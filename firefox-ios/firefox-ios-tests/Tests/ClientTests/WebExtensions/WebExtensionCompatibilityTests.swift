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
        XCTAssertEqual(report.verdict.label, "Not available in Culpeo")
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

    func testManifestChecksDevtoolsAndThemes() throws {
        let devtools: [String: Any] = ["name": "Inspector", "permissions": ["storage"], "devtools_page": "d.html"]
        XCTAssertEqual(WebExtensionCompatibility.assess(manifest: devtools).verdict, .partial)
        let theme: [String: Any] = ["name": "Blue", "theme": ["colors": [:]]]
        XCTAssertEqual(WebExtensionCompatibility.assess(manifest: theme).verdict, .unsupportedType)
        let blocker: [String: Any] = ["name": "Blocker", "permissions": ["webRequest", "webRequestBlocking", "<all_urls>"]]
        XCTAssertEqual(WebExtensionCompatibility.assess(manifest: blocker).verdict, .incompatible)
    }

    func testInstallPromptWarnsBeforeAddingIncompatibleExtensions() throws {
        let manifest = try WebExtensionManifest(json: ["name": "uBlock Origin", "version": "1.60",
                                                       "permissions": ["webRequestBlocking"]])
        let report = WebExtensionCompatibility.assess(manifest: manifest.raw)
        let prompt = WebExtensionInstaller.confirmation(for: manifest, compatibility: report, permissions: [])
        XCTAssertEqual(prompt.title, "uBlock Origin won't work in Culpeo")
        XCTAssertEqual(prompt.addTitle, "Add Anyway")
        XCTAssertTrue(prompt.isRisky)
        XCTAssertTrue(prompt.message.contains("AdGuard"))
    }

    func testInstallPromptForWorkingAndUnavailableAddOns() throws {
        let manifest = try WebExtensionManifest(json: ["name": "Notes", "version": "2.0", "permissions": ["storage"]])
        let report = WebExtensionCompatibility.assess(manifest: manifest.raw)
        let works = WebExtensionInstaller.confirmation(for: manifest, compatibility: report, permissions: [])
        XCTAssertEqual(works.title, "Add Notes?")
        XCTAssertTrue(works.message.contains("Works in Culpeo"))
        XCTAssertFalse(works.isRisky)
        let theme = WebExtensionCompatibility.Report(verdict: .unsupportedType,
                                                     notes: ["Themes aren't supported in Culpeo."])
        XCTAssertNil(WebExtensionInstaller.confirmation(for: manifest, compatibility: theme, permissions: []).addTitle)
    }

    func testOnlyTheStoreGetsVerdicts() {
        XCTAssertTrue(WebExtensionStoreLabels.isStoreHost("addons.mozilla.org"))
        XCTAssertFalse(WebExtensionStoreLabels.isStoreHost("addons.mozilla.org.evil.com"))
        XCTAssertFalse(WebExtensionStoreLabels.isStoreHost("example.com"))
    }
}
