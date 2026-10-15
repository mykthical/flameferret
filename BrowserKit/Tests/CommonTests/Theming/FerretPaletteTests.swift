// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import XCTest
@testable import Common

final class FerretPaletteTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "FerretPaletteTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        FerretThemeStore.select(.classic, defaults: defaults)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsToClassic() {
        FerretThemeStore.load(from: defaults)
        XCTAssertEqual(FerretThemeStore.theme, .classic)
    }

    func testSelectionIsRememberedAndAnnounced() {
        let announced = expectation(forNotification: FerretThemeStore.didChange, object: nil)
        FerretThemeStore.select(.sunflower, defaults: defaults)
        wait(for: [announced], timeout: 1)
        FerretThemeStore.select(.classic, defaults: UserDefaults(suiteName: "scratch-\(UUID().uuidString)")!)
        FerretThemeStore.load(from: defaults)
        XCTAssertEqual(FerretThemeStore.theme, .sunflower)
    }

    func testNovaColorsFollowTheSelectedTheme() {
        FerretThemeStore.select(.classic, defaults: defaults)
        XCTAssertEqual(NovaColors.Navy50, UIColor(rgb: 0x23436f))
        FerretThemeStore.select(.sunflower, defaults: defaults)
        XCTAssertEqual(NovaColors.Navy50, UIColor(rgb: 0x0057b7))
        XCTAssertEqual(NovaLightTheme().colors.actionPrimary, UIColor(rgb: 0x0057b7))
    }

    func testEveryThemeHasCompleteScales() {
        for theme in FerretTheme.allCases {
            let palette = theme.palette
            XCTAssertEqual(palette.accent.count, 10, theme.rawValue)
            XCTAssertEqual(palette.neutral.count, 19, theme.rawValue)
            XCTAssertFalse(theme.displayName.isEmpty)
        }
    }
}
