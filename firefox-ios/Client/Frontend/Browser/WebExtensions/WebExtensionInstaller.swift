// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit

enum WebExtensionInstallerError: LocalizedError {
    case unrecognizedLink
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unrecognizedLink:
            return "Paste an addons.mozilla.org add-on link, a Chrome Web Store link, or a direct .xpi/.crx link."
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        }
    }
}

/// Downloads packages from addons.mozilla.org, the Chrome Web Store or a direct link,
/// confirms with the user and installs them.
@MainActor
final class WebExtensionInstaller {
    static let shared = WebExtensionInstaller()

    private let session = URLSession(configuration: .ephemeral)

    /// Whether a navigation to `url` should be treated as an extension install.
    static func isPackageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "xpi" || ext == "crx" { return true }
        return url.host == "addons.mozilla.org" && url.path.contains("/downloads/file/")
    }

    /// Resolves a pasted link to a direct package download URL.
    func resolvePackageURL(from input: String) async throws -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)"), let host = url.host else {
            throw WebExtensionInstallerError.unrecognizedLink
        }
        if WebExtensionInstaller.isPackageURL(url) { return url }

        if host.hasSuffix("addons.mozilla.org") {
            let parts = url.pathComponents
            guard let addonIndex = parts.firstIndex(of: "addon"), addonIndex + 1 < parts.count else {
                throw WebExtensionInstallerError.unrecognizedLink
            }
            let slug = parts[addonIndex + 1]
            let apiURL = URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/")!
            let (data, _) = try await session.data(from: apiURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["current_version"] as? [String: Any],
                  let file = version["file"] as? [String: Any],
                  let fileURL = (file["url"] as? String).flatMap(URL.init(string:)) else {
                throw WebExtensionInstallerError.downloadFailed("addons.mozilla.org didn't return a package")
            }
            return fileURL
        }

        if host.hasSuffix("chromewebstore.google.com") || host.hasSuffix("chrome.google.com") {
            guard let id = url.pathComponents.first(where: { $0.count == 32 && $0.allSatisfy { ("a"..."p").contains($0) } }),
                  let crx = URL(string: "https://clients2.google.com/service/update2/crx?response=redirect"
                                + "&prodversion=131.0&acceptformat=crx2,crx3&x=id%3D\(id)%26uc") else {
                throw WebExtensionInstallerError.unrecognizedLink
            }
            return crx
        }

        throw WebExtensionInstallerError.unrecognizedLink
    }

    func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebExtensionInstallerError.downloadFailed("HTTP \(http.statusCode)")
        }
        return data
    }

    /// Reads the manifest from a package without installing it.
    func previewManifest(_ data: Data) throws -> WebExtensionManifest {
        let archive = try WebExtensionArchive(data: data)
        let candidates = archive.entries.filter {
            $0.path == "manifest.json" || ($0.path.hasSuffix("/manifest.json") && $0.path.split(separator: "/").count == 2)
        }
        guard let entry = candidates.min(by: { $0.path.count < $1.path.count }) else {
            throw WebExtensionManifestError.missingManifest
        }
        let manifestData = WebExtensionManifest.stripJSONComments(try archive.contents(of: entry))
        guard let json = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw WebExtensionManifestError.invalidJSON("expected an object")
        }
        return try WebExtensionManifest(json: json)
    }

    /// Downloads (if needed), asks for confirmation and installs.
    func installFromURL(_ url: URL, presenter: UIViewController?) {
        let progress = UIAlertController(title: "Downloading extension…", message: nil, preferredStyle: .alert)
        present(progress, fallback: presenter)
        Task {
            do {
                let data = try await download(url)
                progress.dismiss(animated: true) {
                    self.confirmAndInstall(data, suggestedName: url.lastPathComponent, presenter: presenter)
                }
            } catch {
                progress.dismiss(animated: true) {
                    self.showError(error, presenter: presenter)
                }
            }
        }
    }

    func installFromLink(_ input: String, presenter: UIViewController?) {
        Task {
            do {
                let url = try await resolvePackageURL(from: input)
                installFromURL(url, presenter: presenter)
            } catch {
                showError(error, presenter: presenter)
            }
        }
    }

    func confirmAndInstall(_ data: Data, suggestedName: String?, presenter: UIViewController?) {
        let manifest: WebExtensionManifest
        do {
            manifest = try previewManifest(data)
        } catch {
            showError(error, presenter: presenter)
            return
        }
        let confirmation = Self.confirmation(for: manifest,
                                             compatibility: WebExtensionCompatibility.assess(manifest: manifest.raw),
                                             permissions: describePermissions(manifest))
        let alert = UIAlertController(title: confirmation.title, message: confirmation.message, preferredStyle: .alert)
        guard let addTitle = confirmation.addTitle else {
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert, fallback: presenter)
            return
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: addTitle, style: confirmation.isRisky ? .destructive : .default) { _ in
            self.install(data, suggestedName: suggestedName, presenter: presenter)
        })
        present(alert, fallback: presenter)
    }

    private func install(_ data: Data, suggestedName: String?, presenter: UIViewController?) {
        do {
            let installed = try WebExtensionManager.shared.install(packageData: data, suggestedName: suggestedName)
            let done = UIAlertController(title: "\(installed.displayName) was added",
                                         message: "Reload open pages to use it there. Manage it from Menu → Extensions.",
                                         preferredStyle: .alert)
            done.addAction(UIAlertAction(title: "OK", style: .default))
            present(done, fallback: presenter)
        } catch {
            showError(error, presenter: presenter)
        }
    }

    /// What the install prompt says. `addTitle` is nil when the add-on can't be installed at all.
    struct Confirmation: Equatable {
        let title: String
        let message: String
        let addTitle: String?
        let isRisky: Bool
    }

    nonisolated static func confirmation(for manifest: WebExtensionManifest,
                                         compatibility: WebExtensionCompatibility.Report,
                                         permissions: [String]) -> Confirmation {
        let name = manifest.name.hasPrefix("__MSG_") ? "this extension" : manifest.name
        let reasons = compatibility.notes.map { "• " + $0 }.joined(separator: "\n")
        let access = permissions.isEmpty
            ? "It doesn't request any special permissions."
            : "It will be able to:\n• " + permissions.joined(separator: "\n• ")
        let version = "Version \(manifest.version)"
        switch compatibility.verdict {
        case .works:
            return Confirmation(title: "Add \(name)?",
                                message: "\(version) · Works in Culpeo\n\n\(access)",
                                addTitle: "Add",
                                isRisky: false)
        case .partial:
            return Confirmation(title: "Add \(name)?",
                                message: "\(version) · Partly works in Culpeo\n\(reasons)\n\n\(access)",
                                addTitle: "Add",
                                isRisky: false)
        case .incompatible:
            return Confirmation(title: "\(manifest.name.hasPrefix("__MSG_") ? "This extension" : name) won't work in Culpeo",
                                message: "\(reasons)\n\nYou can still add it, but it probably won't do what you "
                                    + "expect.\n\n\(access)",
                                addTitle: "Add Anyway",
                                isRisky: true)
        case .unsupportedType:
            return Confirmation(title: "Not available in Culpeo", message: reasons, addTitle: nil, isRisky: false)
        }
    }

    private func present(_ controller: UIViewController, fallback: UIViewController?) {
        (WebExtensionManager.shared.topViewController() ?? fallback)?.present(controller, animated: true)
    }

    func describePermissions(_ manifest: WebExtensionManifest) -> [String] {
        var lines: [String] = []
        let hosts = manifest.hostPermissions + manifest.contentScripts.flatMap { $0.matches }
        if hosts.contains(where: { WebExtensionMatchPattern($0)?.matchesAllHosts ?? false }) {
            lines.append("Access your data for all websites")
        } else if !hosts.isEmpty {
            let names = Set(hosts.compactMap { URL(string: $0.replacingOccurrences(of: "*.", with: ""))?.host })
            lines.append("Access your data for " + names.sorted().prefix(4).joined(separator: ", ")
                         + (names.count > 4 ? " and \(names.count - 4) more" : ""))
        }
        let descriptions: [String: String] = [
            "tabs": "Access browser tabs",
            "history": "Access browsing history",
            "bookmarks": "Read and modify bookmarks",
            "cookies": "Read and change cookies",
            "downloads": "Download files",
            "notifications": "Display notifications to you",
            "declarativeNetRequest": "Block content on any page",
            "declarativeNetRequestWithHostAccess": "Block content on any page",
            "webRequestBlocking": "Block content on any page",
            "clipboardWrite": "Input data to the clipboard",
            "clipboardRead": "Get data from the clipboard",
            "geolocation": "Access your location",
            "management": "Monitor extension usage"
        ]
        for permission in manifest.permissions {
            if let text = descriptions[permission], !lines.contains(text) { lines.append(text) }
        }
        return lines
    }

    private func showError(_ error: Error, presenter: UIViewController?) {
        let alert = UIAlertController(title: "Couldn't add extension",
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, fallback: presenter)
    }
}
