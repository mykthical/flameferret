// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

final class AdGuardTests: XCTestCase {
    func testHostnameNormalization() {
        XCTAssertEqual(AdGuardRuleBuilder.hostname(from: "https://www.Example.com/page?x=1"), "example.com")
        XCTAssertEqual(AdGuardRuleBuilder.hostname(from: "news.example.co.uk"), "news.example.co.uk")
        XCTAssertNil(AdGuardRuleBuilder.hostname(from: "not a site"))
        XCTAssertNil(AdGuardRuleBuilder.hostname(from: "   "))
    }

    func testAllowlistMatchesSubdomains() throws {
        let hosts = ["example.com"]
        XCTAssertTrue(AdGuardRuleBuilder.isAllowlisted(try XCTUnwrap(URL(string: "https://example.com/")), hosts: hosts))
        XCTAssertTrue(AdGuardRuleBuilder.isAllowlisted(try XCTUnwrap(URL(string: "https://m.example.com/a")), hosts: hosts))
        XCTAssertFalse(AdGuardRuleBuilder.isAllowlisted(try XCTUnwrap(URL(string: "https://notexample.com/")), hosts: hosts))
    }

    func testUserRulesSkipCommentsAndBlankLines() {
        let lines = AdGuardRuleBuilder.userRuleLines("! comment\n\n||ads.test^\n  example.com##.banner  \n")
        XCTAssertEqual(lines, ["||ads.test^", "example.com##.banner"])
    }

    func testCompilerSplitsBlockingAndAdvancedRules() {
        let filter = """
        ||ads.example.com^
        example.com##.banner
        example.com#%#//scriptlet('set-constant', 'ads.enabled', 'false')
        example.com#?#div:has(> span:contains(Sponsored))
        """
        let output = AdGuardCompiler.compile(filterTexts: [(.ads, filter)],
                                             userRules: [],
                                             allowlistRules: AdGuardRuleBuilder.allowlistRules(["safe.test"]))
        XCTAssertEqual(output.groups.map { $0.id }, ["adguard-ads"])
        XCTAssertTrue(output.groups[0].json.contains("example"))
        XCTAssertTrue(output.groups[0].json.contains("ignore-previous-rules"))
        XCTAssertTrue(output.advancedRules.contains("set-constant"))
        XCTAssertTrue(output.advancedRules.contains("contains(Sponsored)"))
    }

    func testDefaultsEnableCoreLists() {
        let settings = AdGuardSettings()
        XCTAssertTrue(settings.isEnabled)
        XCTAssertTrue(settings.enabledFilters.contains { $0.id == "adguard-2" })
        XCTAssertTrue(settings.enabledFilters.allSatisfy { $0.url.host == "filters.adtidy.org" })
    }
}
