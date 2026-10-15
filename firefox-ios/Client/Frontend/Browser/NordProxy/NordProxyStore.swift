// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Where browsing traffic should go, worked out from the saved settings.
enum NordProxyRoute: Equatable {
    /// Proxy off: connect directly.
    case direct
    /// Through a NordVPN HTTPS proxy.
    case proxy(host: String, port: UInt16, username: String, password: String)
    /// Proxy on but not usable yet (no credentials or server): block traffic rather than leak it.
    case blocked
}

/// Proxy settings. The service credentials live in the Keychain; everything else in user defaults.
final class NordProxyStore {
    private enum Key {
        static let enabled = "ferret.nordproxy.enabled"
        static let countryID = "ferret.nordproxy.countryID"
        static let countryName = "ferret.nordproxy.countryName"
        static let hostname = "ferret.nordproxy.hostname"
        static let username = "nordproxy.username"
        static let password = "nordproxy.password"
    }

    private let defaults: UserDefaults
    private let secrets: AppLockSecretStore

    init(defaults: UserDefaults = .standard,
         secrets: AppLockSecretStore = KeychainAppLockSecretStore(service: "com.mykthical.flameferret.nordproxy")) {
        self.defaults = defaults
        self.secrets = secrets
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// The chosen country, or nil for "Fastest available".
    var country: (id: Int, name: String)? {
        get {
            guard let name = defaults.string(forKey: Key.countryName), defaults.object(forKey: Key.countryID) != nil
            else { return nil }
            return (defaults.integer(forKey: Key.countryID), name)
        }
        set {
            defaults.set(newValue?.id, forKey: Key.countryID)
            defaults.set(newValue?.name, forKey: Key.countryName)
        }
    }

    var hostname: String? {
        get { defaults.string(forKey: Key.hostname) }
        set { defaults.set(newValue, forKey: Key.hostname) }
    }

    var username: String {
        get { string(for: Key.username) }
        set { setString(newValue, for: Key.username) }
    }

    var password: String {
        get { string(for: Key.password) }
        set { setString(newValue, for: Key.password) }
    }

    var hasCredentials: Bool {
        return !username.isEmpty && !password.isEmpty
    }

    var route: NordProxyRoute {
        guard isEnabled else { return .direct }
        guard hasCredentials, let hostname, NordProxyCatalog.isNordHostname(hostname) else { return .blocked }
        return .proxy(host: hostname, port: NordProxyCatalog.proxyPort, username: username, password: password)
    }

    func clearCredentials() {
        secrets.set(nil, for: Key.username)
        secrets.set(nil, for: Key.password)
    }

    private func string(for key: String) -> String {
        return secrets.data(for: key).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func setString(_ value: String, for key: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.set(trimmed.isEmpty ? nil : Data(trimmed.utf8), for: key)
    }
}
