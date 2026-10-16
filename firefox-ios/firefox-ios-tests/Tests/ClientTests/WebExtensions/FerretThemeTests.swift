// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import XCTest
@testable import Client

final class FerretThemeTests: XCTestCase {
    func testEveryThemeHasAMatchingIcon() {
        for theme in FerretTheme.allCases {
            XCTAssertEqual(AppIcon(theme: theme).theme, theme)
        }
        XCTAssertEqual(AppIcon.allCases.count, FerretTheme.allCases.count)
        XCTAssertNil(AppIcon(theme: .classic).appIconAssetName)
        XCTAssertEqual(AppIcon(theme: .sunflower).appIconAssetName, "AppIcon_Alt_Ferret_Sunflower")
    }

    @MainActor
    func testMatchingTheIconIsOnUnlessTurnedOff() {
        let defaults = UserDefaults(suiteName: "FerretThemeTests-\(UUID().uuidString)")!
        XCTAssertTrue(FerretThemeSettingsViewController.matchesIcon(defaults))
        defaults.set(false, forKey: FerretThemeSettingsViewController.matchIconKey)
        XCTAssertFalse(FerretThemeSettingsViewController.matchesIcon(defaults))
    }
}
