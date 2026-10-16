// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// What the person chose in Settings, persisted between launches.
struct AdGuardSettings: Codable, Equatable, Sendable {
    var isEnabled = true
    var enabledFilterIDs: Set<String> = AdGuardFilterCatalog.defaultEnabledIDs
    var customFilters: [AdGuardFilter] = []
    var userRules = ""
    var allowlist: [String] = []
    var lastUpdated: Date?
    var lastUpdateError: String?

    var allFilters: [AdGuardFilter] { AdGuardFilterCatalog.builtIn + customFilters }
    var enabledFilters: [AdGuardFilter] { allFilters.filter { enabledFilterIDs.contains($0.id) } }
}

/// The result of the last successful compile, used to restore blocking at launch without recompiling.
struct AdGuardCompiledState: Codable, Equatable, Sendable {
    var ruleListIDs: [String]
    var safariRuleCount: Int
    var advancedRuleCount: Int
    var skippedRuleCount: Int
    var compiledAt: Date
}

/// Files under Application Support/Flameferret/AdGuard.
struct AdGuardStore: Sendable {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("Flameferret/AdGuard", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: filtersDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: ruleListsDirectory, withIntermediateDirectories: true)
    }

    var filtersDirectory: URL { root.appendingPathComponent("filters", isDirectory: true) }
    var ruleListsDirectory: URL { root.appendingPathComponent("rule-lists", isDirectory: true) }
    var engineDirectory: URL { root.appendingPathComponent("engine", isDirectory: true) }
    private var settingsURL: URL { root.appendingPathComponent("settings.json") }
    private var compiledURL: URL { root.appendingPathComponent("compiled.json") }

    func loadSettings() -> AdGuardSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AdGuardSettings.self, from: data) else {
            return AdGuardSettings()
        }
        return settings
    }

    func saveSettings(_ settings: AdGuardSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    func loadCompiledState() -> AdGuardCompiledState? {
        guard let data = try? Data(contentsOf: compiledURL) else { return nil }
        return try? JSONDecoder().decode(AdGuardCompiledState.self, from: data)
    }

    func saveCompiledState(_ state: AdGuardCompiledState?) {
        guard let state else {
            try? FileManager.default.removeItem(at: compiledURL)
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: compiledURL, options: .atomic)
    }

    func cachedFilterURL(for filter: AdGuardFilter) -> URL {
        let safeName = filter.id.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }
            .joined()
            .suffix(120)
        return filtersDirectory.appendingPathComponent(String(safeName) + ".txt")
    }

    func cachedFilterText(for filter: AdGuardFilter) -> String? {
        guard let data = try? Data(contentsOf: cachedFilterURL(for: filter)) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func saveFilterText(_ data: Data, for filter: AdGuardFilter) {
        try? data.write(to: cachedFilterURL(for: filter), options: .atomic)
    }
}
