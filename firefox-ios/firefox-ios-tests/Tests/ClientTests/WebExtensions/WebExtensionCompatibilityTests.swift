// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

final class WebExtensionCompatibilityTests: XCTestCase {
    func testBlockingWebRequestWontWork() {
        let report = WebExtensionCompatibility.assess(type: "extension", permissions: [
            "alarms", "dns", "menus", "privacy", "storage", "tabs", "unlimitedStorage", "webNavigation",
            "webRequest", "webRequestBlocking", "<all_urls>", "https://*/*"
        ])
        XCTAssertEqual(report.verdict, .incompatible)
        XCTAssertTrue(report.notes.first?.contains("AdGuard") ?? false)
    }

    func testProxyExtensionsPointToTheBuiltInProxy() {
        let report = WebExtensionCompatibility.assess(type: "extension", permissions: ["proxy", "storage", "<all_urls>"])
        XCTAssertEqual(report.verdict, .incompatible)
        XCTAssertTrue(report.notes.first?.contains("NordVPN Proxy") ?? false)
    }

    func testLimitedPermissionsPartlyWork() {
        let report = WebExtensionCompatibility.assess(type: "extension",
                                                      permissions: ["storage", "tabs", "contextMenus", "theme"])
        XCTAssertEqual(report.verdict, .partial)
        XCTAssertEqual(report.notes.count, 2)
    }

    func testSupportedPermissionsWork() {
        let report = WebExtensionCompatibility.assess(type: "extension",
                                                      permissions: ["storage", "activeTab", "scripting", "<all_urls>"])
        XCTAssertEqual(report, WebExtensionCompatibility.Report(verdict: .works, notes: []))
    }

    func testOptionalBlockersOnlyDowngradeToPartial() {
        let report = WebExtensionCompatibility.assess(type: "extension",
                                                      permissions: ["storage"],
                                                      optionalPermissions: ["nativeMessaging"])
        XCTAssertEqual(report.verdict, .partial)
        XCTAssertTrue(report.notes.first?.hasPrefix("Optional feature:") ?? false)
    }

    func testUnknownPermissionsAreFlagged() {
        let report = WebExtensionCompatibility.assess(type: "extension", permissions: ["storage", "someNewAPI"])
        XCTAssertEqual(report.verdict, .partial)
        XCTAssertTrue(report.notes.last?.contains("someNewAPI") ?? false)
    }

    func testThemesAreNotAvailable() {
        let report = WebExtensionCompatibility.assess(type: "statictheme", permissions: [])
        XCTAssertEqual(report.verdict, .unsupportedType)
        XCTAssertEqual(report.verdict.label, "Not available in Ferret")
    }

    func testReadsStoreJSON() {
        let json: [String: Any] = [
            "type": "extension",
            "current_version": ["file": ["permissions": ["storage", "webRequestBlocking"], "optional_permissions": []]]
        ]
        XCTAssertEqual(WebExtensionCompatibility.assess(amoAddon: json).verdict, .incompatible)
        let flat: [String: Any] = ["type": "extension", "permissions": ["storage"], "optional_permissions": []]
        XCTAssertEqual(WebExtensionCompatibility.assess(amoAddon: flat).verdict, .works)
    }

    func testOnlyTheStoreGetsVerdicts() {
        XCTAssertTrue(WebExtensionStoreLabels.isStoreHost("addons.mozilla.org"))
        XCTAssertFalse(WebExtensionStoreLabels.isStoreHost("addons.mozilla.org.evil.com"))
        XCTAssertFalse(WebExtensionStoreLabels.isStoreHost("example.com"))
    }
}
