// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared

/// Raises iOS Data Protection on everything Flameferret stores — history, tabs, cookies, website data,
/// the passwords database, extensions and AdGuard data — so it's encrypted with a key that only exists
/// while the iPhone is unlocked.
///
/// iOS's default class keeps files readable from the first unlock until the phone restarts. The
/// "complete unless open" class used here makes closed files unreadable shortly after the phone
/// locks, while files that are already open (databases, downloads) keep working in the background.
enum DataProtectionManager {
    static let enabledKey = "FlameferretStrongDataProtection"
    private static let appliedKey = "FlameferretStrongDataProtectionApplied"

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: enabledKey) == nil { return true }
        return defaults.bool(forKey: enabledKey)
    }

    static var protectionClass: FileProtectionType {
        return isEnabled ? .completeUnlessOpen : .completeUntilFirstUserAuthentication
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        apply()
    }

    /// Protects the top-level folders on every launch, so new files inherit the class, and re-protects
    /// every existing file whenever the setting changes.
    static func apply() {
        let roots = containerRoots()
        let protection = protectionClass
        let marker = protection.rawValue
        let needsFullPass = UserDefaults.standard.string(forKey: appliedKey) != marker

        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            for root in roots {
                setProtection(protection, on: root, fileManager: fileManager)
                if needsFullPass {
                    protectContents(of: root, as: protection, fileManager: fileManager)
                }
            }
            if needsFullPass {
                UserDefaults.standard.set(marker, forKey: appliedKey)
            }
        }
    }

    static func containerRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var roots = ["Documents", "Library", "tmp"].map { home.appendingPathComponent($0, isDirectory: true) }
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppInfo.sharedContainerIdentifier
        ) {
            roots.append(group)
        }
        return roots
    }

    static func protectContents(of root: URL, as protection: FileProtectionType, fileManager: FileManager) {
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: nil,
                                                      options: [],
                                                      errorHandler: { _, _ in true }) else { return }
        for case let url as URL in enumerator {
            setProtection(protection, on: url, fileManager: fileManager)
        }
    }

    private static func setProtection(_ protection: FileProtectionType, on url: URL, fileManager: FileManager) {
        try? fileManager.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
    }
}
