// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import SwiftUI

extension TubeParser {
    /// Whether the signed-in account is subscribed to the channel a response is about
    /// (watch page owner or channel page header). `nil` when YouTube doesn't say.
    static func subscribed(in json: JSON) -> Bool? {
        if let button = findFirst("subscribeButtonRenderer", in: json), let value = button["subscribed"] as? Bool {
            return value
        }
        var found: Bool?
        walk(json) { key, dict in
            guard found == nil else { return true }
            if key == "subscriptionStateEntity" || key == "subscribeState", let value = dict["subscribed"] as? Bool {
                found = value
                return true
            }
            return false
        }
        return found
    }
}

/// The signed-in account's YouTube subscriptions: known states and subscribe / unsubscribe.
@MainActor
final class TubeSubscriptions: ObservableObject {
    static let shared = TubeSubscriptions()

    @Published private(set) var states: [String: Bool] = [:]
    @Published private(set) var pending: Set<String> = []
    /// Bumped after every change, so the Subscriptions tab reloads its feed.
    @Published private(set) var generation = 0
    @Published var lastError: String?

    private let engine: TubeEngine

    init(engine: TubeEngine = .shared) {
        self.engine = engine
    }

    func isSubscribed(_ channelID: String) -> Bool? {
        states[channelID]
    }

    func record(_ channelID: String, subscribed: Bool) {
        if states[channelID] != subscribed { states[channelID] = subscribed }
    }

    func recordAll(_ channels: [TubeChannel]) {
        for channel in channels where states[channel.id] != true {
            states[channel.id] = true
        }
    }

    /// Subscribes or unsubscribes. Signed out, this opens Google sign-in instead.
    func toggle(_ channel: TubeChannel) async {
        guard engine.isSignedIn else {
            if #available(iOS 18.0, *) { TubeRouter.shared.showSignIn = true }
            return
        }
        let subscribe = !(states[channel.id] ?? false)
        await set(channel.id, subscribed: subscribe)
    }

    func set(_ channelID: String, subscribed: Bool) async {
        guard !pending.contains(channelID) else { return }
        pending.insert(channelID)
        let previous = states[channelID]
        states[channelID] = subscribed
        defer { pending.remove(channelID) }
        do {
            _ = try await engine.call(subscribed ? "subscription/subscribe" : "subscription/unsubscribe",
                                      ["channelIds": [channelID]])
            generation += 1
        } catch {
            states[channelID] = previous
            lastError = subscribed
                ? "Couldn't subscribe: \(error.localizedDescription)"
                : "Couldn't unsubscribe: \(error.localizedDescription)"
        }
    }

    func reset() {
        states = [:]
        generation += 1
    }
}

/// YouTube's Subscribe / Subscribed button.
@available(iOS 18.0, *)
struct TubeSubscribeButton: View {
    let channel: TubeChannel
    @ObservedObject private var subscriptions = TubeSubscriptions.shared
    @State private var confirmUnsubscribe = false

    var body: some View {
        let subscribed = subscriptions.isSubscribed(channel.id) ?? false
        Button {
            if subscribed {
                confirmUnsubscribe = true
            } else {
                Task { await subscriptions.toggle(channel) }
            }
        } label: {
            if subscriptions.pending.contains(channel.id) {
                ProgressView().controlSize(.mini).frame(minWidth: 70)
            } else {
                Label(subscribed ? "Subscribed" : "Subscribe", systemImage: subscribed ? "bell" : "plus")
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(subscribed ? Color.secondary : Color.red)
        .controlSize(.small)
        .disabled(subscriptions.pending.contains(channel.id))
        .confirmationDialog("Unsubscribe from \(channel.name.isEmpty ? "this channel" : channel.name)?",
                            isPresented: $confirmUnsubscribe, titleVisibility: .visible) {
            Button("Unsubscribe", role: .destructive) {
                Task { await subscriptions.set(channel.id, subscribed: false) }
            }
        }
    }
}
