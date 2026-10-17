// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Network
import UIKit
import WebEngine
import WebKit

/// Sends Culpeo's web traffic (normal and private tabs, extension pages) through a NordVPN HTTPS proxy,
/// without a system-wide VPN. WebKit is pointed at `NordProxyRelay` on 127.0.0.1, which makes the
/// authenticated TLS connection to NordVPN. Needs iOS 17 for per-data-store proxies.
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
    private let insightsFetch: (@Sendable (NordProxyRoute, UInt16?) async throws -> Data)?
    private let relay = NordProxyRelay()
    private var relayPort: UInt16?
    private var countries: [NordPlace] = []
    private var serversByCountry: [Int: [NordProxyServer]] = [:]

    init(store: NordProxyStore = NordProxyStore(),
         catalog: NordProxyCatalog = NordProxyCatalog(),
         insightsFetch: (@Sendable (NordProxyRoute, UInt16?) async throws -> Data)? = nil) {
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
        // iOS can stop the relay's listener while Culpeo is suspended; restart it when Culpeo comes back.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil,
                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyEverywhere() }
        }
        applyEverywhere()
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

    /// Checks the route step by step — settings, the NordVPN server and credentials, then a request through
    /// Culpeo's relay — and asks NordVPN which IP the traffic arrives from. Errors explain which step failed.
    func checkConnection() async throws -> NordConnectionInsight {
        switch route {
        case .direct:
            break
        case .blocked:
            if !store.hasCredentials {
                throw NordConnectionProblem("Add your NordVPN service username and password first.")
            }
            throw NordConnectionProblem("No NordVPN server is selected yet. Tap Find Another Server.")
        case .proxy(let host, let port, let username, let password):
            if insightsFetch == nil {
                let upstream = NordProxyUpstream(host: host, port: port,
                                                 authorization: NordProxyWire.basicAuthorization(username: username,
                                                                                                 password: password))
                try await Self.probe(upstream)
            }
            if relayPort == nil {
                throw NordConnectionProblem("Culpeo's proxy relay isn't running. Turn the proxy off and on again.")
            }
        }
        let fetch = insightsFetch ?? Self.fetchInsights
        let data: Data
        do {
            data = try await fetch(route, relayPort)
        } catch {
            throw NordConnectionProblem("NordVPN accepted your credentials, but the test page couldn't load through "
                                        + "Culpeo's relay (\(error.localizedDescription)).")
        }
        return try JSONDecoder().decode(NordConnectionInsight.self, from: data)
    }

    /// Opens and closes one tunnel through the NordVPN server, to test the server and the credentials.
    private static func probe(_ upstream: NordProxyUpstream) async throws {
        let queue = DispatchQueue(label: "ferret.nordproxy.probe")
        let result: Result<Void, NordProxyTunnelError> = await withCheckedContinuation { continuation in
            NordProxyRelay.openTunnel(to: "api.nordvpn.com:443", through: upstream, queue: queue) { result in
                switch result {
                case .success(let (connection, _)):
                    connection.cancel()
                    continuation.resume(returning: .success(()))
                case .failure(let error):
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        if case .failure(let error) = result {
            throw NordConnectionProblem(error.explanation)
        }
    }

    private func applyEverywhere() {
        if case let .proxy(host, port, username, password) = route {
            let upstream = NordProxyUpstream(host: host, port: port,
                                             authorization: NordProxyWire.basicAuthorization(username: username,
                                                                                             password: password))
            relay.start(upstream: upstream) { [weak self] port in
                Task { @MainActor in self?.relayDidStart(port) }
            }
        } else {
            relay.stop()
            relayPort = nil
        }
        applyConfigurations()
    }

    private func relayDidStart(_ port: UInt16?) {
        guard port != relayPort else { return }
        relayPort = port
        applyConfigurations()
    }

    private func applyConfigurations() {
        DefaultWKEngineConfigurationProvider.forEachDataStore { apply(to: $0) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func apply(to dataStore: WKWebsiteDataStore) {
        guard #available(iOS 17.0, *) else { return }
        dataStore.proxyConfigurations = Self.proxyConfigurations(for: route, relayPort: relayPort)
    }

    /// WebKit's proxy settings: none when off, Culpeo's relay when on, and a dead end when the proxy is on but
    /// can't be used yet (no credentials, server or relay), so pages fail instead of going out directly.
    @available(iOS 17.0, *)
    nonisolated static func proxyConfigurations(for route: NordProxyRoute, relayPort: UInt16?) -> [ProxyConfiguration] {
        switch route {
        case .direct:
            return []
        case .proxy where relayPort != nil:
            return [localProxy(port: relayPort ?? 9)]
        case .proxy, .blocked:
            return [localProxy(port: 9)]
        }
    }

    @available(iOS 17.0, *)
    nonisolated private static func localProxy(port: UInt16) -> ProxyConfiguration {
        var configuration = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1",
                                                                         port: NWEndpoint.Port(rawValue: port) ?? 9))
        configuration.allowFailover = false
        return configuration
    }

    private static let fetchInsights: @Sendable (NordProxyRoute, UInt16?) async throws -> Data = { route, relayPort in
        let configuration = URLSessionConfiguration.ephemeral
        if #available(iOS 17.0, *) {
            configuration.proxyConfigurations = proxyConfigurations(for: route, relayPort: relayPort)
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

struct NordConnectionProblem: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
