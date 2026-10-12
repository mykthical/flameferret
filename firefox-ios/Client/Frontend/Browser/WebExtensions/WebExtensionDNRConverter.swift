// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Translates `declarativeNetRequest` rules into WebKit content-blocker rules.
/// Supported actions: block, allow, allowAllRequests and upgradeScheme. Redirect and
/// modifyHeaders have no WebKit equivalent and are skipped.
enum WebExtensionDNRConverter {
    struct Output {
        var rules: [[String: Any]]
        var skipped: Int
    }

    private static let resourceTypeMap: [String: [String]] = [
        "main_frame": ["document"],
        "sub_frame": ["document"],
        "stylesheet": ["style-sheet"],
        "script": ["script"],
        "image": ["image"],
        "imageset": ["image"],
        "font": ["font"],
        "object": ["other"],
        "xmlhttprequest": ["fetch"],
        "ping": ["ping"],
        "beacon": ["ping"],
        "csp_report": ["other"],
        "media": ["media"],
        "websocket": ["websocket"],
        "webtransport": ["other"],
        "webbundle": ["other"],
        "other": ["other"]
    ]

    private static let allWebKitTypes = ["document", "image", "style-sheet", "script", "font",
                                         "raw", "svg-document", "media", "popup", "ping", "fetch",
                                         "websocket", "other"]

    static func convert(_ dnrRules: [[String: Any]]) -> Output {
        // WebKit applies rules in order and "ignore-previous-rules" only cancels earlier ones, so
        // emit lower priorities first and allow rules after block rules of the same priority.
        let sorted = dnrRules.sorted { lhs, rhs in
            let lp = lhs["priority"] as? Int ?? 1
            let rp = rhs["priority"] as? Int ?? 1
            if lp != rp { return lp < rp }
            return actionRank(lhs) < actionRank(rhs)
        }
        var output = Output(rules: [], skipped: 0)
        for rule in sorted {
            let converted = convertRule(rule)
            if converted.isEmpty {
                output.skipped += 1
            } else {
                output.rules.append(contentsOf: converted)
            }
        }
        return output
    }

    private static func actionRank(_ rule: [String: Any]) -> Int {
        let type = (rule["action"] as? [String: Any])?["type"] as? String ?? ""
        switch type {
        case "block": return 0
        case "upgradeScheme": return 1
        default: return 2
        }
    }

    static func convertRule(_ rule: [String: Any]) -> [[String: Any]] {
        guard let action = rule["action"] as? [String: Any],
              let actionType = action["type"] as? String else { return [] }
        let condition = rule["condition"] as? [String: Any] ?? [:]

        let webKitAction: String
        switch actionType {
        case "block": webKitAction = "block"
        case "allow", "allowAllRequests": webKitAction = "ignore-previous-rules"
        case "upgradeScheme": webKitAction = "make-https"
        default: return []
        }

        var filters: [String] = []
        if let regex = condition["regexFilter"] as? String {
            guard let sanitized = sanitizeRegex(regex) else { return [] }
            filters = [sanitized]
        } else if let urlFilter = condition["urlFilter"] as? String, !urlFilter.isEmpty {
            guard let regex = urlFilterToRegex(urlFilter) else { return [] }
            filters = [regex]
        } else {
            filters = [".*"]
        }

        let requestDomains = (condition["requestDomains"] as? [String]) ?? []
        if !requestDomains.isEmpty {
            filters = requestDomains.compactMap { domain -> String? in
                guard domain.allSatisfy({ $0.isASCII }) else { return nil }
                let escaped = NSRegularExpression.escapedPattern(for: domain.lowercased())
                if filters == [".*"] {
                    return "^[a-z][a-z0-9+.-]*://([^/:]*\\.)?\(escaped)[:/]"
                }
                // Keep the original filter but require the request host; WebKit lacks AND across filters,
                // so the request-domain anchored form is the conservative choice.
                return "^[a-z][a-z0-9+.-]*://([^/:]*\\.)?\(escaped)[:/].*"
            }
            if filters.isEmpty { return [] }
        }

        var trigger: [String: Any] = [:]
        if condition["isUrlFilterCaseSensitive"] as? Bool == true {
            trigger["url-filter-is-case-sensitive"] = true
        }

        var resourceTypes = (condition["resourceTypes"] as? [String] ?? [])
            .flatMap { resourceTypeMap[$0] ?? [] }
        if actionType == "allowAllRequests" {
            resourceTypes = []
        }
        let excludedTypes = Set((condition["excludedResourceTypes"] as? [String] ?? [])
            .flatMap { resourceTypeMap[$0] ?? [] })
        if !excludedTypes.isEmpty {
            let base = resourceTypes.isEmpty ? allWebKitTypes : resourceTypes
            resourceTypes = base.filter { !excludedTypes.contains($0) }
            if resourceTypes.isEmpty { return [] }
        }
        if !resourceTypes.isEmpty {
            trigger["resource-type"] = Array(Set(resourceTypes)).sorted()
        }

        let includeDomains = ((condition["initiatorDomains"] ?? condition["domains"]) as? [String]) ?? []
        let excludeDomains = ((condition["excludedInitiatorDomains"] ?? condition["excludedDomains"]) as? [String]) ?? []
        if !includeDomains.isEmpty {
            let list = includeDomains.filter { $0.allSatisfy { $0.isASCII } }.map { "*" + $0.lowercased() }
            if list.isEmpty { return [] }
            trigger["if-domain"] = list
        } else if !excludeDomains.isEmpty {
            let list = excludeDomains.filter { $0.allSatisfy { $0.isASCII } }.map { "*" + $0.lowercased() }
            if !list.isEmpty { trigger["unless-domain"] = list }
        }

        if let domainType = condition["domainType"] as? String {
            trigger["load-type"] = [domainType == "thirdParty" ? "third-party" : "first-party"]
        }

        return filters.map { filter in
            var ruleTrigger = trigger
            ruleTrigger["url-filter"] = filter
            return ["trigger": ruleTrigger, "action": ["type": webKitAction]]
        }
    }

    /// Converts Adblock-style `urlFilter` syntax (`||`, `|`, `^`, `*`) to a WebKit-compatible regex.
    static func urlFilterToRegex(_ filter: String) -> String? {
        guard filter.allSatisfy({ $0.isASCII }) else { return nil }
        var pattern = filter
        var prefix = ""
        var suffix = ""

        if pattern.hasPrefix("||") {
            pattern.removeFirst(2)
            prefix = "^[a-z][a-z0-9+.-]*://([^/:]*\\.)?"
        } else if pattern.hasPrefix("|") {
            pattern.removeFirst()
            prefix = "^"
        }
        if pattern.hasSuffix("|") {
            pattern.removeLast()
            suffix = "$"
        }

        var body = ""
        let characters = Array(pattern)
        for (index, character) in characters.enumerated() {
            switch character {
            case "*":
                body += ".*"
            case "^":
                if index == characters.count - 1 && suffix.isEmpty {
                    body += "([^a-zA-Z0-9_.%-].*)?$"
                } else {
                    body += "[^a-zA-Z0-9_.%-]"
                }
            default:
                body += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        let result = prefix + body + suffix
        return result.isEmpty ? ".*" : result
    }

    /// WebKit's content-blocker regex engine has no alternation, quantifier ranges, backreferences,
    /// word boundaries or lookarounds. Rewrite the easy cases and reject the rest.
    static func sanitizeRegex(_ regex: String) -> String? {
        guard regex.allSatisfy({ $0.isASCII }) else { return nil }
        var result = regex
            .replacingOccurrences(of: "\\d", with: "[0-9]")
            .replacingOccurrences(of: "\\w", with: "[A-Za-z0-9_]")
            .replacingOccurrences(of: "\\/", with: "/")
        let unsupported = ["|", "{", "\\b", "\\B", "(?", "\\s", "\\S", "\\W", "\\D", "\\1", "\\2"]
        // Escaped pipes are literal and fine; strip them before checking.
        let probe = result.replacingOccurrences(of: "\\|", with: "")
        if unsupported.contains(where: { probe.contains($0) }) { return nil }
        if result.isEmpty { result = ".*" }
        return result
    }
}
