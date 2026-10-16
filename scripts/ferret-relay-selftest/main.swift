import Foundation
import Network

// Usage: relay <upstreamPort> <username> <password>   — runs the relay and prints PORT=<n>
//        probe <upstreamPort> <username> <password>   — opens one tunnel and prints PROBE=ok or PROBE=<error>
let args = CommandLine.arguments
let upstream = NordProxyUpstream(host: "127.0.0.1", port: UInt16(args[2]) ?? 0,
                                 authorization: NordProxyWire.basicAuthorization(username: args.count > 3 ? args[3] : "",
                                                                                 password: args.count > 4 ? args[4] : ""))
let plainTCP: @Sendable () -> NWParameters = { .tcp }

// realprobe <proxyHost> — TLS to a real NordVPN proxy on port 89 without credentials; expects a 407.
if args[1] == "realprobe" {
    let real = NordProxyUpstream(host: args[2], port: 89, authorization: "Basic invalid")
    NordProxyRelay.openTunnel(to: "api.nordvpn.com:443", through: real, queue: DispatchQueue(label: "real")) { result in
        switch result {
        case .success(let (connection, _)):
            connection.cancel()
            print("PROBE=ok")
        case .failure(let error):
            print("PROBE=\(error)")
        }
        fflush(stdout)
        exit(0)
    }
    dispatchMain()
}
let relay = NordProxyRelay(upstreamParameters: plainTCP)

if args[1] == "relay" {
    relay.start(upstream: upstream) { port in
        print("PORT=\(port.map(String.init) ?? "none")")
        fflush(stdout)
    }
} else {
    let queue = DispatchQueue(label: "probe")
    NordProxyRelay.openTunnel(to: "127.0.0.1:\(args[5])", through: upstream, using: .tcp, queue: queue) { result in
        switch result {
        case .success(let (connection, _)):
            connection.cancel()
            print("PROBE=ok")
        case .failure(let error):
            print("PROBE=\(error)")
        }
        fflush(stdout)
        exit(0)
    }
}
dispatchMain()
