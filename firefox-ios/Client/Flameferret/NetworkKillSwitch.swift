// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import ObjectiveC

/// Refuses every app-level request to Mozilla services and known analytics, attribution and
/// crash-reporting hosts. Installed into every `URLSession` the app creates.
final class NetworkKillSwitch: URLProtocol {
    static let blockedDomains: [String] = [
        "mozilla.org", "mozilla.com", "mozilla.net", "mozilla.cloud", "mozgcp.net", "mozaws.net",
        "firefox.com", "firefoxusercontent.com", "getpocket.com", "pocket.com", "fakespot.com",
        "mozilla-ohttp.fastly-edge.com", "mlpa-prod-prod-mozilla.global.ssl.fastly.net",
        "mlpa-nonprod-stage-mozilla.global.ssl.fastly.net", "mlpa-nonprod-dev-mozilla.global.ssl.fastly.net",
        "adjust.com", "adjust.io", "adjust-skadnetwork.com", "sentry.io", "sentry-cdn.com",
        "app-measurement.com", "google-analytics.com", "googletagmanager.com", "doubleclick.net",
        "crashlytics.com", "firebaseinstallations.googleapis.com", "firebaselogging-pa.googleapis.com",
        "branch.io", "appsflyer.com", "amplitude.com", "mixpanel.com", "segment.io", "braze.com",
    ]

    private static let lock = NSLock()
    private nonisolated(unsafe) static var installed = false
    private nonisolated(unsafe) static var refused = 0

    static var refusedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }

    static func isBlocked(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return blockedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Call once, before anything creates a `URLSession`.
    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        URLProtocol.registerClass(NetworkKillSwitch.self)
        swizzle(#selector(getter: URLSessionConfiguration.default),
                with: #selector(getter: URLSessionConfiguration.flameferret_default))
        swizzle(#selector(getter: URLSessionConfiguration.ephemeral),
                with: #selector(getter: URLSessionConfiguration.flameferret_ephemeral))
    }

    private static func swizzle(_ original: Selector, with replacement: Selector) {
        let metaClass: AnyClass = object_getClass(URLSessionConfiguration.self)!
        guard let originalMethod = class_getInstanceMethod(metaClass, original),
              let replacementMethod = class_getInstanceMethod(metaClass, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        return isBlocked(host: request.url?.host)
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest ?? task.originalRequest else { return false }
        return canInit(with: request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        NetworkKillSwitch.lock.lock()
        NetworkKillSwitch.refused += 1
        NetworkKillSwitch.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}

extension URLSessionConfiguration {
    /// After swizzling, calling this runs the original `default` getter.
    @objc class var flameferret_default: URLSessionConfiguration {
        let configuration = self.flameferret_default
        configuration.addKillSwitch()
        return configuration
    }

    @objc class var flameferret_ephemeral: URLSessionConfiguration {
        let configuration = self.flameferret_ephemeral
        configuration.addKillSwitch()
        return configuration
    }

    fileprivate func addKillSwitch() {
        var classes = protocolClasses ?? []
        if !classes.contains(where: { $0 == NetworkKillSwitch.self }) {
            classes.insert(NetworkKillSwitch.self, at: 0)
        }
        protocolClasses = classes
    }
}
