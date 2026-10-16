// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import SwiftUI
import UIKit

/// Owns the player tab and the native details for one video.
@available(iOS 18.0, *)
@MainActor
final class TubePlayerModel: ObservableObject {
    @Published private(set) var videoID: String
    @Published private(set) var details: TubeVideoDetails?
    @Published private(set) var error: String?
    /// Set when the video still hasn't loaded a few seconds after opening; holds YouTube's message if it shows one.
    @Published private(set) var stall: Stall?
    @Published private(set) var comments: TubeCommentsModel?
    let webTab: TubeWebTab

    struct Stall: Equatable {
        var message: String?
    }

    private let fallback: TubeVideo

    init(video: TubeVideo) {
        videoID = video.id
        fallback = video
        webTab = TubeWebTab(url: video.watchURL, mode: .player)
        webTab.onNavigate = { [weak self] url in
            guard let self, let id = TubeLinks.videoID(from: url.absoluteString), id != self.videoID else { return }
            self.videoID = id
            self.details = nil
            self.comments = nil
            self.stall = nil
            Task { await self.loadDetails() }
        }
    }

    deinit {
        let tab = webTab
        Task { @MainActor in tab.close() }
    }

    var video: TubeVideo {
        details?.video ?? (videoID == fallback.id ? fallback : TubeVideo(id: videoID, title: ""))
    }

    func loadDetails() async {
        let id = videoID
        do {
            let json = try await TubeEngine.shared.call("next", ["videoId": id])
            guard id == videoID else { return }
            details = TubeParser.videoDetails(from: json, videoID: id,
                                              fallback: id == fallback.id ? fallback : nil)
            if let channelID = details?.video.channelID, let subscribed = TubeParser.subscribed(in: json) {
                TubeSubscriptions.shared.record(channelID, subscribed: subscribed)
            }
            if let token = TubeParser.commentsToken(from: json) {
                comments = TubeCommentsModel(token: token, countText: TubeParser.commentCountText(from: json))
            }
            error = nil
            if let details { TubeLibrary.shared.recordWatch(details.video) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Watches the first seconds of playback. Nudges the player to start, and if nothing has loaded,
    /// surfaces why instead of leaving a black box.
    func watchPlayback() async {
        stall = nil
        let id = videoID
        TubeEngine.log("watch: start \(id)")
        for attempt in 0..<8 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, id == videoID, !webTab.showsFullPage else { return }
            guard let state = await webTab.playbackState() else { continue }
            if state.readyState > 0 {
                stall = nil
                if attempt == 1 && state.paused { webTab.play() }
                if state.message == nil { return }
            }
            if attempt == 1 { webTab.play() }
            if let message = state.message {
                TubeEngine.log("watch: stalled with message")
                stall = Stall(message: message)
                return
            }
        }
        if let state = await webTab.playbackState(), state.readyState == 0 {
            TubeEngine.log("watch: stalled without message")
            stall = Stall(message: nil)
        }
    }

    func retry() {
        stall = nil
        webTab.reload()
    }

    func play(_ video: TubeVideo) {
        guard video.id != videoID else { return }
        webTab.load(video.watchURL)
    }
}

@available(iOS 18.0, *)
struct TubePlayerView: View {
    @StateObject private var model: TubePlayerModel
    @EnvironmentObject private var library: TubeLibrary
    @State private var expanded = false

    init(video: TubeVideo) {
        _model = StateObject(wrappedValue: TubePlayerModel(video: video))
    }

    private var video: TubeVideo { model.video }

    var body: some View {
        VStack(spacing: 0) {
            TubeWebTabView(webTab: model.webTab)
                .aspectRatio(model.webTab.showsFullPage ? nil : 16 / 9, contentMode: .fit)
                .frame(maxHeight: model.webTab.showsFullPage ? .infinity : nil)
                .background(Color.black)
                .overlay(alignment: .bottom) {
                    if let stall = model.stall, !model.webTab.showsFullPage {
                        TubeStallBanner(stall: stall,
                                        retry: { model.retry(); Task { await model.watchPlayback() } },
                                        showPage: { model.webTab.setShowsFullPage(true) })
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if model.webTab.showsFullPage {
                        Button("Back to player") {
                            model.webTab.setShowsFullPage(false)
                            Task { await model.watchPlayback() }
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .padding(10)
                    }
                }
            ScrollView {
                details
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.webTab.startPictureInPicture() } label: {
                    Label("Picture in Picture", systemImage: "pip.enter")
                }
            }
        }
        .onAppear { model.webTab.activate() }
        .task(id: model.videoID) {
            async let watching: Void = model.watchPlayback()
            if model.details == nil { await model.loadDetails() }
            await watching
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-openVideo") else { return }
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                TubeEngine.log("player: \(await model.webTab.debugState())")
            }
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(video.title.isEmpty ? (model.webTab.pageTitle ?? " ") : video.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)

            let meta = [video.viewsText, model.details?.dateText ?? video.publishedText].compactMap { $0 }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
            }

            if let channel = video.channel {
                TubeChannelRow(channel: channel, subscriberText: model.details?.subscriberText)
            }

            actions

            if let description = model.details?.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(description)
                        .font(.callout)
                        .lineLimit(expanded ? nil : 4)
                        .textSelection(.enabled)
                    Button(expanded ? "Less" : "More") { withAnimation { expanded.toggle() } }
                        .font(.callout.weight(.semibold))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
            }

            if let comments = model.comments {
                TubeCommentsCard(model: comments, video: video, pause: { model.webTab.pause() })
            } else if model.details != nil {
                Text("Comments are turned off.").font(.footnote).foregroundStyle(.secondary)
            }

            if let error = model.error, model.details == nil {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if let related = model.details?.related, !related.isEmpty {
                Text("Up next").font(.headline).padding(.top, 6)
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(related) { item in
                        NavigationLink(value: item) { TubeVideoRow(video: item) }
                            .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 24)
        }
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let isSaved = library.isSaved(video.id)
                Button { library.toggleSaved(video) } label: {
                    Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                }
                ShareLink(item: video.shareURL) { Label("Share", systemImage: "square.and.arrow.up") }
                Button { model.webTab.startPictureInPicture() } label: {
                    Label("PiP", systemImage: "pip.enter")
                }
                if let sponsorBlock = TubeBundledExtensions.installed(.sponsorBlock) {
                    Button {
                        model.webTab.activate()
                        WebExtensionManager.shared.openPopup(for: sponsorBlock)
                    } label: {
                        Label("SponsorBlock", systemImage: "forward.end.alt")
                    }
                }
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
    }
}

@available(iOS 18.0, *)
struct TubeChannelRow: View {
    let channel: TubeChannel
    var subscriberText: String?

    var body: some View {
        HStack(spacing: 10) {
            NavigationLink(value: channel) {
                HStack(spacing: 10) {
                    TubeAvatar(url: channel.avatarURL, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let subscriberText {
                            Text(subscriberText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            TubeSubscribeButton(channel: channel)
        }
    }
}

/// A full YouTube (or extension) page in a sheet: comments, sign-in hops, extension help pages.
@available(iOS 18.0, *)
struct TubePageSheet: View {
    let url: URL
    @StateObject private var webTab: TubeWebTab
    @Environment(\.dismiss) private var dismiss

    init(url: URL) {
        self.url = url
        _webTab = StateObject(wrappedValue: TubeWebTab(url: url, mode: .page))
    }

    var body: some View {
        NavigationStack {
            TubeWebTabView(webTab: webTab)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(webTab.pageTitle ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onAppear { webTab.activate() }
        .onDisappear { webTab.close() }
    }
}

/// Google's own sign-in page inside a Flameferret tab. Closes itself once YouTube is reached.
@available(iOS 18.0, *)
struct TubeSignInView: View {
    static let signInURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube&passive=true&continue=https%3A%2F%2Fm.youtube.com%2F")!

    @EnvironmentObject private var engine: TubeEngine
    @StateObject private var webTab = TubeWebTab(url: TubeSignInView.signInURL, mode: .page)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TubeWebTabView(webTab: webTab)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in to YouTube")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if webTab.isLoading { ProgressView() }
                    }
                }
        }
        .onAppear { webTab.activate() }
        .onChange(of: webTab.currentURL) { _, url in
            guard let url, let host = url.host?.lowercased(), host.hasSuffix("youtube.com"),
                  !host.hasPrefix("accounts."), !url.path.hasPrefix("/signin") else { return }
            dismiss()
        }
        .onDisappear {
            webTab.close()
            engine.didSignIn()
        }
    }
}

@available(iOS 18.0, *)
struct TubeStallBanner: View {
    let stall: TubePlayerModel.Stall
    let retry: () -> Void
    let showPage: () -> Void
    @EnvironmentObject private var engine: TubeEngine

    private var needsSignIn: Bool {
        guard !engine.isSignedIn, let message = stall.message?.lowercased() else { return false }
        return message.contains("sign in") || message.contains("not a bot")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stall.message ?? "The video hasn't started.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
            HStack(spacing: 8) {
                if needsSignIn {
                    Button("Sign in") { TubeRouter.shared.showSignIn = true }
                }
                Button("Try again", action: retry)
                Button("Show YouTube page", action: showPage)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.white)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.75))
    }
}
