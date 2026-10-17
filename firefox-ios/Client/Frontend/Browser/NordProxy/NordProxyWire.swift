// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Why a tunnel through NordVPN couldn't be opened, in words the Check Connection alert can show.
enum NordProxyTunnelError: Error, Equatable {
    /// No TLS connection to the NordVPN server (unreachable, blocked network, bad certificate).
    case cannotReachServer(String)
    /// The server answered the CONNECT request with this HTTP status.
    case rejected(status: Int)
    /// The server's reply wasn't HTTP.
    case badResponse
    case timedOut

    var explanation: String {
        switch self {
        case .cannotReachServer(let detail):
            return "Couldn't make a secure connection to the NordVPN server (\(detail)). Try Find Another Server."
        case .rejected(status: 407):
            return "NordVPN rejected the service credentials. Copy the service username and password again from "
                + "my.nordaccount.com → NordVPN → Set up NordVPN manually. They aren't your login email and password."
        case .rejected(status: 403):
            return "NordVPN refused the connection (403). Your subscription may have expired, or this server doesn't "
                + "allow proxy connections. Try Find Another Server."
        case .rejected(let status):
            return "The NordVPN server answered with an error (\(status)). Try Find Another Server."
        case .badResponse:
            return "The NordVPN server sent an unexpected reply. Try Find Another Server."
        case .timedOut:
            return "The NordVPN server didn't answer in time. Try Find Another Server."
        }
    }
}

/// The HTTP CONNECT handshake spoken between WebKit, Culpeo's relay and NordVPN's HTTPS proxy.
enum NordProxyWire {
    static let headerTerminator = Data("\r\n\r\n".utf8)
    static let maxHeaderLength = 32 * 1024

    static func basicAuthorization(username: String, password: String) -> String {
        return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// The request Culpeo sends to NordVPN to open a tunnel to `target` ("host:port").
    static func connectRequest(target: String, authorization: String) -> Data {
        return Data(("CONNECT \(target) HTTP/1.1\r\n"
            + "Host: \(target)\r\n"
            + "Proxy-Authorization: \(authorization)\r\n"
            + "Proxy-Connection: Keep-Alive\r\n\r\n").utf8)
    }

    /// The "host:port" a client asked to CONNECT to, or nil for anything else.
    static func connectTarget(fromHeader header: Data) -> String? {
        guard let text = String(data: header, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0].uppercased() == "CONNECT", parts[2].hasPrefix("HTTP/1.") else { return nil }
        let target = String(parts[1])
        guard let colon = target.lastIndex(of: ":"),
              let port = Int(target[target.index(after: colon)...]), (1...65535).contains(port),
              colon > target.startIndex else { return nil }
        return target
    }

    /// The status code on the first line of an HTTP response header.
    static func statusCode(fromHeader header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let code = Int(parts[1]) else { return nil }
        return code
    }

    /// Splits accumulated bytes into a complete header (including the blank line) and whatever followed it.
    static func splitHeader(_ buffer: Data) -> (header: Data, rest: Data)? {
        guard let range = buffer.range(of: headerTerminator) else { return nil }
        return (buffer.subdata(in: buffer.startIndex..<range.upperBound),
                buffer.subdata(in: range.upperBound..<buffer.endIndex))
    }

    static let established = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

    static func failureResponse(status: Int, reason: String) -> Data {
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
}
