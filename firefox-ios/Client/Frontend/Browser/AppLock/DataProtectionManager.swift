// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Shared
import UIKit

/// Sets iOS Data Protection on what the browser stores.
///
/// Website data, cookies, caches, downloads, extensions and ad-blocking data get the "complete unless open"
/// class: their key is discarded shortly after the iPhone locks. Settings, the browser profile (history,
/// bookmarks, tabs, the saved-passwords database) and everything else keep iOS's standard class, readable
/// after the first unlock since restart: iOS starts browsers in the background while locked (sync,
/// notifications, background refresh), and settings that can't be read then look empty and get
/// overwritten with defaults. Saved passwords are also encrypted with their own key in the Keychain.
enum DataProtectionManager {
    static let enabledKey = "FlameferretStrongDataProtection"
    private static let appliedKey = "FlameferretStrongDataProtectionApplied"
    /// Bump when the folder plan changes, so existing installs get a full re-protection pass.
    private static let planVersion = "2"

    struct Plan: Equatable {
        /// Folders (with everything inside) that keep the standard class.
        let standard: [URL]
        /// Folders (with everything inside) that get the strong class, applied after `standard`.
        let strong: [URL]
    }

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: enabledKey) == nil { return true }
        return defaults.bool(forKey: enabledKey)
    }

    static var strongClass: FileProtectionType {
        return isEnabled ? .completeUnlessOpen : .completeUntilFirstUserAuthentication
    }

    @MainActor
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        apply()
    }

    static func plan(home: URL, group: URL?) -> Plan {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let standard = [home.appendingPathComponent("Documents", isDirectory: true),
                        library,
                        home.appendingPathComponent("tmp", isDirectory: true)] + (group.map { [$0] } ?? [])
        let strong = [
            library.appendingPathComponent("WebKit", isDirectory: true),
            library.appendingPathComponent("Cookies", isDirectory: true),
            library.appendingPathComponent("Caches", isDirectory: true),
            support.appendingPathComponent("Flameferret", isDirectory: true),
            home.appendingPathComponent("Documents/Downloads", isDirectory: true),
            home.appendingPathComponent("tmp", isDirectory: true)
        ]
        return Plan(standard: standard, strong: strong)
    }

    /// Protects the folders on every launch so new files inherit the right class, and re-protects every
    /// existing file when the setting or the plan changes. Skipped while the iPhone is locked, when
    /// protected files can't be changed.
    @MainActor
    static func apply() {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        let plan = plan(home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                        group: FileManager.default.containerURL(
                            forSecurityApplicationGroupIdentifier: AppInfo.sharedContainerIdentifier))
        let strong = strongClass
        let marker = "\(planVersion):\(strong.rawValue)"
        let needsFullPass = UserDefaults.standard.string(forKey: appliedKey) != marker

        DispatchQueue.global(qos: .utility).async {
            let fileManager = FileManager.default
            for root in plan.standard {
                setProtection(.completeUntilFirstUserAuthentication, on: root, fileManager: fileManager)
                if needsFullPass {
                    protectContents(of: root, as: .completeUntilFirstUserAuthentication, fileManager: fileManager)
                }
            }
            for root in plan.strong {
                try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                setProtection(strong, on: root, fileManager: fileManager)
                if needsFullPass {
                    protectContents(of: root, as: strong, fileManager: fileManager)
                }
            }
            if needsFullPass {
                UserDefaults.standard.set(marker, forKey: appliedKey)
            }
        }
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
