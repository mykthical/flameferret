// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Shared
import XCTest

final class FlameferretBrandingTests: XCTestCase {
    func testReplacesProductName() {
        XCTAssertEqual(flameferretBranded("Make Firefox your default browser"),
                       "Make Culpeo your default browser")
        XCTAssertEqual(flameferretBranded("Firefox can use your camera"), "Culpeo can use your camera")
    }

    func testKeepsOtherMozillaProducts() {
        XCTAssertEqual(flameferretBranded("Mask your email with Firefox Relay"), "Mask your email with Firefox Relay")
        XCTAssertEqual(flameferretBranded("Sign in to your Firefox account"), "Sign in to your Firefox account")
    }

    func testLeavesOtherTextAlone() {
        XCTAssertEqual(flameferretBranded("Bookmarks"), "Bookmarks")
    }
}
