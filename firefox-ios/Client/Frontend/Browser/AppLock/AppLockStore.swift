// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CommonCrypto
import Foundation
import Security

/// Where lock secrets live. The real one is the Keychain; tests use an in-memory store.
protocol AppLockSecretStore: AnyObject {
    func data(for key: String) -> Data?
    func set(_ data: Data?, for key: String)
}

/// Keychain items that never leave this device and are readable only while it's unlocked.
final class KeychainAppLockSecretStore: AppLockSecretStore {
    private let service: String

    init(service: String = "com.mykthical.flameferret.applock") {
        self.service = service
    }

    func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func set(_ data: Data?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        guard let data else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

final class InMemoryAppLockSecretStore: AppLockSecretStore {
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { values[key] }

    func set(_ data: Data?, for key: String) { values[key] = data }
}

/// Stores the PIN as a salted PBKDF2-SHA256 hash and tracks failed attempts.
final class AppLockStore {
    static let pinLength = 6
    static let iterations: UInt32 = 200_000

    private enum Key {
        static let record = "pin"
        static let failures = "failures"
        static let lockedUntil = "lockedUntil"
    }

    private struct PINRecord: Codable {
        let salt: Data
        let hash: Data
        let iterations: UInt32
    }

    private let secrets: AppLockSecretStore
    private let now: () -> Date

    init(secrets: AppLockSecretStore = KeychainAppLockSecretStore(), now: @escaping () -> Date = Date.init) {
        self.secrets = secrets
        self.now = now
    }

    var hasPIN: Bool { secrets.data(for: Key.record) != nil }

    static func isValidPIN(_ pin: String) -> Bool {
        return pin.count == pinLength && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    func setPIN(_ pin: String) {
        guard AppLockStore.isValidPIN(pin) else { return }
        let salt = AppLockStore.randomBytes(16)
        let record = PINRecord(salt: salt,
                               hash: AppLockStore.derive(pin, salt: salt, iterations: AppLockStore.iterations),
                               iterations: AppLockStore.iterations)
        secrets.set(try? JSONEncoder().encode(record), for: Key.record)
        resetFailures()
    }

    func removePIN() {
        secrets.set(nil, for: Key.record)
        resetFailures()
    }

    enum VerifyResult: Equatable {
        case success
        case wrong(remainingBeforeLockout: Int?)
        case lockedOut(until: Date)
    }

    /// Checks a PIN, recording a failure if it's wrong. Refuses to check at all while locked out.
    func verify(_ pin: String) -> VerifyResult {
        if let until = lockedOutUntil { return .lockedOut(until: until) }
        guard let data = secrets.data(for: Key.record),
              let record = try? JSONDecoder().decode(PINRecord.self, from: data) else {
            return .wrong(remainingBeforeLockout: nil)
        }
        let candidate = AppLockStore.derive(pin, salt: record.salt, iterations: record.iterations)
        if AppLockStore.constantTimeEqual(candidate, record.hash) {
            resetFailures()
            return .success
        }
        let failures = failureCount + 1
        secrets.set(Data(String(failures).utf8), for: Key.failures)
        if let delay = AppLockStore.lockoutDelay(afterFailures: failures) {
            let until = now().addingTimeInterval(delay)
            secrets.set(Data(String(until.timeIntervalSince1970).utf8), for: Key.lockedUntil)
            return .lockedOut(until: until)
        }
        return .wrong(remainingBeforeLockout: AppLockStore.freeAttempts - failures)
    }

    var failureCount: Int {
        return secrets.data(for: Key.failures).flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    }

    var lockedOutUntil: Date? {
        guard let data = secrets.data(for: Key.lockedUntil),
              let seconds = Double(String(decoding: data, as: UTF8.self)) else { return nil }
        let until = Date(timeIntervalSince1970: seconds)
        return until > now() ? until : nil
    }

    func resetFailures() {
        secrets.set(nil, for: Key.failures)
        secrets.set(nil, for: Key.lockedUntil)
    }

    static let freeAttempts = 5

    /// Waits after the 5th, 6th, 7th, 8th and later wrong PINs. Data is never erased.
    static func lockoutDelay(afterFailures failures: Int) -> TimeInterval? {
        switch failures {
        case ..<freeAttempts: return nil
        case freeAttempts: return 30
        case freeAttempts + 1: return 60
        case freeAttempts + 2: return 5 * 60
        case freeAttempts + 3: return 15 * 60
        default: return 60 * 60
        }
    }

    static func derive(_ pin: String, salt: Data, iterations: UInt32) -> Data {
        var derived = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let saltBytes = [UInt8](salt)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                          pin,
                                          pin.utf8.count,
                                          saltBytes,
                                          saltBytes.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                          iterations,
                                          &derived,
                                          derived.count)
        return status == Int32(kCCSuccess) ? Data(derived) : Data()
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
