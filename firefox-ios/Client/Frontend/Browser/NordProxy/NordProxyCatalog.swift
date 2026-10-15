// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

struct NordCountry: Codable, Equatable, Sendable {
    let id: Int
    let name: String
    let code: String
}

struct NordServer: Codable, Equatable, Sendable {
    let hostname: String
    let load: Int
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
        case .noServers: return "NordVPN didn't return a proxy server for that location. Try another country."
        }
    }
}

/// Reads NordVPN's public server API, the same one its apps and browser extensions use.
struct NordProxyCatalog: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    static let apiBase = "https://api.nordvpn.com/v1"
    /// NordVPN's encrypted (HTTPS) proxy port, as used by its browser extensions.
    static let proxyPort: UInt16 = 89

    private let fetch: Fetch

    init(fetch: @escaping Fetch = NordProxyCatalog.urlSessionFetch) {
        self.fetch = fetch
    }

    func countries() async throws -> [NordCountry] {
        let data = try await fetch(URLRequest(url: URL(string: "\(Self.apiBase)/servers/countries")!))
        return try JSONDecoder().decode([NordCountry].self, from: data).sorted { $0.name < $1.name }
    }

    /// The least-loaded HTTPS proxy server, in `countryID` or near the user when nil.
    func recommendedServer(countryID: Int?) async throws -> NordServer {
        let data = try await fetch(URLRequest(url: Self.recommendationsURL(countryID: countryID)))
        let servers = try JSONDecoder().decode([NordServer].self, from: data)
            .filter { Self.isNordHostname($0.hostname) }
        guard let best = servers.min(by: { $0.load < $1.load }) else { throw NordProxyCatalogError.noServers }
        return best
    }

    static func recommendationsURL(countryID: Int?) -> URL {
        var query = "filters%5Bservers_technologies%5D%5Bidentifier%5D=proxy_ssl&limit=10"
        if let countryID { query += "&filters%5Bcountry_id%5D=\(countryID)" }
        return URL(string: "\(apiBase)/servers/recommendations?\(query)")!
    }

    static let insightsURL = URL(string: "\(apiBase)/helpers/ips/insights")!

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
