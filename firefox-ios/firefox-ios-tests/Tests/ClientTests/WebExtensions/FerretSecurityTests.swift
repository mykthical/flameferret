// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Shared
import XCTest
@testable import Client

final class FerretSecurityTests: XCTestCase {
    // MARK: - Secure defaults

    func testSecureDefaultsTurnOffDataSharingAndTightenTracking() {
        let prefs = MockProfilePrefs()
        SecureDefaults.apply(to: prefs)
        for key in SecureDefaults.disabledPrefs {
            XCTAssertEqual(prefs.boolForKey(key), false, key)
        }
        XCTAssertEqual(prefs.stringForKey(ContentBlockingConfig.Prefs.StrengthKey), BlockingStrength.strict.rawValue)
        XCTAssertEqual(prefs.boolForKey(ContentBlockingConfig.Prefs.EnabledKey), true)
    }

    func testSecureDefaultsDontOverrideLaterChoices() {
        let prefs = MockProfilePrefs()
        SecureDefaults.apply(to: prefs)
        prefs.setBool(true, forKey: PrefsKeys.SearchSettings.showSearchSuggestions)
        SecureDefaults.apply(to: prefs)
        XCTAssertEqual(prefs.boolForKey(PrefsKeys.SearchSettings.showSearchSuggestions), true)
    }

    // MARK: - PIN setup

    @MainActor
    func testPINScreenCoversSettingsWithoutReplacingIt() {
        // Settings closes itself when its view disappears, which a .fullScreen presentation would cause.
        let controller = AppLockViewController(mode: .create { _ in }, manager: AppLockManager.shared)
        XCTAssertEqual(controller.modalPresentationStyle, .overFullScreen)
    }

    // MARK: - HTTPS-First

    func testUpgradesPlainHTTP() {
        let url = URL(string: "http://example.com/path?q=1#top")!
        XCTAssertEqual(HTTPSFirstPolicy.secureURL(for: url, exceptions: [])?.absoluteString,
                       "https://example.com/path?q=1#top")
        XCTAssertEqual(HTTPSFirstPolicy.secureURL(for: URL(string: "http://example.com:80/")!, exceptions: [])?
            .absoluteString, "https://example.com/")
    }

    func testLeavesLocalCustomPortAndExceptedSitesAlone() {
        for address in ["http://localhost/", "http://192.168.1.1/", "http://printer.local/", "http://router/",
                        "http://example.com:8080/", "https://example.com/", "http://[::1]/"] {
            XCTAssertNil(HTTPSFirstPolicy.secureURL(for: URL(string: address)!, exceptions: []), address)
        }
        XCTAssertNil(HTTPSFirstPolicy.secureURL(for: URL(string: "http://old.example/")!, exceptions: ["old.example"]))
    }

    @MainActor
    func testFallsBackToHTTPWhenTheSecureConnectionFails() {
        let policy = HTTPSFirstPolicy(defaults: UserDefaults(suiteName: "https-\(UUID().uuidString)")!)
        let webView = NSObject()
        let insecure = URL(string: "http://old.example/page")!
        XCTAssertEqual(policy.upgrade(insecure, method: "GET", in: webView)?.scheme, "https")
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed)
        XCTAssertEqual(policy.fallback(after: failure, in: webView), insecure)
        XCTAssertNil(policy.upgrade(insecure, method: "GET", in: webView))
    }

    @MainActor
    func testRedirectBackToHTTPStopsUpgrading() {
        let policy = HTTPSFirstPolicy(defaults: UserDefaults(suiteName: "https-\(UUID().uuidString)")!)
        let webView = NSObject()
        let insecure = URL(string: "http://loop.example/")!
        XCTAssertNotNil(policy.upgrade(insecure, method: "GET", in: webView))
        XCTAssertNil(policy.upgrade(insecure, method: "GET", in: webView))
        XCTAssertTrue(policy.exceptions.contains("loop.example"))
    }

    @MainActor
    func testOnlyUpgradesGETAndRespectsTheSetting() {
        let policy = HTTPSFirstPolicy(defaults: UserDefaults(suiteName: "https-\(UUID().uuidString)")!)
        let url = URL(string: "http://example.com/form")!
        XCTAssertNil(policy.upgrade(url, method: "POST", in: NSObject()))
        policy.isEnabled = false
        XCTAssertNil(policy.upgrade(url, method: "GET", in: NSObject()))
    }

    func testOtherErrorsDontTriggerFallback() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertFalse(HTTPSFirstPolicy.isSecureConnectionFailure(cancelled))
        XCTAssertTrue(HTTPSFirstPolicy.isSecureConnectionFailure(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)))
    }
}
