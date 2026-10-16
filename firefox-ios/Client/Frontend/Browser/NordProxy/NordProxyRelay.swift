// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Network

/// The NordVPN server and service credentials the relay forwards to.
struct NordProxyUpstream: Equatable, Sendable {
    let host: String
    let port: UInt16
    let authorization: String
}

/// A small HTTP CONNECT proxy on 127.0.0.1 inside Ferret. WebKit connects to it without TLS or credentials;
/// for each tunnel it opens a TLS connection to the NordVPN server, authenticates with the service
/// credentials, and then passes bytes both ways. This avoids relying on WebKit's own support for
/// authenticated HTTPS proxies. All state is confined to `queue`.
final class NordProxyRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ferret.nordproxy.relay")
    private var listener: NWListener?
    private var listenerPort: UInt16?
    private var upstream: NordProxyUpstream?
    private var readyHandlers: [@Sendable (UInt16?) -> Void] = []
    private let upstreamParameters: @Sendable () -> NWParameters
    static let timeout: TimeInterval = 20

    /// `upstreamParameters` is TLS to the NordVPN server; tests pass plain TCP to talk to a local fake.
    init(upstreamParameters: @escaping @Sendable () -> NWParameters = { NWParameters(tls: NWProtocolTLS.Options()) }) {
        self.upstreamParameters = upstreamParameters
    }

    /// Starts listening (if needed) and reports the local port, or nil if the listener couldn't start.
    func start(upstream: NordProxyUpstream, ready: @escaping @Sendable (UInt16?) -> Void) {
        queue.async {
            self.upstream = upstream
            if let port = self.listenerPort {
                ready(port)
                return
            }
            self.readyHandlers.append(ready)
            if self.listener == nil { self.startListener() }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.listenerPort = nil
            self.upstream = nil
            self.finishReady(nil)
        }
    }

    private func startListener() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            finishReady(nil)
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.listenerPort = listener?.port?.rawValue
                self.finishReady(self.listenerPort)
            case .failed, .cancelled:
                if self.listener === listener {
                    self.listener = nil
                    self.listenerPort = nil
                }
                self.finishReady(nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func finishReady(_ port: UInt16?) {
        let handlers = readyHandlers
        readyHandlers = []
        handlers.forEach { $0(port) }
    }

    // MARK: - Tunnels

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        Self.readHeader(from: client, buffer: Data()) { [weak self] header, rest in
            guard let self, let header, let target = NordProxyWire.connectTarget(fromHeader: header) else {
                Self.fail(client, status: 405, reason: "Method Not Allowed")
                return
            }
            guard let upstream = self.upstream else {
                Self.fail(client, status: 502, reason: "Bad Gateway")
                return
            }
            Self.openTunnel(to: target, through: upstream, using: self.upstreamParameters(), queue: self.queue) { result in
                switch result {
                case .success(let (server, leftover)):
                    client.send(content: NordProxyWire.established, completion: .contentProcessed { _ in })
                    if !rest.isEmpty { server.send(content: rest, completion: .contentProcessed { _ in }) }
                    if !leftover.isEmpty { client.send(content: leftover, completion: .contentProcessed { _ in }) }
                    Self.pipe(from: client, to: server)
                    Self.pipe(from: server, to: client)
                case .failure(let error):
                    if case .rejected(407) = error {
                        Self.fail(client, status: 502, reason: "Proxy Credentials Rejected")
                    } else {
                        Self.fail(client, status: 502, reason: "Bad Gateway")
                    }
                }
            }
        }
    }

    /// Opens a TLS connection to the NordVPN server and asks it to CONNECT to `target`. On success, returns
    /// the ready connection and any bytes the server sent after its reply header.
    static func openTunnel(to target: String,
                           through upstream: NordProxyUpstream,
                           using parameters: NWParameters = NWParameters(tls: NWProtocolTLS.Options()),
                           queue: DispatchQueue,
                           completion: @escaping @Sendable (Result<(NWConnection, Data), NordProxyTunnelError>) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: upstream.port) else {
            completion(.failure(.cannotReachServer("invalid port")))
            return
        }
        let server = NWConnection(host: NWEndpoint.Host(upstream.host), port: port, using: parameters)
        let finisher = OnceFinisher(completion)
        queue.asyncAfter(deadline: .now() + timeout) {
            if finisher.finish(.failure(.timedOut)) { server.cancel() }
        }
        server.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = NordProxyWire.connectRequest(target: target, authorization: upstream.authorization)
                server.send(content: request, completion: .contentProcessed { _ in })
                readHeader(from: server, buffer: Data()) { header, rest in
                    guard let header, let status = NordProxyWire.statusCode(fromHeader: header) else {
                        if finisher.finish(.failure(.badResponse)) { server.cancel() }
                        return
                    }
                    guard status == 200 else {
                        if finisher.finish(.failure(.rejected(status: status))) { server.cancel() }
                        return
                    }
                    if !finisher.finish(.success((server, rest))) { server.cancel() }
                }
            case .waiting(let error), .failed(let error):
                if finisher.finish(.failure(.cannotReachServer(error.localizedDescription))) { server.cancel() }
            default:
                break
            }
        }
        server.start(queue: queue)
    }

    private static func readHeader(from connection: NWConnection,
                                   buffer: Data,
                                   completion: @escaping @Sendable (Data?, Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let split = NordProxyWire.splitHeader(buffer) {
                completion(split.header, split.rest)
            } else if isComplete || error != nil || buffer.count > NordProxyWire.maxHeaderLength {
                completion(nil, Data())
            } else {
                readHeader(from: connection, buffer: buffer, completion: completion)
            }
        }
    }

    private static func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            guard let data, !data.isEmpty else {
                if isComplete || error != nil {
                    source.cancel()
                    destination.cancel()
                } else {
                    pipe(from: source, to: destination)
                }
                return
            }
            destination.send(content: data, completion: .contentProcessed { sendError in
                if sendError != nil || isComplete || error != nil {
                    source.cancel()
                    destination.cancel()
                } else {
                    pipe(from: source, to: destination)
                }
            })
        }
    }

    private static func fail(_ client: NWConnection, status: Int, reason: String) {
        client.send(content: NordProxyWire.failureResponse(status: status, reason: reason),
                    completion: .contentProcessed { _ in client.cancel() })
    }
}

/// Delivers a result once, whichever of the connection callbacks or the timeout gets there first.
private final class OnceFinisher<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let completion: @Sendable (Value) -> Void

    init(_ completion: @escaping @Sendable (Value) -> Void) {
        self.completion = completion
    }

    /// Returns true if this call delivered the result.
    @discardableResult
    func finish(_ value: Value) -> Bool {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { completion(value) }
        return first
    }
}
