// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// A filter list Flameferret can subscribe to.
struct AdGuardFilter: Codable, Equatable, Sendable {
    enum Group: String, Codable, CaseIterable, Sendable {
        case ads
        case privacy
        case annoyances
        case custom

        var title: String {
            switch self {
            case .ads: return "Ads"
            case .privacy: return "Privacy"
            case .annoyances: return "Annoyances"
            case .custom: return "Custom Lists"
            }
        }
    }

    let id: String
    let name: String
    let summary: String
    let url: URL
    let group: Group
}

/// AdGuard's filter lists, using the builds AdGuard optimizes for WebKit content blockers.
enum AdGuardFilterCatalog {
    private static func adguard(_ number: Int,
                                _ name: String,
                                _ summary: String,
                                _ group: AdGuardFilter.Group) -> AdGuardFilter {
        let url = URL(string: "https://filters.adtidy.org/extension/safari/filters/\(number)_optimized.txt")!
        return AdGuardFilter(id: "adguard-\(number)", name: name, summary: summary, url: url, group: group)
    }

    static let builtIn: [AdGuardFilter] = [
        adguard(2, "AdGuard Base", "Removes ads from websites in English and other languages.", .ads),
        adguard(11, "AdGuard Mobile Ads", "Blocks ad networks used on mobile sites.", .ads),
        adguard(3, "AdGuard Tracking Protection", "Blocks analytics and tracking scripts.", .privacy),
        adguard(4, "AdGuard Social Media", "Removes social widgets such as Like and Share buttons.", .privacy),
        adguard(18, "AdGuard Cookie Notices", "Hides cookie consent banners.", .annoyances),
        adguard(19, "AdGuard Popups", "Blocks pop-ups and newsletter prompts.", .annoyances),
        adguard(20, "AdGuard Mobile App Banners", "Hides \"open in app\" banners.", .annoyances),
        adguard(21, "AdGuard Other Annoyances", "Removes other irritating page elements.", .annoyances),
        adguard(22, "AdGuard Widgets", "Removes chat, support and other third-party widgets.", .annoyances)
    ]

    static let defaultEnabledIDs: Set<String> = ["adguard-2", "adguard-11", "adguard-3", "adguard-18", "adguard-19",
                                                 "adguard-20"]

    static func customFilter(url: URL, name: String? = nil) -> AdGuardFilter {
        return AdGuardFilter(id: "custom-" + url.absoluteString,
                             name: name ?? url.host ?? url.absoluteString,
                             summary: url.absoluteString,
                             url: url,
                             group: .custom)
    }
}

/// Builds rule text from Flameferret's own settings.
enum AdGuardRuleBuilder {
    /// Normalizes something a person typed ("https://www.Example.com/page", "example.com") to a hostname.
    static func hostname(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let host = URL(string: candidate)?.host, host.contains("."), !host.contains(" ") else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Rules that turn all filtering off for the allowlisted sites and their subdomains.
    static func allowlistRules(_ hosts: [String]) -> [String] {
        return hosts.flatMap { host in
            ["@@||\(host)^$document", "@@||\(host)^$elemhide,jsinject,generichide"]
        }
    }

    static func isAllowlisted(_ url: URL, hosts: [String]) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func userRuleLines(_ text: String) -> [String] {
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("!") }
    }
}
