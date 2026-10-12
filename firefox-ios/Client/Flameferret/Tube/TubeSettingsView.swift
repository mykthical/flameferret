// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Shared
import SwiftUI
import UIKit

@available(iOS 18.0, *)
struct TubeSettingsView: View {
    @EnvironmentObject private var library: TubeLibrary
    @EnvironmentObject private var engine: TubeEngine
    @EnvironmentObject private var router: TubeRouter
    @State private var extensions: [WebExtension] = []
    @State private var backgroundAudio = true
    @State private var refused = NetworkKillSwitch.refusedCount
    @State private var confirmWipe = false
    @State private var confirmSignOut = false
    @State private var showHub = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                extensionsSection

                Section("Playback") {
                    Toggle("Keep playing in the background", isOn: $backgroundAudio)
                        .onChange(of: backgroundAudio) { _, isOn in
                            let profile: Profile = AppContainer.shared.resolve()
                            BackgroundAudioHelper.shared.toggle(isEnabled: isOn, prefs: profile.prefs)
                        }
                }

                Section {
                    Label("No Mozilla telemetry, crash reports or experiments", systemImage: "chart.bar.xaxis")
                    Label("Firefox Sync and Mozilla accounts removed", systemImage: "person.crop.circle.badge.xmark")
                    Label("App components can't reach Mozilla's servers", systemImage: "network.slash")
                    Label("Ads and trackers blocked by uBlock Origin Lite", systemImage: "shield.checkered")
                    Label("Sponsor segments skipped by SponsorBlock", systemImage: "forward.end.alt")
                    LabeledContent("App requests refused this session", value: "\(refused)")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("When you're signed in, YouTube still keeps its own watch and search history on your "
                         + "Google account. You can pause it on YouTube's history page. SponsorBlock asks its "
                         + "server for segments using only a short hash prefix of the video ID.")
                }

                Section {
                    Toggle("Keep watch history on this device", isOn: $library.historyEnabled)
                    Button("Erase all local data", role: .destructive) { confirmWipe = true }
                } header: {
                    Text("Local data")
                } footer: {
                    Text("Saved videos, followed channels and history are kept only on this phone.")
                }
            }
            .navigationTitle("Settings")
            .task {
                reloadExtensions()
                let profile: Profile = AppContainer.shared.resolve()
                backgroundAudio = profile.prefs.boolForKey(PrefsKeys.BackgroundAudio) ?? true
                refused = NetworkKillSwitch.refusedCount
            }
            .onReceive(NotificationCenter.default.publisher(for: .webExtensionsDidChange)) { _ in
                reloadExtensions()
            }
            .confirmationDialog("Erase saved videos, followed channels and history?",
                                isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { library.wipeAll() }
            }
            .confirmationDialog("Sign out of YouTube on this device?",
                                isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await engine.signOut() } }
            }
            .sheet(isPresented: $showHub) {
                TubeExtensionsHub()
                    .ignoresSafeArea()
            }
        }
    }

    private var accountSection: some View {
        Section {
            if engine.isSignedIn {
                Label("Signed in to YouTube", systemImage: "person.crop.circle.badge.checkmark")
                Button("Sign out", role: .destructive) { confirmSignOut = true }
            } else {
                Button {
                    router.showSignIn = true
                } label: {
                    Label("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
                }
            }
            if case .failed(let why) = engine.state {
                Text(why).font(.footnote).foregroundStyle(.secondary)
                Button("Try again") { engine.reload() }
            }
        } header: {
            Text("YouTube account")
        } footer: {
            Text("Optional. Sign-in happens on Google's own page. Signed out, Following and Saved still work on this phone.")
        }
    }

    private var extensionsSection: some View {
        Section {
            if extensions.isEmpty {
                Text("Setting up extensions…").foregroundStyle(.secondary)
            }
            ForEach(extensions, id: \.uuid) { webExtension in
                TubeExtensionRow(webExtension: webExtension)
            }
            Button("More extensions…") { showHub = true }
        } header: {
            Text("Extensions")
        } footer: {
            Text("Tap an extension to open its settings.")
        }
    }

    private func reloadExtensions() {
        extensions = WebExtensionManager.shared.extensions.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}

@available(iOS 18.0, *)
struct TubeExtensionRow: View {
    let webExtension: WebExtension
    @State private var isOn: Bool

    init(webExtension: WebExtension) {
        self.webExtension = webExtension
        _isOn = State(initialValue: webExtension.isEnabled)
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = webExtension.icon(preferredSize: 64) {
                    Image(uiImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "puzzlepiece.extension")
                }
            }
            .frame(width: 28, height: 28)
            Button {
                if webExtension.hasPopup {
                    WebExtensionManager.shared.openPopup(for: webExtension)
                } else if webExtension.hasOptions {
                    WebExtensionManager.shared.openOptions(for: webExtension)
                }
            } label: {
                Text(webExtension.displayName).foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            Spacer()
            Toggle(webExtension.displayName, isOn: $isOn)
                .labelsHidden()
                .onChange(of: isOn) { _, enabled in
                    WebExtensionManager.shared.setEnabled(enabled, for: webExtension)
                }
        }
    }
}

/// Flameferret's extension manager (install from addons.mozilla.org, a link or a file).
@available(iOS 18.0, *)
struct TubeExtensionsHub: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: WebExtensionsHubViewController(manager: .shared))
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}
