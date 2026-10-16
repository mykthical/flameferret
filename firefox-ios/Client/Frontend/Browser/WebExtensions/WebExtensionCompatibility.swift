// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Predicts how well an add-on from addons.mozilla.org will run in Ferret, from the type and permissions
/// the store lists for it. Permissions are a good proxy for the APIs an extension relies on.
enum WebExtensionCompatibility {
    enum Verdict: String, Equatable {
        case works
        case partial
        case incompatible
        case unsupportedType

        var label: String {
            switch self {
            case .works: return "Works in Ferret"
            case .partial: return "Partly works in Ferret"
            case .incompatible: return "Won't work in Ferret"
            case .unsupportedType: return "Not available in Ferret"
            }
        }
    }

    struct Report: Equatable {
        let verdict: Verdict
        /// Plain-language reasons, most important first.
        let notes: [String]

        var dictionary: [String: Any] {
            return ["verdict": verdict.rawValue, "label": verdict.label, "notes": notes]
        }
    }

    /// Permissions Ferret's engine implements.
    static let supported: Set<String> = [
        "activeTab", "alarms", "background", "clipboardRead", "clipboardWrite", "cookies",
        "declarativeNetRequest", "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess",
        "downloads", "geolocation", "i18n", "idle", "management", "notifications", "offscreen", "permissions",
        "scripting", "search", "storage", "tabs", "unlimitedStorage", "webNavigation"
    ]

    /// Permissions Ferret accepts but can't fully honor: the extension runs, minus that feature.
    static let limited: [String: String] = [
        "bookmarks": "It can't read or change your bookmarks.",
        "browsingData": "It can't clear browsing data.",
        "commands": "Its keyboard shortcuts won't work.",
        "contextMenus": "Its right-click menu items won't appear.",
        "contextualIdentities": "Firefox containers aren't available.",
        "dns": "It can't look up DNS records directly.",
        "downloads.open": "It can't open downloaded files.",
        "find": "It can't search the text of pages for you.",
        "history": "It can't read your browsing history.",
        "menus": "Its right-click menu items won't appear.",
        "pageCapture": "It can't save whole pages.",
        "privacy": "It can't change browser privacy settings.",
        "sessions": "It can't restore recently closed tabs.",
        "tabHide": "It can't hide tabs.",
        "theme": "It can't change Ferret's look.",
        "topSites": "It can't read your most visited sites.",
        "webRequest": "It can't watch network requests, so features that rely on that won't work."
    ]

    /// Permissions for things iOS or Ferret can't do at all; an extension that requires one won't work.
    static let unsupported: [String: String] = [
        "debugger": "It needs browser debugging access, which isn't available on iPhone.",
        "geckoProfiler": "It uses Firefox-only internals.",
        "mozillaAddons": "It uses Firefox-only internals.",
        "nativeMessaging": "It works with a companion app on a computer, which isn't possible on iPhone.",
        "pkcs11": "It needs access to security devices.",
        "proxy": "It needs to control the browser's proxy settings. For NordVPN, use Settings → Privacy → "
            + "NordVPN Proxy instead.",
        "telemetry": "It uses Firefox-only internals.",
        "userScripts": "It needs the user scripts API, which Ferret doesn't support yet.",
        "webRequestBlocking": "It blocks or changes requests as they happen, which iOS doesn't allow. "
            + "For ad blocking, use Ferret's built-in AdGuard filters.",
        "webRequestFilterResponse": "It rewrites page responses, which iOS doesn't allow."
    ]

    static func assess(type: String,
                       permissions: [String],
                       optionalPermissions: [String] = []) -> Report {
        guard type == "extension" else {
            return Report(verdict: .unsupportedType, notes: [typeNote(type)])
        }
        let required = apiPermissions(permissions)
        let optional = apiPermissions(optionalPermissions).filter { !required.contains($0) }

        let blockers = required.compactMap { unsupported[$0] }
        let optionalBlockers = optional.compactMap { name in unsupported[name].map { "Optional feature: " + $0 } }
        let limits = (required + optional).compactMap { limited[$0] }
        let unknown = required.filter { supported.contains($0) == false && limited[$0] == nil && unsupported[$0] == nil }

        var notes = unique(blockers + optionalBlockers + limits)
        if !unknown.isEmpty {
            notes.append("It uses features Ferret may not support: \(unknown.joined(separator: ", ")).")
        }
        if !blockers.isEmpty {
            return Report(verdict: .incompatible, notes: notes)
        }
        return Report(verdict: notes.isEmpty ? .works : .partial, notes: notes)
    }

    /// Reads the add-on JSON from addons.mozilla.org's v5 API (or the subset Ferret's store script sends).
    static func assess(amoAddon json: [String: Any]) -> Report {
        let file = ((json["current_version"] as? [String: Any])?["file"] as? [String: Any]) ?? json
        return assess(type: json["type"] as? String ?? "extension",
                      permissions: file["permissions"] as? [String] ?? [],
                      optionalPermissions: file["optional_permissions"] as? [String] ?? [])
    }

    /// Reads an extension's own manifest.json, before it's installed.
    static func assess(manifest json: [String: Any]) -> Report {
        let runsCode = json["background"] != nil || json["content_scripts"] != nil || json["action"] != nil
            || json["browser_action"] != nil
        if json["theme"] != nil && !runsCode {
            return Report(verdict: .unsupportedType, notes: [typeNote("statictheme")])
        }
        let strings = { (key: String) in (json[key] as? [Any] ?? []).compactMap { $0 as? String } }
        let report = assess(type: "extension",
                            permissions: strings("permissions"),
                            optionalPermissions: strings("optional_permissions"))
        guard json["devtools_page"] != nil else { return report }
        let notes = report.notes + ["Its developer tools panel won't appear."]
        return Report(verdict: report.verdict == .works ? .partial : report.verdict, notes: notes)
    }

    /// Drops host patterns ("<all_urls>", "https://*/*"), which Ferret honors, leaving API permissions.
    static func apiPermissions(_ permissions: [String]) -> [String] {
        return unique(permissions.filter { !$0.contains("://") && $0 != "<all_urls>" && !$0.isEmpty })
    }

    private static func typeNote(_ type: String) -> String {
        switch type {
        case "statictheme": return "Themes aren't supported in Ferret."
        case "dictionary": return "Spell-check dictionaries aren't supported in Ferret."
        case "language": return "Language packs aren't supported in Ferret."
        default: return "Only extensions can be installed in Ferret."
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
