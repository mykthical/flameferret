// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Network
import WebEngine
import WebKit

/// Sends Ferret's web traffic (normal and private tabs, extension pages) through a NordVPN HTTPS proxy,
/// without a system-wide VPN. Needs iOS 17 for per-data-store proxies.
@MainActor
final class NordProxyManager {
    static let shared = NordProxyManager()
    static let didChange = Notification.Name("FerretNordProxyDidChange")

    static var isSupported: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    let store: NordProxyStore
    private let catalog: NordProxyCatalog
    private let insightsFetch: (@Sendable (NordProxyRoute) async throws -> Data)?
    private var countries: [NordPlace] = []
    private var serversByCountry: [Int: [NordProxyServer]] = [:]

    init(store: NordProxyStore = NordProxyStore(),
         catalog: NordProxyCatalog = NordProxyCatalog(),
         insightsFetch: (@Sendable (NordProxyRoute) async throws -> Data)? = nil) {
        self.store = store
        self.catalog = catalog
        self.insightsFetch = insightsFetch
    }

    var route: NordProxyRoute { store.route }

    /// Call once at launch, before any web view is created.
    func start() {
        DefaultWKEngineConfigurationProvider.dataStoreObserver = { [weak self] dataStore in
            self?.apply(to: dataStore)
        }
        if store.isEnabled && store.hostname == nil {
            Task { try? await self.refreshServer() }
        }
    }

    func setEnabled(_ enabled: Bool) async throws {
        store.isEnabled = enabled
        applyEverywhere()
        if enabled && store.hostname == nil {
            try await refreshServer()
        }
    }

    func setCountry(_ country: NordPlace?) async throws {
        store.country = country
        try await locationChanged()
    }

    func setRegion(_ region: NordPlace?) async throws {
        store.region = region
        try await locationChanged()
    }

    func setCity(_ city: NordPlace?) async throws {
        store.city = city
        try await locationChanged()
    }

    private func locationChanged() async throws {
        store.hostname = nil
        applyEverywhere()
        try await refreshServer()
    }

    func setCredentials(username: String, password: String) {
        store.username = username
        store.password = password
        applyEverywhere()
    }

    /// Picks the least-loaded server for the chosen country, region and city.
    func refreshServer() async throws {
        guard let country = store.country else {
            store.hostname = try await catalog.recommendedServer().hostname
            applyEverywhere()
            return
        }
        let servers = try await proxyServers(countryID: country.id, reload: true)
        guard let best = NordProxyCatalog.bestServer(in: servers, regionID: store.region?.id, cityID: store.city?.id)
        else { throw NordProxyCatalogError.noServers }
        store.hostname = best.hostname
        applyEverywhere()
    }

    func loadCountries() async throws -> [NordPlace] {
        if countries.isEmpty {
            countries = try await catalog.countries().map { NordPlace(id: $0.id, name: $0.name) }
        }
        return countries
    }

    /// Regions in the chosen country that have proxy servers.
    func loadRegions() async throws -> [NordPlace] {
        guard let country = store.country else { return [] }
        return NordProxyCatalog.regions(in: try await proxyServers(countryID: country.id))
    }

    /// Cities in the chosen country, and region if one is set, that have proxy servers.
    func loadCities() async throws -> [NordPlace] {
        guard let country = store.country else { return [] }
        let servers = try await proxyServers(countryID: country.id)
        return NordProxyCatalog.cities(in: servers, regionID: store.region?.id)
    }

    private func proxyServers(countryID: Int, reload: Bool = false) async throws -> [NordProxyServer] {
        if !reload, let cached = serversByCountry[countryID] { return cached }
        let servers = try await catalog.proxyServers(countryID: countryID)
        serversByCountry[countryID] = servers
        return servers
    }

    /// Asks NordVPN, through the current route, which IP the traffic arrives from.
    func checkConnection() async throws -> NordConnectionInsight {
        let fetch = insightsFetch ?? Self.fetchInsights
        let data = try await fetch(route)
        return try JSONDecoder().decode(NordConnectionInsight.self, from: data)
    }

    private func applyEverywhere() {
        DefaultWKEngineConfigurationProvider.forEachDataStore { apply(to: $0) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func apply(to dataStore: WKWebsiteDataStore) {
        guard #available(iOS 17.0, *) else { return }
        dataStore.proxyConfigurations = Self.proxyConfigurations(for: route)
    }

    @available(iOS 17.0, *)
    nonisolated static func proxyConfigurations(for route: NordProxyRoute) -> [ProxyConfiguration] {
        switch route {
        case .direct:
            return []
        case .blocked:
            // A proxy nothing listens on, so pages fail to load instead of going out directly.
            var configuration = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 9))
            configuration.allowFailover = false
            return [configuration]
        case let .proxy(host, port, username, password):
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                               port: NWEndpoint.Port(rawValue: port) ?? 89)
            var configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
            configuration.applyCredential(username: username, password: password)
            configuration.allowFailover = false
            return [configuration]
        }
    }

    private static let fetchInsights: @Sendable (NordProxyRoute) async throws -> Data = { route in
        let configuration = URLSessionConfiguration.ephemeral
        if #available(iOS 17.0, *) {
            configuration.proxyConfigurations = proxyConfigurations(for: route)
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: NordProxyCatalog.insightsURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
