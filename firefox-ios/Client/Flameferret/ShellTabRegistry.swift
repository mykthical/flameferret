// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Tabs owned by the YouTube shell rather than a browser window. The extension engine treats
/// them like browser tabs so `tabs.*` APIs, popups and messaging work on the player.
@MainActor
final class ShellTabRegistry {
    static let shared = ShellTabRegistry()

    private final class WeakTab {
        weak var tab: Tab?
        init(_ tab: Tab) { self.tab = tab }
    }

    private var entries: [WeakTab] = []
    private weak var active: Tab?

    /// Asked to open a URL in a new shell tab (`tabs.create`, `downloads.download`).
    var openHandler: ((URL) -> Tab?)?
    /// Asked to close a shell tab (`tabs.remove`).
    var closeHandler: ((Tab) -> Void)?

    var tabs: [Tab] {
        entries.removeAll { $0.tab == nil }
        return entries.compactMap { $0.tab }
    }

    var activeTab: Tab? { active }

    func register(_ tab: Tab) {
        guard !contains(tab) else { return }
        entries.append(WeakTab(tab))
    }

    func unregister(_ tab: Tab) {
        entries.removeAll { $0.tab == nil || $0.tab === tab }
        if active === tab { active = nil }
    }

    func setActive(_ tab: Tab?) {
        active = tab
    }

    func contains(_ tab: Tab) -> Bool {
        return entries.contains { $0.tab === tab }
    }
}
