// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import LocalAuthentication
import UIKit

/// Locks Flameferret behind a PIN (and optionally Face ID or Touch ID).
///
/// Every window gets a lock screen that sits above all other content. It also goes up when the app
/// moves to the background, so the app-switcher snapshot never shows a page.
@MainActor
final class AppLockManager {
    static let shared = AppLockManager()

    enum AutoLock: Int, CaseIterable {
        case immediately = 0
        case oneMinute = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case oneHour = 3600

        var title: String {
            switch self {
            case .immediately: return "Immediately"
            case .oneMinute: return "After 1 minute"
            case .fiveMinutes: return "After 5 minutes"
            case .fifteenMinutes: return "After 15 minutes"
            case .oneHour: return "After 1 hour"
            }
        }
    }

    private enum DefaultsKey {
        static let biometrics = "FlameferretAppLockBiometrics"
        static let autoLock = "FlameferretAppLockAutoLock"
        static let installMarker = "FlameferretAppLockInstalled"
    }

    let store: AppLockStore
    private let defaults: UserDefaults
    private var lockWindows: [ObjectIdentifier: UIWindow] = [:]
    private(set) var isLocked = false
    private var backgroundedAt: Date?
    /// Set once biometrics has been offered for the current lock, so dismissing the Face ID sheet
    /// (which makes the app inactive and active again) doesn't offer it in a loop.
    private var hasOfferedBiometrics = false
    private var isAuthenticatingWithBiometrics = false

    init(store: AppLockStore = AppLockStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        // Keychain items survive deleting the app; a fresh install must not inherit an old PIN.
        if !defaults.bool(forKey: DefaultsKey.installMarker) {
            store.removePIN()
            defaults.set(true, forKey: DefaultsKey.installMarker)
        }
        isLocked = store.hasPIN
    }

    var isEnabled: Bool { store.hasPIN }

    var usesBiometrics: Bool {
        get { defaults.object(forKey: DefaultsKey.biometrics) as? Bool ?? true }
        set { defaults.set(newValue, forKey: DefaultsKey.biometrics) }
    }

    var autoLock: AutoLock {
        get { AutoLock(rawValue: defaults.integer(forKey: DefaultsKey.autoLock)) ?? .immediately }
        set { defaults.set(newValue.rawValue, forKey: DefaultsKey.autoLock) }
    }

    var biometryName: String? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Optic ID"
        }
    }

    // MARK: - Scene lifecycle

    func sceneDidConnect(_ scene: UIScene) {
        guard isEnabled, let windowScene = scene as? UIWindowScene else { return }
        isLocked = true
        showLockScreen(in: windowScene, promptBiometrics: true)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        lockWindows[ObjectIdentifier(scene)] = nil
    }

    func sceneWillResignActive(_ scene: UIScene) {
        guard isEnabled, let windowScene = scene as? UIWindowScene else { return }
        showLockScreen(in: windowScene, promptBiometrics: false)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        guard isEnabled else { return }
        guard !isAuthenticatingWithBiometrics else { return }
        if !isLocked { backgroundedAt = Date() }
        if autoLock == .immediately { isLocked = true }
        hasOfferedBiometrics = false
        if let windowScene = scene as? UIWindowScene {
            showLockScreen(in: windowScene, promptBiometrics: false)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard isEnabled, let windowScene = scene as? UIWindowScene else {
            hideAllLockScreens()
            return
        }
        if !isLocked, let backgroundedAt, Date().timeIntervalSince(backgroundedAt) >= Double(autoLock.rawValue) {
            isLocked = true
            hasOfferedBiometrics = false
        }
        backgroundedAt = nil
        if isLocked {
            showLockScreen(in: windowScene, promptBiometrics: true)
        } else {
            hideAllLockScreens()
        }
    }

    // MARK: - Locking

    func lockNow() {
        guard isEnabled else { return }
        isLocked = true
        hasOfferedBiometrics = false
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            showLockScreen(in: scene, promptBiometrics: false)
        }
    }

    func didUnlock() {
        isLocked = false
        backgroundedAt = nil
        hideAllLockScreens()
    }

    private func showLockScreen(in scene: UIWindowScene, promptBiometrics: Bool) {
        let key = ObjectIdentifier(scene)
        let window: UIWindow
        if let existing = lockWindows[key] {
            window = existing
        } else {
            window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 100
            window.rootViewController = AppLockViewController(mode: .unlock, manager: self)
            lockWindows[key] = window
        }
        let controller = window.rootViewController as? AppLockViewController
        controller?.showsKeypad = isLocked
        window.isHidden = false
        window.makeKeyAndVisible()
        if promptBiometrics && isLocked && !hasOfferedBiometrics && !isAuthenticatingWithBiometrics
            && UIApplication.shared.applicationState == .active {
            hasOfferedBiometrics = true
            controller?.requestBiometricsIfAvailable()
        }
    }

    private func hideAllLockScreens() {
        for window in lockWindows.values {
            window.isHidden = true
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            scene.windows.first { !$0.isHidden && $0.windowLevel == .normal }?.makeKey()
        }
    }

    // MARK: - Biometrics

    func authenticateWithBiometrics(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard usesBiometrics, store.lockedOutUntil == nil else {
            completion(false)
            return
        }
        let context = LAContext()
        context.localizedFallbackTitle = "Enter PIN"
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            completion(false)
            return
        }
        isAuthenticatingWithBiometrics = true
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                               localizedReason: "Unlock Ferret") { success, _ in
            Task { @MainActor in
                self.isAuthenticatingWithBiometrics = false
                completion(success)
            }
        }
    }

    // MARK: - Settings changes

    func enable(pin: String) {
        store.setPIN(pin)
        isLocked = false
    }

    func disable() {
        store.removePIN()
        isLocked = false
        hideAllLockScreens()
        lockWindows.removeAll()
    }
}
