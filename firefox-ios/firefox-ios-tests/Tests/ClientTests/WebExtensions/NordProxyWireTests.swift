// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import XCTest
@testable import Client

final class NordProxyWireTests: XCTestCase {
    func testBasicAuthorization() {
        XCTAssertEqual(NordProxyWire.basicAuthorization(username: "user", password: "p:ss"), "Basic dXNlcjpwOnNz")
    }

    func testConnectRequestCarriesTargetAndCredentials() {
        let request = String(data: NordProxyWire.connectRequest(target: "example.com:443", authorization: "Basic abc"),
                             encoding: .utf8)
        XCTAssertEqual(request, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n"
                       + "Proxy-Authorization: Basic abc\r\nProxy-Connection: Keep-Alive\r\n\r\n")
    }

    func testReadsTheTargetOfAConnectRequestOnly() {
        let connect = Data("CONNECT www.example.com:443 HTTP/1.1\r\nHost: www.example.com:443\r\n\r\n".utf8)
        XCTAssertEqual(NordProxyWire.connectTarget(fromHeader: connect), "www.example.com:443")
        XCTAssertEqual(NordProxyWire.connectTarget(fromHeader: Data("CONNECT [::1]:8443 HTTP/1.1\r\n\r\n".utf8)),
                       "[::1]:8443")
        XCTAssertNil(NordProxyWire.connectTarget(fromHeader: Data("GET http://example.com/ HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(NordProxyWire.connectTarget(fromHeader: Data("CONNECT example.com HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(NordProxyWire.connectTarget(fromHeader: Data("CONNECT example.com:0 HTTP/1.1\r\n\r\n".utf8)))
    }

    func testStatusCodes() {
        XCTAssertEqual(NordProxyWire.statusCode(fromHeader: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8)), 200)
        XCTAssertEqual(NordProxyWire.statusCode(fromHeader: Data("HTTP/1.0 407 Proxy Auth Required\r\n\r\n".utf8)), 407)
        XCTAssertNil(NordProxyWire.statusCode(fromHeader: Data("SSH-2.0-OpenSSH\r\n\r\n".utf8)))
    }

    func testSplitsTheHeaderFromTheBytesAfterIt() {
        let buffer = Data("HTTP/1.1 200 OK\r\n\r\n".utf8) + Data([0x16, 0x03, 0x01])
        let split = NordProxyWire.splitHeader(buffer)
        XCTAssertEqual(split?.header, Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
        XCTAssertEqual(split?.rest, Data([0x16, 0x03, 0x01]))
        XCTAssertNil(NordProxyWire.splitHeader(Data("HTTP/1.1 200 OK\r\n".utf8)))
    }

    func testRejectedCredentialsGetAClearExplanation() {
        XCTAssertTrue(NordProxyTunnelError.rejected(status: 407).explanation.contains("service credentials"))
    }
}
