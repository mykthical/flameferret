// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import Sentry

public protocol SentryWrapper: Sendable {
    var crashedInLastRun: Bool { get }
    var dsn: String? { get }

    func startWithConfigureOptions(configure options: @escaping (Options) -> Void)
    func captureMessage(message: String, with scopeBlock: @escaping (Scope) -> Void)
    func captureError(error: Error)
    func addBreadcrumb(crumb: Breadcrumb)
    func configureScope(scope: @escaping (Scope) -> Void)
}

public final class DefaultSentry: SentryWrapper {
    public init() {}

    public var crashedInLastRun: Bool {
        return SentrySDK.lastRunStatus == .didCrash
    }

    /// Crash reporting is permanently disabled in Flameferret.
    public var dsn: String? {
        return nil
    }

    public func startWithConfigureOptions(configure options: @escaping (Options) -> Void) {}

    public func captureMessage(message: String, with scopeBlock: @escaping (Scope) -> Void) {
    }

    public func captureError(error: Error) {
    }

    public func addBreadcrumb(crumb: Breadcrumb) {
    }

    public func configureScope(scope: @escaping (Scope) -> Void) {
    }
}
