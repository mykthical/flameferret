// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

@MainActor
final class WebExtensionPackageTests: XCTestCase {
    // A small MV2 package with a localized name, a content script, a popup and a background script.
    private let fixture = [
        "UEsDBBQAAAAAAAAAIQDWKHwh0QEAANEBAAANAAAAbWFuaWZlc3QuanNvbi8vIGNvbW1lbnQgYWxsb3dlZAp7Im1hbmlmZXN0X3Zl",
        "cnNpb24iOiAyLCAibmFtZSI6ICJfX01TR19leHROYW1lX18iLCAidmVyc2lvbiI6ICIxLjIuMyIsICJkZWZhdWx0X2xvY2FsZSI6",
        "ICJlbiIsICJicm93c2VyX3NwZWNpZmljX3NldHRpbmdzIjogeyJnZWNrbyI6IHsiaWQiOiAiZml4dHVyZUBmbGFtZWZlcnJldC50",
        "ZXN0In19LCAicGVybWlzc2lvbnMiOiBbInN0b3JhZ2UiLCAidGFicyIsICI8YWxsX3VybHM+Il0sICJjb250ZW50X3NjcmlwdHMi",
        "OiBbeyJtYXRjaGVzIjogWyIqOi8vKi5leGFtcGxlLmNvbS8qIl0sICJqcyI6IFsiY29udGVudC5qcyJdLCAicnVuX2F0IjogImRv",
        "Y3VtZW50X3N0YXJ0In1dLCAiYnJvd3Nlcl9hY3Rpb24iOiB7ImRlZmF1bHRfcG9wdXAiOiAicG9wdXAuaHRtbCIsICJkZWZhdWx0",
        "X3RpdGxlIjogIkZpeHR1cmUifSwgImJhY2tncm91bmQiOiB7InNjcmlwdHMiOiBbImJnLmpzIl19fVBLAwQUAAAAAACWAkxdP++y",
        "ujEAAAAxAAAACgAAAGNvbnRlbnQuanNkb2N1bWVudC5kb2N1bWVudEVsZW1lbnQuZGF0YXNldC5maXh0dXJlID0gJ3llcyc7UEsD",
        "BBQAAAAAAJYCTF0KAFSHLQAAAC0AAAAZAAAAX2xvY2FsZXMvZW4vbWVzc2FnZXMuanNvbnsiZXh0TmFtZSI6IHsibWVzc2FnZSI6",
        "ICJGaXh0dXJlIEV4dGVuc2lvbiJ9fVBLAwQUAAAAAACWAkxd+lOCWDAAAAAwAAAABQAAAGJnLmpzYnJvd3Nlci5ydW50aW1lLm9u",
        "TWVzc2FnZS5hZGRMaXN0ZW5lcigoKSA9PiB7fSk7UEsBAhQDFAAAAAAAAAAhANYofCHRAQAA0QEAAA0AAAAAAAAAAAAAAIABAAAA",
        "AG1hbmlmZXN0Lmpzb25QSwECFAMUAAAAAACWAkxdP++yujEAAAAxAAAACgAAAAAAAAAAAAAAgAH8AQAAY29udGVudC5qc1BLAQIU",
        "AxQAAAAAAJYCTF0KAFSHLQAAAC0AAAAZAAAAAAAAAAAAAACAAVUCAABfbG9jYWxlcy9lbi9tZXNzYWdlcy5qc29uUEsBAhQDFAAA",
        "AAAAlgJMXfpTglgwAAAAMAAAAAUAAAAAAAAAAAAAAIABuQIAAGJnLmpzUEsFBgAAAAAEAAQA7QAAAAwDAAAAAA=="
    ].joined()

    private func makeStore() -> (WebExtensionStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (WebExtensionStore(rootDirectory: directory), directory)
    }

    func testArchiveListsEntries() throws {
        let archive = try WebExtensionArchive(data: try XCTUnwrap(Data(base64Encoded: fixture)))
        XCTAssertEqual(Set(archive.entries.map { $0.path }),
                       ["manifest.json", "content.js", "_locales/en/messages.json", "bg.js"])
    }

    func testRejectsNonArchive() {
        XCTAssertThrowsError(try WebExtensionArchive(data: Data("not a zip".utf8)))
    }

    func testInstallParsesManifestAndLocalizesName() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = try store.install(packageData: try XCTUnwrap(Data(base64Encoded: fixture)), suggestedName: nil)
        XCTAssertEqual(installed.id, "fixture@flameferret.test")
        XCTAssertEqual(installed.displayName, "Fixture Extension")
        XCTAssertEqual(installed.manifest.version, "1.2.3")
        XCTAssertTrue(installed.hasPopup)
        XCTAssertTrue(installed.hasBackground)
        XCTAssertEqual(installed.manifest.permissions, ["storage", "tabs"])
        XCTAssertEqual(installed.manifest.hostPermissions, ["<all_urls>"])
        XCTAssertEqual(installed.manifest.contentScripts.first?.runAt, .documentStart)
        XCTAssertEqual(installed.readText("content.js"), "document.documentElement.dataset.fixture = 'yes';")
        XCTAssertNil(installed.fileURL(for: "../../escape"))
    }

    func testReinstallKeepsUUIDAndStorage() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try XCTUnwrap(Data(base64Encoded: fixture))
        let first = try store.install(packageData: data, suggestedName: nil)
        store.writeStorage(["key": "value"], uuid: first.uuid, area: "local")
        let second = try store.install(packageData: data, suggestedName: nil)
        XCTAssertEqual(first.uuid, second.uuid)
        XCTAssertEqual(store.loadRecords().count, 1)
        XCTAssertEqual(store.storage(uuid: second.uuid, area: "local")["key"] as? String, "value")
        store.uninstall(uuid: second.uuid)
        XCTAssertTrue(store.loadRecords().isEmpty)
    }

    func testManifestCommentsAreStripped() throws {
        let text = "{ // name\n \"name\": \"A // not a comment\", /* block */ \"version\": \"1\" }"
        let data = WebExtensionManifest.stripJSONComments(Data(text.utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "A // not a comment")
    }
}
