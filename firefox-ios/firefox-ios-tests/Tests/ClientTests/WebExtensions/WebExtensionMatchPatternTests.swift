// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

final class WebExtensionMatchPatternTests: XCTestCase {
    func testAllURLsMatchesWebSchemes() throws {
        let pattern = try XCTUnwrap(WebExtensionMatchPattern("<all_urls>"))
        XCTAssertTrue(pattern.matches("https://example.com/path"))
        XCTAssertTrue(pattern.matches("http://localhost:8080/"))
        XCTAssertFalse(pattern.matches("moz-extension://abc/popup.html"))
        XCTAssertTrue(pattern.matchesAllHosts)
    }

    func testWildcardSubdomain() throws {
        let pattern = try XCTUnwrap(WebExtensionMatchPattern("*://*.example.com/*"))
        XCTAssertTrue(pattern.matches("https://example.com/"))
        XCTAssertTrue(pattern.matches("https://www.example.com/a/b?c=d"))
        XCTAssertTrue(pattern.matches("http://a.b.example.com:8443/x"))
        XCTAssertFalse(pattern.matches("https://notexample.com/"))
        XCTAssertFalse(pattern.matches("https://example.com.evil.net/"))
        XCTAssertFalse(pattern.matches("ftp://example.com/"))
    }

    func testExactHostAndPath() throws {
        let pattern = try XCTUnwrap(WebExtensionMatchPattern("https://example.org/foo/*"))
        XCTAssertTrue(pattern.matches("https://example.org/foo/bar"))
        XCTAssertFalse(pattern.matches("https://example.org/bar"))
        XCTAssertFalse(pattern.matches("http://example.org/foo/bar"))
    }

    func testInvalidPatternsAreRejected() {
        XCTAssertNil(WebExtensionMatchPattern("https://exa*mple.com/*"))
        XCTAssertNil(WebExtensionMatchPattern("chrome://settings/*"))
        XCTAssertNil(WebExtensionMatchPattern("not a pattern"))
    }

    func testUserScriptGlob() {
        let regex = WebExtensionMatchPattern.userScriptGlobToRegex("https://*.example.com/a?c")
        XCTAssertNotNil("https://www.example.com/abc".range(of: regex, options: .regularExpression))
        XCTAssertNil("https://www.example.com/abcd".range(of: regex, options: .regularExpression))
    }
}
