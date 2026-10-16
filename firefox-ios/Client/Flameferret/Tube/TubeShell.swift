// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import AVFoundation
import Common
import CryptoKit
import Foundation
import Shared
import SwiftUI
import UIKit

/// The extensions that ship inside the app.
@MainActor
enum TubeBundledExtensions {
    enum Package: String, CaseIterable {
        case sponsorBlock = "sponsorblock"

        var extensionID: String {
            switch self {
            case .sponsorBlock: return "sponsorBlocker@ajay.app"
            }
        }

        var displayName: String {
            switch self {
            case .sponsorBlock: return "SponsorBlock"
            }
        }
    }

    /// uBlock Origin Lite shipped in earlier builds; AdGuard is now built in, so the bundled copy is
    /// removed once to avoid two blockers fighting over the same page.
    private static let retiredBundledIDs = ["uBOLiteRedux@raymondhill.net": "tube.bundledExtension.ublock-origin-lite"]

    /// Installs or updates each bundled package when the copy in the app differs from the last one
    /// installed. Removing a bundled extension sticks until the app ships a new version of it.
    static func installIfNeeded(defaults: UserDefaults = .standard) {
        let manager = WebExtensionManager.shared
        manager.startIfNeeded()
        for (extensionID, key) in retiredBundledIDs where defaults.string(forKey: key) != nil {
            if let installed = manager.extensions.first(where: { $0.id == extensionID }) {
                manager.uninstall(installed)
            }
            defaults.removeObject(forKey: key)
        }
        for package in Package.allCases {
            guard let url = Bundle.main.url(forResource: package.rawValue, withExtension: "xpi"),
                  let data = try? Data(contentsOf: url) else {
                DefaultLogger.shared.log("Bundled extension \(package.rawValue) is missing",
                                         level: .warning, category: .lifecycle)
                continue
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let key = "tube.bundledExtension.\(package.rawValue)"
            guard defaults.string(forKey: key) != digest else { continue }
            do {
                _ = try manager.install(packageData: data, suggestedName: package.displayName)
                defaults.set(digest, forKey: key)
            } catch {
                DefaultLogger.shared.log("Could not install \(package.rawValue): \(error.localizedDescription)",
                                         level: .warning, category: .lifecycle)
            }
        }
    }

    static func installed(_ package: Package) -> WebExtension? {
        return WebExtensionManager.shared.extensions.first { $0.id == package.extensionID && $0.isEnabled }
    }
}

/// Starts the YouTube shell: bundled extensions, background audio, the hidden YouTube session.
@MainActor
enum TubeShell {
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true

        let profile: Profile = AppContainer.shared.resolve()
        if profile.prefs.boolForKey(PrefsKeys.BackgroundAudio) == nil {
            profile.prefs.setBool(true, forKey: PrefsKeys.BackgroundAudio)
        }
        if profile.prefs.boolForKey(PrefsKeys.BackgroundAudio) ?? true {
            BackgroundAudioHelper.shared.startObserving()
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)

        TubeBundledExtensions.installIfNeeded()
        AdGuardManager.shared.startIfNeeded()
        TubeEngine.shared.start()

        if #available(iOS 18.0, *) {
            ShellTabRegistry.shared.openHandler = { url in
                TubeRouter.shared.open(url)
                return nil
            }
            ShellTabRegistry.shared.closeHandler = { _ in
                TubeRouter.shared.pageSheet = nil
            }
        }
    }

    static func makeRootViewController() -> UIViewController {
        start()
        if #available(iOS 18.0, *) {
            return UIHostingController(rootView: TubeRootView())
        }
        return TubeUnsupportedViewController()
    }

    /// Handles a link opened from another app (youtube.com, youtu.be, youtubex://open-url?url=...).
    static func handleIncoming(_ url: URL) {
        var target = url
        if url.scheme?.lowercased().hasPrefix("youtubex") == true,
           let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value,
           let innerURL = URL(string: inner) {
            target = innerURL
        }
        if #available(iOS 18.0, *) {
            TubeRouter.shared.open(target)
        }
    }
}
