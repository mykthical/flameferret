// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import XCTest
@testable import Client

final class FerretStyleTests: XCTestCase {
    func testLetterheadIsTrackedUppercase() {
        let font = UIFont.systemFont(ofSize: 12)
        let text = FerretStyle.letterhead("Authorized access only", font: font, color: .black, tracking: 3)
        XCTAssertEqual(text.string, "AUTHORIZED ACCESS ONLY")
        XCTAssertEqual(text.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat, 3)
    }

    func testPaperFollowsAppearance() {
        let light = FerretStyle.paper.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = FerretStyle.paper.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertEqual(light, FerretStyle.parchment)
        XCTAssertNotEqual(light, dark)
    }

    func testSerifFontKeepsTextStyleSize() {
        let body = UIFont.preferredFont(forTextStyle: .body)
        XCTAssertEqual(FerretStyle.serifFont(.body).pointSize, body.pointSize)
    }
}
