// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

final class WebExtensionDNRConverterTests: XCTestCase {
    func testDomainAnchorFilter() throws {
        let regex = try XCTUnwrap(WebExtensionDNRConverter.urlFilterToRegex("||ads.example.com^"))
        XCTAssertNotNil("https://ads.example.com/banner.js".range(of: regex, options: .regularExpression))
        XCTAssertNotNil("https://cdn.ads.example.com/x".range(of: regex, options: .regularExpression))
        XCTAssertNotNil("https://ads.example.com".range(of: regex, options: .regularExpression))
        XCTAssertNil("https://ads.example.company/x".range(of: regex, options: .regularExpression))
        XCTAssertNil("https://badads.example.com.evil/x".range(of: regex, options: .regularExpression))
    }

    func testBlockRuleConversion() throws {
        let rule: [String: Any] = [
            "id": 1,
            "action": ["type": "block"],
            "condition": ["urlFilter": "||tracker.test^",
                          "resourceTypes": ["script", "image"],
                          "initiatorDomains": ["news.test"]]
        ]
        let converted = WebExtensionDNRConverter.convertRule(rule)
        XCTAssertEqual(converted.count, 1)
        let trigger = try XCTUnwrap(converted.first?["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["resource-type"] as? [String], ["image", "script"])
        XCTAssertEqual(trigger["if-domain"] as? [String], ["*news.test"])
        XCTAssertEqual((converted.first?["action"] as? [String: Any])?["type"] as? String, "block")
    }

    func testAllowRulesComeAfterBlockRules() {
        let rules: [[String: Any]] = [
            ["id": 2, "action": ["type": "allow"], "condition": ["urlFilter": "||good.test^"]],
            ["id": 1, "action": ["type": "block"], "condition": ["urlFilter": "||good.test^"]]
        ]
        let output = WebExtensionDNRConverter.convert(rules)
        let types = output.rules.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
        XCTAssertEqual(types, ["block", "ignore-previous-rules"])
    }

    func testUnsupportedActionsAndRegexesAreSkipped() {
        let rules: [[String: Any]] = [
            ["id": 1, "action": ["type": "redirect", "redirect": ["url": "https://x.test"]], "condition": [:]],
            ["id": 2, "action": ["type": "block"], "condition": ["regexFilter": "^https://(a|b)\\.test/"]],
            ["id": 3, "action": ["type": "block"], "condition": ["regexFilter": "^https://a\\.test/\\d+"]]
        ]
        let output = WebExtensionDNRConverter.convert(rules)
        XCTAssertEqual(output.skipped, 2)
        XCTAssertEqual(output.rules.count, 1)
    }

    func testRequestDomainsBecomeHostFilters() {
        let rule: [String: Any] = ["id": 1, "action": ["type": "block"],
                                   "condition": ["requestDomains": ["a.test", "b.test"]]]
        XCTAssertEqual(WebExtensionDNRConverter.convertRule(rule).count, 2)
    }
}
