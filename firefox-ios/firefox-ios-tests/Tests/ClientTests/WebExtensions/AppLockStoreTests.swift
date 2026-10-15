// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

final class AppLockStoreTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000_000)
    }

    private func makeStore() -> (AppLockStore, Clock) {
        let clock = Clock()
        return (AppLockStore(secrets: InMemoryAppLockSecretStore(), now: { clock.date }), clock)
    }

    func testOnlySixDigitPINsAreAccepted() {
        XCTAssertTrue(AppLockStore.isValidPIN("123456"))
        XCTAssertFalse(AppLockStore.isValidPIN("12345"))
        XCTAssertFalse(AppLockStore.isValidPIN("12345a"))
        XCTAssertFalse(AppLockStore.isValidPIN("１２３４５６"))
        let (store, _) = makeStore()
        store.setPIN("1234")
        XCTAssertFalse(store.hasPIN)
    }

    func testCorrectAndWrongPIN() {
        let (store, _) = makeStore()
        store.setPIN("482915")
        XCTAssertTrue(store.hasPIN)
        XCTAssertEqual(store.verify("482915"), .success)
        XCTAssertEqual(store.verify("000000"), .wrong(remainingBeforeLockout: 4))
        XCTAssertEqual(store.failureCount, 1)
        XCTAssertEqual(store.verify("482915"), .success)
        XCTAssertEqual(store.failureCount, 0)
    }

    func testLockoutAfterFiveWrongPINsBlocksEvenTheRightOne() {
        let (store, clock) = makeStore()
        store.setPIN("482915")
        for _ in 0..<4 { _ = store.verify("111111") }
        guard case .lockedOut(let until) = store.verify("111111") else {
            return XCTFail("Expected a lockout on the 5th wrong PIN")
        }
        XCTAssertEqual(until.timeIntervalSince(clock.date), 30, accuracy: 0.5)
        guard case .lockedOut = store.verify("482915") else {
            return XCTFail("The correct PIN must not work during a lockout")
        }
        clock.date = until.addingTimeInterval(1)
        XCTAssertNil(store.lockedOutUntil)
        guard case .lockedOut(let next) = store.verify("111111") else {
            return XCTFail("Expected a longer lockout on the 6th wrong PIN")
        }
        XCTAssertEqual(next.timeIntervalSince(clock.date), 60, accuracy: 0.5)
        clock.date = next.addingTimeInterval(1)
        XCTAssertEqual(store.verify("482915"), .success)
        XCTAssertEqual(store.failureCount, 0)
    }

    func testLockoutSchedule() {
        XCTAssertNil(AppLockStore.lockoutDelay(afterFailures: 4))
        XCTAssertEqual(AppLockStore.lockoutDelay(afterFailures: 5), 30)
        XCTAssertEqual(AppLockStore.lockoutDelay(afterFailures: 7), 300)
        XCTAssertEqual(AppLockStore.lockoutDelay(afterFailures: 8), 900)
        XCTAssertEqual(AppLockStore.lockoutDelay(afterFailures: 20), 3600)
    }

    func testRemovingPINClearsEverything() {
        let (store, _) = makeStore()
        store.setPIN("482915")
        _ = store.verify("111111")
        store.removePIN()
        XCTAssertFalse(store.hasPIN)
        XCTAssertEqual(store.failureCount, 0)
    }

    func testHashIsSaltedAndNotThePIN() {
        let saltA = AppLockStore.randomBytes(16)
        let saltB = AppLockStore.randomBytes(16)
        XCTAssertNotEqual(saltA, saltB)
        let hashA = AppLockStore.derive("482915", salt: saltA, iterations: 1000)
        XCTAssertEqual(hashA.count, 32)
        XCTAssertNotEqual(hashA, AppLockStore.derive("482915", salt: saltB, iterations: 1000))
        XCTAssertEqual(hashA, AppLockStore.derive("482915", salt: saltA, iterations: 1000))
        XCTAssertFalse(AppLockStore.constantTimeEqual(hashA, Data()))
    }
}
