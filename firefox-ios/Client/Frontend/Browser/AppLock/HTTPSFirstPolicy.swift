// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// HTTPS-First: page loads that ask for `http://` are sent to `https://` instead. If the secure
/// connection can't be made, or the site redirects back to `http://`, Ferret falls back to `http://`
/// for that site until the app quits. Local network addresses are left alone.
@MainActor
final class HTTPSFirstPolicy {
    static let shared = HTTPSFirstPolicy()
    static let enabledKey = "ferret.httpsFirst"

    private let defaults: UserDefaults
    /// Sites that couldn't be loaded securely this session.
    private(set) var exceptions = Set<String>()
    /// The original `http://` address for each web view with an upgrade in flight.
    private var pending: [ObjectIdentifier: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// The `https://` address to load instead of `url`, or nil to load `url` as it is.
    func upgrade(_ url: URL, method: String?, in webView: AnyObject) -> URL? {
        let key = ObjectIdentifier(webView)
        if let original = pending[key], original.host?.lowercased() == url.host?.lowercased(),
           url.scheme?.lowercased() == "http" {
            // The secure page sent us back to http://, so the site doesn't support https.
            pending[key] = nil
            if let host = url.host?.lowercased() { exceptions.insert(host) }
            return nil
        }
        guard isEnabled,
              (method ?? "GET").uppercased() == "GET",
              let secure = Self.secureURL(for: url, exceptions: exceptions) else { return nil }
        pending[key] = url
        return secure
    }

    /// After an upgraded load fails to connect, the `http://` address to fall back to.
    func fallback(after error: Error, in webView: AnyObject) -> URL? {
        guard Self.isSecureConnectionFailure(error),
              let original = pending.removeValue(forKey: ObjectIdentifier(webView)),
              let host = original.host?.lowercased() else { return nil }
        exceptions.insert(host)
        return original
    }

    func navigationCommitted(in webView: AnyObject) {
        pending[ObjectIdentifier(webView)] = nil
    }

    nonisolated static func secureURL(for url: URL, exceptions: Set<String>) -> URL? {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.port == nil || url.port == 80,
              !exceptions.contains(host),
              !isLocal(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        components.port = nil
        return components.url
    }

    /// Hosts that usually have no certificate: localhost, .local names, single-label names and IP addresses.
    nonisolated static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if !host.contains(".") || host.contains(":") { return true }
        return host.split(separator: ".").allSatisfy { Int($0) != nil }
    }

    nonisolated static func isSecureConnectionFailure(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
            NSURLErrorCannotConnectToHost,
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost
        ].contains(error.code)
    }
}
