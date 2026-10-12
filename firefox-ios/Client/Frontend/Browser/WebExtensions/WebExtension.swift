// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import WebKit

/// An installed extension: its unpacked files, parsed manifest and runtime settings.
@MainActor
final class WebExtension {
    /// The extension ID (`browser_specific_settings.gecko.id`, or a generated one).
    let id: String
    /// Per-install random UUID used as the host of `moz-extension://` URLs, like Firefox.
    let uuid: String
    let rootDirectory: URL
    let filesDirectory: URL
    let manifest: WebExtensionManifest
    let localization: WebExtensionLocalization
    var isEnabled: Bool
    let installedAt: Date

    init(id: String, uuid: String, rootDirectory: URL, isEnabled: Bool, installedAt: Date) throws {
        self.id = id
        self.uuid = uuid
        self.rootDirectory = rootDirectory
        self.filesDirectory = rootDirectory.appendingPathComponent("files", isDirectory: true)
        self.manifest = try WebExtensionManifest.load(from: filesDirectory)
        self.localization = WebExtensionLocalization(directory: filesDirectory, defaultLocale: manifest.defaultLocale)
        self.isEnabled = isEnabled
        self.installedAt = installedAt
    }

    var displayName: String { localization.localize(manifest.name) }
    var displayDescription: String { localization.localize(manifest.description) }
    var baseURL: URL { URL(string: "\(WebExtensionURLSchemeHandler.scheme)://\(uuid)/")! }

    /// Name of the isolated JavaScript world this extension's content scripts run in.
    var contentWorldName: String { "flameferret-ext-\(uuid)" }
    var contentWorld: WKContentWorld { .world(name: contentWorldName) }

    func url(for path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    func fileURL(for path: String) -> URL? {
        let decoded = path.removingPercentEncoding ?? path
        let trimmed = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        let candidate = filesDirectory.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path.hasPrefix(filesDirectory.standardizedFileURL.path) else { return nil }
        return candidate
    }

    func readText(_ path: String) -> String? {
        guard let url = fileURL(for: path), let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func icon(preferredSize: Int) -> UIImage? {
        guard let path = manifest.iconPath(preferredSize: preferredSize),
              let url = fileURL(for: path),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data, scale: UIScreen.main.scale)
    }

    var hasPopup: Bool { manifest.action?.defaultPopup != nil }
    var hasAction: Bool { manifest.action != nil }
    var hasOptions: Bool { manifest.optionsPage != nil }
    var hasBackground: Bool {
        guard let background = manifest.background else { return false }
        return !background.scripts.isEmpty || background.page != nil || background.serviceWorker != nil
    }

    func hasPermission(_ name: String) -> Bool {
        return manifest.permissions.contains(name)
    }

    /// Whether the extension may script or read `url` (host permissions plus content script matches).
    func hasHostAccess(to url: URL) -> Bool {
        if url.scheme == WebExtensionURLSchemeHandler.scheme { return url.host == uuid }
        let patterns = manifest.hostPermissions + manifest.contentScripts.flatMap { $0.matches }
        if hasPermission("activeTab") { return true }
        return patterns.compactMap { WebExtensionMatchPattern($0) }.contains { $0.matches(url) }
    }
}
