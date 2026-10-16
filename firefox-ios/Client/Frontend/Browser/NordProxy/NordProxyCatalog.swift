// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

struct NordCountry: Codable, Equatable, Sendable {
    let id: Int
    let name: String
    let code: String
}

/// A country, region (state or province) or city, as NordVPN identifies it.
struct NordPlace: Codable, Equatable, Hashable, Sendable {
    let id: Int
    let name: String
}

struct NordServer: Codable, Equatable, Sendable {
    let hostname: String
    let load: Int
}

/// One HTTPS proxy server and where it is.
struct NordProxyServer: Decodable, Equatable, Sendable {
    let hostname: String
    let load: Int
    let isOnline: Bool
    let countryID: Int?
    let region: NordPlace?
    let city: NordPlace?

    private enum CodingKeys: String, CodingKey { case hostname, load, status, locations }
    private struct Location: Decodable { let country: Country }
    private struct Country: Decodable {
        let id: Int?
        let subdivision: NordPlace?
        let city: NordPlace?
    }

    init(hostname: String, load: Int, isOnline: Bool = true, countryID: Int?, region: NordPlace?, city: NordPlace?) {
        self.hostname = hostname
        self.load = load
        self.isOnline = isOnline
        self.countryID = countryID
        self.region = region
        self.city = city
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try container.decode(String.self, forKey: .hostname)
        load = try container.decodeIfPresent(Int.self, forKey: .load) ?? 100
        isOnline = (try container.decodeIfPresent(String.self, forKey: .status) ?? "online") == "online"
        let country = try container.decodeIfPresent([Location].self, forKey: .locations)?.first?.country
        countryID = country?.id
        region = country?.subdivision
        city = country?.city
    }
}

/// What NordVPN reports about the connection a request arrived on.
struct NordConnectionInsight: Codable, Equatable, Sendable {
    let ip: String
    let country: String?
    let city: String?
    let protected: Bool
}

enum NordProxyCatalogError: LocalizedError {
    case noServers

    var errorDescription: String? {
        switch self {
        case .noServers: return "NordVPN has no proxy server online there right now. Try another location."
        }
    }
}

/// Reads NordVPN's public server API, the same one its apps and browser extensions use.
struct NordProxyCatalog: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    static let apiBase = "https://api.nordvpn.com/v1"
    /// NordVPN's encrypted (HTTPS) proxy port, as used by its browser extensions.
    static let proxyPort: UInt16 = 89
    private static let proxyFilter = "filters%5Bservers_technologies%5D%5Bidentifier%5D=proxy_ssl"

    private let fetch: Fetch

    init(fetch: @escaping Fetch = NordProxyCatalog.urlSessionFetch) {
        self.fetch = fetch
    }

    func countries() async throws -> [NordCountry] {
        let data = try await fetch(URLRequest(url: URL(string: "\(Self.apiBase)/servers/countries")!))
        return try JSONDecoder().decode([NordCountry].self, from: data).sorted { $0.name < $1.name }
    }

    /// The least-loaded HTTPS proxy server near the user.
    func recommendedServer() async throws -> NordServer {
        let data = try await fetch(URLRequest(url: Self.recommendationsURL))
        let servers = try JSONDecoder().decode([NordServer].self, from: data)
            .filter { Self.isNordHostname($0.hostname) }
        guard let best = servers.min(by: { $0.load < $1.load }) else { throw NordProxyCatalogError.noServers }
        return best
    }

    /// Every online HTTPS proxy server in a country, with its region and city.
    func proxyServers(countryID: Int) async throws -> [NordProxyServer] {
        let data = try await fetch(URLRequest(url: Self.serversURL(countryID: countryID)))
        return try JSONDecoder().decode([NordProxyServer].self, from: data).filter {
            $0.isOnline && $0.countryID == countryID && Self.isNordHostname($0.hostname)
        }
    }

    static let recommendationsURL = URL(string: "\(apiBase)/servers/recommendations?\(proxyFilter)&limit=10")!

    static func serversURL(countryID: Int) -> URL {
        return URL(string: "\(apiBase)/servers?\(proxyFilter)&filters%5Bcountry_id%5D=\(countryID)&limit=0")!
    }

    static let insightsURL = URL(string: "\(apiBase)/helpers/ips/insights")!

    /// Regions that have proxy servers, by name.
    static func regions(in servers: [NordProxyServer]) -> [NordPlace] {
        return Set(servers.compactMap(\.region)).sorted { $0.name < $1.name }
    }

    /// Cities that have proxy servers, optionally only those in `regionID`, by name.
    static func cities(in servers: [NordProxyServer], regionID: Int?) -> [NordPlace] {
        let matching = servers.filter { regionID == nil || $0.region?.id == regionID }
        return Set(matching.compactMap(\.city)).sorted { $0.name < $1.name }
    }

    /// The least-loaded server matching the region and city, when they're set.
    static func bestServer(in servers: [NordProxyServer], regionID: Int?, cityID: Int?) -> NordProxyServer? {
        return servers
            .filter { (regionID == nil || $0.region?.id == regionID) && (cityID == nil || $0.city?.id == cityID) }
            .min { $0.load < $1.load }
    }

    /// The name to connect to for a server's HTTPS proxy. NordVPN's proxy certificate is issued for
    /// `*.proxy.nordvpn.com`, so `us1234.nordvpn.com` is reached as `us1234.proxy.nordvpn.com` (same address).
    static func proxyHostname(for hostname: String) -> String {
        let host = hostname.lowercased()
        guard host.hasSuffix(".nordvpn.com"), !host.hasSuffix(".proxy.nordvpn.com") else { return host }
        return String(host.dropLast(".nordvpn.com".count)) + ".proxy.nordvpn.com"
    }

    /// Only connect to NordVPN's own hosts, whatever the API returns.
    static func isNordHostname(_ hostname: String) -> Bool {
        let host = hostname.lowercased()
        let label = host.dropLast(".nordvpn.com".count)
        return host.hasSuffix(".nordvpn.com")
            && !label.isEmpty
            && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
