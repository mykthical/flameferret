// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

final class NordProxyTests: XCTestCase {
    private let countriesJSON = """
    [{"id":228,"name":"United States","code":"US"},{"id":81,"name":"Germany","code":"DE"}]
    """
    private let serversJSON = """
    [{"hostname":"us1234.nordvpn.com","load":40},{"hostname":"us99.nordvpn.com","load":7},
     {"hostname":"evil.example.com","load":1}]
    """

    private let proxyServersJSON = """
    [{"hostname":"us1.nordvpn.com","load":30,"status":"online","locations":[{"country":{"id":228,
      "subdivision":{"id":84,"name":"Texas"},"city":{"id":9080300,"name":"Dallas"}}}]},
     {"hostname":"us2.nordvpn.com","load":5,"status":"online","locations":[{"country":{"id":228,
      "subdivision":{"id":73,"name":"New York"},"city":{"id":8971718,"name":"New York"}}}]},
     {"hostname":"us3.nordvpn.com","load":12,"status":"online","locations":[{"country":{"id":228,
      "subdivision":{"id":84,"name":"Texas"},"city":{"id":9080300,"name":"Dallas"}}}]},
     {"hostname":"us4.nordvpn.com","load":1,"status":"maintenance","locations":[{"country":{"id":228,
      "subdivision":{"id":84,"name":"Texas"},"city":{"id":9080300,"name":"Dallas"}}}]},
     {"hostname":"de1.nordvpn.com","load":1,"status":"online","locations":[{"country":{"id":81,
      "city":{"id":2,"name":"Berlin"}}}]}]
    """

    private func makeStore() -> NordProxyStore {
        let defaults = UserDefaults(suiteName: "NordProxyTests-\(UUID().uuidString)")!
        return NordProxyStore(defaults: defaults, secrets: InMemoryAppLockSecretStore())
    }

    private func catalog(_ responses: [String: String]) -> NordProxyCatalog {
        return NordProxyCatalog { request in
            let url = request.url?.absoluteString ?? ""
            guard let body = responses.first(where: { url.contains($0.key) })?.value else {
                throw URLError(.fileDoesNotExist)
            }
            return Data(body.utf8)
        }
    }

    func testOnlyNordHostnamesAreAccepted() {
        XCTAssertTrue(NordProxyCatalog.isNordHostname("us1234.nordvpn.com"))
        XCTAssertTrue(NordProxyCatalog.isNordHostname("DE-FR5.NordVPN.com"))
        XCTAssertFalse(NordProxyCatalog.isNordHostname("nordvpn.com"))
        XCTAssertFalse(NordProxyCatalog.isNordHostname(".nordvpn.com"))
        XCTAssertFalse(NordProxyCatalog.isNordHostname("us1.nordvpn.com.evil.com"))
        XCTAssertFalse(NordProxyCatalog.isNordHostname("a.b.nordvpn.com"))
    }

    func testURLsAskForHTTPSProxies() {
        XCTAssertTrue(NordProxyCatalog.recommendationsURL.absoluteString.contains("identifier%5D=proxy_ssl"))
        let country = NordProxyCatalog.serversURL(countryID: 228).absoluteString
        XCTAssertTrue(country.contains("identifier%5D=proxy_ssl"))
        XCTAssertTrue(country.contains("filters%5Bcountry_id%5D=228"))
    }

    func testCountryServersKeepOnlyOnlineServersInThatCountry() async throws {
        let servers = try await catalog(["/servers?": proxyServersJSON]).proxyServers(countryID: 228)
        XCTAssertEqual(servers.map(\.hostname), ["us1.nordvpn.com", "us2.nordvpn.com", "us3.nordvpn.com"])
        XCTAssertEqual(servers.first?.region, NordPlace(id: 84, name: "Texas"))
        XCTAssertEqual(servers.first?.city, NordPlace(id: 9080300, name: "Dallas"))
    }

    func testRegionsCitiesAndBestServer() async throws {
        let servers = try await catalog(["/servers?": proxyServersJSON]).proxyServers(countryID: 228)
        XCTAssertEqual(NordProxyCatalog.regions(in: servers).map(\.name), ["New York", "Texas"])
        XCTAssertEqual(NordProxyCatalog.cities(in: servers, regionID: 84).map(\.name), ["Dallas"])
        XCTAssertEqual(NordProxyCatalog.cities(in: servers, regionID: nil).count, 2)
        XCTAssertEqual(NordProxyCatalog.bestServer(in: servers, regionID: nil, cityID: nil)?.hostname,
                       "us2.nordvpn.com")
        XCTAssertEqual(NordProxyCatalog.bestServer(in: servers, regionID: 84, cityID: 9080300)?.hostname,
                       "us3.nordvpn.com")
        XCTAssertNil(NordProxyCatalog.bestServer(in: servers, regionID: 73, cityID: 9080300))
    }

    func testPicksLeastLoadedNordServer() async throws {
        let server = try await catalog(["recommendations": serversJSON]).recommendedServer()
        XCTAssertEqual(server.hostname, "us99.nordvpn.com")
    }

    func testNoServersIsAnError() async {
        do {
            _ = try await catalog(["recommendations": "[]"]).recommendedServer()
            XCTFail("Expected noServers")
        } catch {
            XCTAssertTrue(error is NordProxyCatalogError)
        }
    }

    func testCountriesAreSortedByName() async throws {
        let countries = try await catalog(["countries": countriesJSON]).countries()
        XCTAssertEqual(countries.map(\.code), ["DE", "US"])
    }

    func testRouteIsDirectWhenOff() {
        let store = makeStore()
        store.username = "user"
        store.password = "pass"
        store.hostname = "us99.nordvpn.com"
        XCTAssertEqual(store.route, .direct)
    }

    func testRouteBlocksWhenOnButIncomplete() {
        let store = makeStore()
        store.isEnabled = true
        XCTAssertEqual(store.route, .blocked)
        store.username = "user"
        store.password = "pass"
        XCTAssertEqual(store.route, .blocked)
        store.hostname = "proxy.example.com"
        XCTAssertEqual(store.route, .blocked)
    }

    func testRouteUsesProxyWhenComplete() {
        let store = makeStore()
        store.isEnabled = true
        store.username = "  user \n"
        store.password = "pass"
        store.hostname = "us99.nordvpn.com"
        XCTAssertEqual(store.route, .proxy(host: "us99.nordvpn.com", port: 89, username: "user", password: "pass"))
        store.clearCredentials()
        XCTAssertFalse(store.hasCredentials)
    }

    func testLocationIsRememberedAndNarrowerChoicesReset() {
        let store = makeStore()
        XCTAssertEqual(store.locationSummary, "Fastest Available")
        store.country = NordPlace(id: 228, name: "United States")
        store.region = NordPlace(id: 84, name: "Texas")
        store.city = NordPlace(id: 9080300, name: "Dallas")
        XCTAssertEqual(store.locationSummary, "Dallas, Texas, United States")
        store.region = NordPlace(id: 73, name: "New York")
        XCTAssertNil(store.city)
        store.country = NordPlace(id: 81, name: "Germany")
        XCTAssertNil(store.region)
        XCTAssertEqual(store.country?.id, 81)
    }

    @MainActor
    func testChoosingALocationPicksAServerThere() async throws {
        let manager = NordProxyManager(store: makeStore(), catalog: catalog(["/servers?": proxyServersJSON]))
        try await manager.setCountry(NordPlace(id: 228, name: "United States"))
        XCTAssertEqual(manager.store.hostname, "us2.nordvpn.com")
        let regions = try await manager.loadRegions()
        XCTAssertEqual(regions.map(\.name), ["New York", "Texas"])
        try await manager.setRegion(NordPlace(id: 84, name: "Texas"))
        XCTAssertEqual(manager.store.hostname, "us3.nordvpn.com")
        let cities = try await manager.loadCities()
        XCTAssertEqual(cities.map(\.name), ["Dallas"])
        try await manager.setCity(NordPlace(id: 9080300, name: "Dallas"))
        XCTAssertEqual(manager.store.hostname, "us3.nordvpn.com")
    }

    @MainActor
    func testFastestAvailableUsesRecommendations() async throws {
        let manager = NordProxyManager(store: makeStore(), catalog: catalog(["recommendations": serversJSON]))
        try await manager.setCountry(nil)
        XCTAssertEqual(manager.store.hostname, "us99.nordvpn.com")
    }

    @MainActor
    func testCheckConnectionReadsInsights() async throws {
        let manager = NordProxyManager(store: makeStore(), catalog: catalog([:])) { _, _ in
            Data(#"{"ip":"203.0.113.9","country":"Germany","city":"Berlin","protected":true}"#.utf8)
        }
        let insight = try await manager.checkConnection()
        XCTAssertTrue(insight.protected)
        XCTAssertEqual(insight.ip, "203.0.113.9")
    }
}
