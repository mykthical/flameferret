import Foundation
import Network

// Usage: relay <upstreamPort> <username> <password>   — runs the relay and prints PORT=<n>
//        probe <upstreamPort> <username> <password>   — opens one tunnel and prints PROBE=ok or PROBE=<error>
let args = CommandLine.arguments
let upstream = NordProxyUpstream(host: "127.0.0.1", port: UInt16(args[2])!,
                                 authorization: NordProxyWire.basicAuthorization(username: args[3], password: args[4]))
let plainTCP: @Sendable () -> NWParameters = { .tcp }
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
