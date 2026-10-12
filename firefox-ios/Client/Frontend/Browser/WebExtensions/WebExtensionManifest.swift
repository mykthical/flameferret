// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

enum WebExtensionManifestError: LocalizedError {
    case missingManifest
    case invalidJSON(String)
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "The package has no manifest.json, so it isn't a browser extension."
        case .invalidJSON(let detail):
            return "manifest.json couldn't be read: \(detail)"
        case .missingField(let field):
            return "manifest.json is missing \"\(field)\"."
        }
    }
}

/// The parts of manifest.json that Flameferret understands, for both Manifest V2 and V3.
struct WebExtensionManifest {
    enum RunAt: String {
        case documentStart = "document_start"
        case documentEnd = "document_end"
        case documentIdle = "document_idle"
    }

    struct ContentScript {
        let matches: [String]
        let excludeMatches: [String]
        let includeGlobs: [String]
        let excludeGlobs: [String]
        let js: [String]
        let css: [String]
        let runAt: RunAt
        let allFrames: Bool
        let matchAboutBlank: Bool
        let world: String
    }

    struct Background {
        let scripts: [String]
        let page: String?
        let serviceWorker: String?
        let isModule: Bool
    }

    struct Action {
        let defaultPopup: String?
        let defaultTitle: String?
        let defaultIcon: [String: String]
    }

    struct RuleResource {
        let id: String
        let enabled: Bool
        let path: String
    }

    let raw: [String: Any]
    let manifestVersion: Int
    let name: String
    let version: String
    let description: String
    let geckoID: String?
    let defaultLocale: String?
    let icons: [String: String]
    let contentScripts: [ContentScript]
    let background: Background?
    let action: Action?
    let optionsPage: String?
    let optionsOpenInTab: Bool
    let permissions: [String]
    let hostPermissions: [String]
    let ruleResources: [RuleResource]
    let homepageURL: String?

    init(json: [String: Any]) throws {
        raw = json
        manifestVersion = json["manifest_version"] as? Int ?? 2
        guard let name = json["name"] as? String, !name.isEmpty else {
            throw WebExtensionManifestError.missingField("name")
        }
        self.name = name
        version = json["version"] as? String ?? "0"
        description = json["description"] as? String ?? ""
        defaultLocale = json["default_locale"] as? String
        homepageURL = json["homepage_url"] as? String

        let browserSettings = (json["browser_specific_settings"] ?? json["applications"]) as? [String: Any]
        geckoID = (browserSettings?["gecko"] as? [String: Any])?["id"] as? String

        icons = WebExtensionManifest.iconMap(json["icons"])

        contentScripts = (json["content_scripts"] as? [[String: Any]] ?? []).map { entry in
            ContentScript(
                matches: entry["matches"] as? [String] ?? [],
                excludeMatches: entry["exclude_matches"] as? [String] ?? [],
                includeGlobs: entry["include_globs"] as? [String] ?? [],
                excludeGlobs: entry["exclude_globs"] as? [String] ?? [],
                js: entry["js"] as? [String] ?? [],
                css: entry["css"] as? [String] ?? [],
                runAt: RunAt(rawValue: entry["run_at"] as? String ?? "") ?? .documentIdle,
                allFrames: entry["all_frames"] as? Bool ?? false,
                matchAboutBlank: entry["match_about_blank"] as? Bool ?? false,
                world: (entry["world"] as? String ?? "ISOLATED").uppercased()
            )
        }

        if let background = json["background"] as? [String: Any] {
            self.background = Background(
                scripts: background["scripts"] as? [String] ?? [],
                page: background["page"] as? String,
                serviceWorker: background["service_worker"] as? String,
                isModule: (background["type"] as? String) == "module"
            )
        } else {
            self.background = nil
        }

        let actionJSON = (json["action"] ?? json["browser_action"] ?? json["page_action"]) as? [String: Any]
        if let actionJSON {
            var iconMap = WebExtensionManifest.iconMap(actionJSON["default_icon"])
            if iconMap.isEmpty, let single = actionJSON["default_icon"] as? String {
                iconMap = ["32": single]
            }
            action = Action(defaultPopup: actionJSON["default_popup"] as? String,
                            defaultTitle: actionJSON["default_title"] as? String,
                            defaultIcon: iconMap)
        } else {
            action = nil
        }

        if let optionsUI = json["options_ui"] as? [String: Any] {
            optionsPage = optionsUI["page"] as? String
            optionsOpenInTab = optionsUI["open_in_tab"] as? Bool ?? false
        } else {
            optionsPage = json["options_page"] as? String
            optionsOpenInTab = json["options_page"] != nil
        }

        let declaredPermissions = (json["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        let optionalPermissions = (json["optional_permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        let declaredHosts = json["host_permissions"] as? [String] ?? []
        let optionalHosts = json["optional_host_permissions"] as? [String] ?? []
        let allPermissions = declaredPermissions + optionalPermissions
        permissions = allPermissions.filter { !WebExtensionManifest.looksLikeHostPattern($0) }
        hostPermissions = declaredHosts + optionalHosts + allPermissions.filter {
            WebExtensionManifest.looksLikeHostPattern($0)
        }

        let dnr = json["declarative_net_request"] as? [String: Any]
        ruleResources = (dnr?["rule_resources"] as? [[String: Any]] ?? []).compactMap { resource in
            guard let path = resource["path"] as? String else { return nil }
            return RuleResource(id: resource["id"] as? String ?? path,
                                enabled: resource["enabled"] as? Bool ?? true,
                                path: path)
        }
    }

    static func load(from directory: URL) throws -> WebExtensionManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw WebExtensionManifestError.missingManifest
        }
        do {
            let object = try JSONSerialization.jsonObject(with: stripJSONComments(data), options: [])
            guard let json = object as? [String: Any] else {
                throw WebExtensionManifestError.invalidJSON("expected an object")
            }
            return try WebExtensionManifest(json: json)
        } catch let error as WebExtensionManifestError {
            throw error
        } catch {
            throw WebExtensionManifestError.invalidJSON(error.localizedDescription)
        }
    }

    /// The preferred icon path for roughly the requested pixel size.
    func iconPath(preferredSize: Int) -> String? {
        let candidates = icons.isEmpty ? (action?.defaultIcon ?? [:]) : icons
        let sorted = candidates.compactMap { key, value -> (Int, String)? in
            guard let size = Int(key) else { return nil }
            return (size, value)
        }.sorted { $0.0 < $1.0 }
        return (sorted.first { $0.0 >= preferredSize } ?? sorted.last)?.1
    }

    private static func iconMap(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, path) in dictionary {
            if let path = path as? String { result[key] = path }
        }
        return result
    }

    private static func looksLikeHostPattern(_ permission: String) -> Bool {
        return permission == "<all_urls>" || permission.contains("://")
    }

    /// Chrome allows `//` comments in manifest.json; strip them before parsing.
    static func stripJSONComments(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("//") || text.contains("/*") else {
            return data
        }
        var output = ""
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = next
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index = next
            } else if character == "/", next < text.endIndex, text[next] == "/" {
                index = text[next...].firstIndex(of: "\n") ?? text.endIndex
            } else if character == "/", next < text.endIndex, text[next] == "*" {
                let searchStart = text.index(after: next)
                index = text.range(of: "*/", range: searchStart..<text.endIndex)?.upperBound ?? text.endIndex
            } else {
                output.append(character)
                index = next
            }
        }
        return Data(output.utf8)
    }
}

/// Loads `_locales/<lang>/messages.json` and resolves `__MSG_name__` placeholders.
struct WebExtensionLocalization {
    let messages: [String: [String: Any]]
    let language: String

    init(directory: URL, defaultLocale: String?) {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let normalized = preferred.replacingOccurrences(of: "-", with: "_")
        let languageOnly = String(normalized.split(separator: "_").first ?? "en")
        var candidates = [normalized, languageOnly]
        if let defaultLocale { candidates.append(defaultLocale) }
        candidates.append("en")

        var merged: [String: [String: Any]] = [:]
        // Later (more specific) locales win, so iterate from least to most preferred.
        for locale in candidates.reversed() {
            let url = directory.appendingPathComponent("_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: WebExtensionManifest.stripJSONComments(data))
                    as? [String: Any] else { continue }
            for (key, value) in json {
                if let entry = value as? [String: Any] {
                    merged[key.lowercased()] = entry
                }
            }
        }
        messages = merged
        language = preferred
    }

    func message(_ name: String) -> String? {
        return messages[name.lowercased()]?["message"] as? String
    }

    func localize(_ text: String) -> String {
        guard text.contains("__MSG_") else { return text }
        var result = text
        let pattern = "__MSG_([A-Za-z0-9_@]+)__"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: result),
                  let nameRange = Range(match.range(at: 1), in: result) else { continue }
            let replacement = message(String(result[nameRange])) ?? ""
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }

    /// Messages as a JSON-safe dictionary for the JavaScript `i18n` API.
    var jsonMessages: [String: Any] {
        var output: [String: Any] = [:]
        for (key, entry) in messages {
            var item: [String: Any] = ["message": entry["message"] as? String ?? ""]
            if let placeholders = entry["placeholders"] as? [String: Any] {
                item["placeholders"] = placeholders
            }
            output[key] = item
        }
        return output
    }
}
