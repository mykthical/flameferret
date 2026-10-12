// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Persists installed extensions on disk and implements `storage.local` / `storage.sync`.
@MainActor
final class WebExtensionStore {
    struct Record: Codable {
        var id: String
        var uuid: String
        var enabled: Bool
        var installedAt: Date
    }

    let rootDirectory: URL
    private let fileManager = FileManager.default
    private var storageCache: [String: [String: Any]] = [:]

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootDirectory = support.appendingPathComponent("Flameferret/Extensions", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    private var registryURL: URL { rootDirectory.appendingPathComponent("registry.json") }

    func loadRecords() -> [Record] {
        guard let data = try? Data(contentsOf: registryURL) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    func saveRecords(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: registryURL, options: .atomic)
    }

    func loadExtensions() -> [WebExtension] {
        return loadRecords().compactMap { record in
            try? WebExtension(id: record.id,
                              uuid: record.uuid,
                              rootDirectory: directory(forUUID: record.uuid),
                              isEnabled: record.enabled,
                              installedAt: record.installedAt)
        }
    }

    func directory(forUUID uuid: String) -> URL {
        return rootDirectory.appendingPathComponent(uuid, isDirectory: true)
    }

    /// Unpacks an `.xpi`, `.zip` or `.crx` and installs (or updates) it. Returns the installed extension.
    func install(packageData: Data, suggestedName: String?) throws -> WebExtension {
        let archive = try WebExtensionArchive(data: packageData)
        let staging = rootDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try archive.extract(to: staging)

        let packageRoot = try locateManifestRoot(in: staging)
        let manifest = try WebExtensionManifest.load(from: packageRoot)

        var records = loadRecords()
        let extensionID = manifest.geckoID ?? generatedID(for: manifest, suggestedName: suggestedName)
        let existingIndex = records.firstIndex { $0.id == extensionID }
        let uuid = existingIndex.map { records[$0].uuid } ?? UUID().uuidString.lowercased()

        let destinationRoot = directory(forUUID: uuid)
        let filesDirectory = destinationRoot.appendingPathComponent("files", isDirectory: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: filesDirectory.path) {
            try fileManager.removeItem(at: filesDirectory)
        }
        try fileManager.moveItem(at: packageRoot, to: filesDirectory)

        let record = Record(id: extensionID,
                            uuid: uuid,
                            enabled: existingIndex.map { records[$0].enabled } ?? true,
                            installedAt: Date())
        if let existingIndex {
            records[existingIndex] = record
        } else {
            records.append(record)
        }
        saveRecords(records)

        return try WebExtension(id: record.id,
                                uuid: record.uuid,
                                rootDirectory: destinationRoot,
                                isEnabled: record.enabled,
                                installedAt: record.installedAt)
    }

    func uninstall(uuid: String) {
        var records = loadRecords()
        records.removeAll { $0.uuid == uuid }
        saveRecords(records)
        storageCache = storageCache.filter { !$0.key.hasPrefix(uuid) }
        try? fileManager.removeItem(at: directory(forUUID: uuid))
    }

    func setEnabled(_ enabled: Bool, uuid: String) {
        var records = loadRecords()
        guard let index = records.firstIndex(where: { $0.uuid == uuid }) else { return }
        records[index].enabled = enabled
        saveRecords(records)
    }

    private func locateManifestRoot(in directory: URL) throws -> URL {
        if fileManager.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
            return directory
        }
        let children = (try? fileManager.contentsOfDirectory(at: directory,
                                                             includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let folders = children.filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__") }
        if folders.count == 1,
           fileManager.fileExists(atPath: folders[0].appendingPathComponent("manifest.json").path) {
            return folders[0]
        }
        throw WebExtensionManifestError.missingManifest
    }

    private func generatedID(for manifest: WebExtensionManifest, suggestedName: String?) -> String {
        let base = (manifest.name.contains("__MSG_") ? (suggestedName ?? "extension") : manifest.name)
        let slug = base.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        return "\(slug.isEmpty ? "extension" : slug)@flameferret.local"
    }

    // MARK: - storage.local / storage.sync

    private func storageURL(uuid: String, area: String) -> URL {
        return directory(forUUID: uuid).appendingPathComponent("storage-\(area).json")
    }

    func storage(uuid: String, area: String) -> [String: Any] {
        let key = "\(uuid)/\(area)"
        if let cached = storageCache[key] { return cached }
        let url = storageURL(uuid: uuid, area: area)
        let value = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        storageCache[key] = value
        return value
    }

    func writeStorage(_ values: [String: Any], uuid: String, area: String) {
        storageCache["\(uuid)/\(area)"] = values
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values) else { return }
        try? data.write(to: storageURL(uuid: uuid, area: area), options: .atomic)
    }

    // MARK: - declarativeNetRequest dynamic rules

    func dynamicRules(uuid: String) -> [[String: Any]] {
        let url = directory(forUUID: uuid).appendingPathComponent("dnr-dynamic.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    func writeDynamicRules(_ rules: [[String: Any]], uuid: String) {
        let url = directory(forUUID: uuid).appendingPathComponent("dnr-dynamic.json")
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func enabledRulesets(uuid: String) -> Set<String>? {
        let url = directory(forUUID: uuid).appendingPathComponent("dnr-rulesets.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return Set(list)
    }

    func writeEnabledRulesets(_ ids: Set<String>, uuid: String) {
        let url = directory(forUUID: uuid).appendingPathComponent("dnr-rulesets.json")
        guard let data = try? JSONSerialization.data(withJSONObject: Array(ids).sorted()) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
