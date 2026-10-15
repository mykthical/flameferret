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
    private(set) var countries: [NordCountry] = []

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

    func setCountry(_ country: NordCountry?) async throws {
        store.country = country.map { ($0.id, $0.name) }
        store.hostname = nil
        applyEverywhere()
        try await refreshServer()
    }

    func setCredentials(username: String, password: String) {
        store.username = username
        store.password = password
        applyEverywhere()
    }

    /// Picks the least-loaded server for the chosen location.
    func refreshServer() async throws {
        let server = try await catalog.recommendedServer(countryID: store.country?.id)
        store.hostname = server.hostname
        applyEverywhere()
    }

    func loadCountries() async throws -> [NordCountry] {
        if countries.isEmpty {
            countries = try await catalog.countries()
        }
        return countries
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
