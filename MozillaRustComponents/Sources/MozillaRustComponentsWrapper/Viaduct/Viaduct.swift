/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

#if canImport(MozillaRustComponents)
    import MozillaRustComponents
#endif

/// The public interface to viaduct.
///
/// This is a singleton, and should be used via the
/// `shared` static member.
///
/// Flameferret installs a backend that refuses every request, so no Rust component
/// (accounts, sync, experiments, remote settings, suggestions, push) can reach the network.
public class Viaduct {
    /// The singleton instance of Viaduct
    /// FIXME: FXIOS-13501 Unprotected shared mutable state is an error in Swift 6
    public nonisolated(unsafe) static let shared = Viaduct()

    private let lock = NSLock()
    private var isInitialized = false

    private init() {}

    public func initialize(userAgent: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !isInitialized else { return }
        isInitialized = true

        uniffiEnsureViaductInitialized()
        setGlobalDefaultUserAgent(userAgent: userAgent)
        initBackend(backend: OfflineViaductBackend())
    }
}

/// A viaduct backend that never touches the network.
public final class OfflineViaductBackend: Backend {
    public init() {}

    public func sendRequest(request: Request, settings: ClientSettings) async throws -> Response {
        throw ViaductError.NetworkError("Network access from app components is disabled in Flameferret")
    }
}
