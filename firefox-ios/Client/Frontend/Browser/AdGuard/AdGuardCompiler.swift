// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import class ContentBlockerConverter.ContentBlockerConverter
import enum ContentBlockerConverter.SafariVersion
import class FilterEngine.WebExtension

/// Converts AdGuard filter lists into WebKit content-blocker JSON and the "advanced" rules
/// (scriptlets, scripts, extended CSS) that Flameferret applies itself. Runs off the main thread.
enum AdGuardCompiler {
    struct Group: Sendable {
        let id: String
        let json: String
        let ruleCount: Int
    }

    struct Output: Sendable {
        let groups: [Group]
        let advancedRules: String
        let advancedRuleCount: Int
        let skippedRuleCount: Int
    }

    /// One content blocker per filter group keeps each under WebKit's 150,000-rule limit. The
    /// person's own rules and allowlist go into every group, because an exception only cancels
    /// blocking rules compiled into the same content blocker.
    static func compile(filterTexts: [(AdGuardFilter.Group, String)],
                        userRules: [String],
                        allowlistRules: [String]) -> Output {
        let converter = ContentBlockerConverter()
        let version = SafariVersion.autodetect()
        let shared = userRules + allowlistRules

        var grouped: [AdGuardFilter.Group: [String]] = [:]
        for (group, text) in filterTexts {
            grouped[group, default: []].append(contentsOf: text.components(separatedBy: .newlines))
        }
        if grouped.isEmpty && !userRules.isEmpty {
            grouped[.custom] = []
        }

        var groups: [Group] = []
        var advancedLines: [String] = []
        var seenAdvanced = Set<String>()
        var skipped = 0

        for group in AdGuardFilter.Group.allCases {
            guard let lines = grouped[group] else { continue }
            let result = converter.convertArray(rules: lines + shared,
                                                safariVersion: version,
                                                advancedBlocking: true)
            skipped += result.discardedSafariRules + result.errorsCount
            if result.safariRulesCount > 0 {
                groups.append(Group(id: "adguard-\(group.rawValue)",
                                    json: result.safariRulesJSON,
                                    ruleCount: result.safariRulesCount))
            }
            for line in (result.advancedRulesText ?? "").components(separatedBy: "\n") where !line.isEmpty {
                if seenAdvanced.insert(line).inserted {
                    advancedLines.append(line)
                }
            }
        }

        return Output(groups: groups,
                      advancedRules: advancedLines.joined(separator: "\n"),
                      advancedRuleCount: advancedLines.count,
                      skippedRuleCount: skipped)
    }

    /// Builds and saves the lookup engine for advanced rules.
    static func buildEngine(rules: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = try FilterEngine.WebExtension(containerURL: directory)
        _ = try engine.buildFilterEngine(rules: rules)
    }
}
