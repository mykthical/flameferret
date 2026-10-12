// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import Glean
import MozillaAppServices

/// Glean ping uploader that never sends anything over the network.
struct GleanPingUploader: PingUploader {
    init?() {}

    /// Flameferret never uploads telemetry. Reporting the ping as incapable makes Glean discard it.
    func upload(request: CapablePingUploadRequest,
                callback: @escaping @Sendable (UploadResult) -> Void) {
        callback(.incapable(unused: 0))
    }
}

/// Adding a protocol on top of the `Glean.PingUploadRequest` so we can unit tests
protocol GleanPingUploadRequest {
    var url: String { get }
    var data: [UInt8] { get }
    var headers: HeadersList { get }
}

extension PingUploadRequest: GleanPingUploadRequest {}
