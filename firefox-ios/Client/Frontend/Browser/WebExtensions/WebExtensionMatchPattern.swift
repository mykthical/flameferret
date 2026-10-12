// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// A WebExtension match pattern such as `*://*.example.com/*` or `<all_urls>`.
/// https://developer.mozilla.org/docs/Mozilla/Add-ons/WebExtensions/Match_patterns
struct WebExtensionMatchPattern: Equatable {
    let pattern: String
    let regexSource: String

    private static let allURLSchemes = ["http", "https", "ws", "wss", "ftp", "data", "file"]

    init?(_ pattern: String) {
        self.pattern = pattern
        guard let source = WebExtensionMatchPattern.makeRegex(pattern) else { return nil }
        self.regexSource = source
    }

    func matches(_ url: URL) -> Bool {
        return matches(url.absoluteString)
    }

    func matches(_ urlString: String) -> Bool {
        return urlString.range(of: regexSource, options: .regularExpression) != nil
    }

    var matchesAllHosts: Bool {
        return pattern == "<all_urls>" || pattern.hasPrefix("*://*/") || pattern.hasPrefix("http://*/")
            || pattern.hasPrefix("https://*/")
    }

    private static func makeRegex(_ pattern: String) -> String? {
        if pattern == "<all_urls>" {
            return "^(" + allURLSchemes.joined(separator: "|") + "):"
        }
        guard let schemeEnd = pattern.range(of: "://") else {
            if pattern.hasPrefix("data:") || pattern.hasPrefix("about:") {
                return "^" + globToRegex(pattern) + "$"
            }
            return nil
        }

        let scheme = String(pattern[pattern.startIndex..<schemeEnd.lowerBound])
        let rest = String(pattern[schemeEnd.upperBound...])
        let schemeRegex: String
        switch scheme {
        case "*":
            schemeRegex = "(https?|wss?)"
        case "http", "https", "ws", "wss", "ftp", "file", "moz-extension":
            schemeRegex = scheme
        default:
            return nil
        }

        let host: String
        let path: String
        if let slash = rest.firstIndex(of: "/") {
            host = String(rest[rest.startIndex..<slash])
            path = String(rest[slash...])
        } else {
            if scheme == "file" { return nil }
            host = rest
            path = "/*"
        }

        let hostRegex: String
        if host == "*" {
            hostRegex = "[^/]*"
        } else if host.hasPrefix("*.") {
            let base = NSRegularExpression.escapedPattern(for: String(host.dropFirst(2)))
            hostRegex = "([^/@]*\\.)?" + base + "(:[0-9]+)?"
        } else if host.contains("*") {
            return nil
        } else {
            hostRegex = NSRegularExpression.escapedPattern(for: host) + "(:[0-9]+)?"
        }

        return "^" + schemeRegex + "://" + hostRegex + globToRegex(path) + "$"
    }

    /// Converts a `*`-glob to a regular expression body (no anchors).
    static func globToRegex(_ glob: String) -> String {
        return glob.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*")
    }

    /// Converts an `include_globs`/`exclude_globs` entry (supports `*` and `?`) to a regular expression.
    static func userScriptGlobToRegex(_ glob: String) -> String {
        var result = "^"
        for character in glob {
            switch character {
            case "*": result += ".*"
            case "?": result += "."
            default: result += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return result + "$"
    }
}
