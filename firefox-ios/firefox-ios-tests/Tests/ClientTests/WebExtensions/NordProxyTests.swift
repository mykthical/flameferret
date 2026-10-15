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

    func testRecommendationsURLAsksForHTTPSProxies() {
        let fastest = NordProxyCatalog.recommendationsURL(countryID: nil).absoluteString
        XCTAssertTrue(fastest.contains("identifier%5D=proxy_ssl"))
        XCTAssertFalse(fastest.contains("country_id"))
        XCTAssertTrue(NordProxyCatalog.recommendationsURL(countryID: 228).absoluteString
            .hasSuffix("filters%5Bcountry_id%5D=228"))
    }

    func testPicksLeastLoadedNordServer() async throws {
        let server = try await catalog(["recommendations": serversJSON]).recommendedServer(countryID: 228)
        XCTAssertEqual(server.hostname, "us99.nordvpn.com")
    }

    func testNoServersIsAnError() async {
        do {
            _ = try await catalog(["recommendations": "[]"]).recommendedServer(countryID: nil)
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

    func testCountryIsRemembered() {
        let store = makeStore()
        XCTAssertNil(store.country)
        store.country = (81, "Germany")
        XCTAssertEqual(store.country?.id, 81)
        XCTAssertEqual(store.country?.name, "Germany")
        store.country = nil
        XCTAssertNil(store.country)
    }

    @MainActor
    func testChoosingACountryPicksAServer() async throws {
        let manager = NordProxyManager(store: makeStore(), catalog: catalog(["recommendations": serversJSON]))
        try await manager.setCountry(NordCountry(id: 228, name: "United States", code: "US"))
        XCTAssertEqual(manager.store.country?.id, 228)
        XCTAssertEqual(manager.store.hostname, "us99.nordvpn.com")
    }

    @MainActor
    func testCheckConnectionReadsInsights() async throws {
        let manager = NordProxyManager(store: makeStore(), catalog: catalog([:])) { _ in
            Data(#"{"ip":"203.0.113.9","country":"Germany","city":"Berlin","protected":true}"#.utf8)
        }
        let insight = try await manager.checkConnection()
        XCTAssertTrue(insight.protected)
        XCTAssertEqual(insight.ip, "203.0.113.9")
    }
}
