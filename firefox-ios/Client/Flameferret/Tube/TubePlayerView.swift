// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import AVKit
import SwiftUI
import UIKit

/// Owns playback and the native details for one video. Plays natively with Apple's player when
/// YouTube hands out a stream, and falls back to YouTube's own player in a Ferret tab otherwise.
@available(iOS 18.0, *)
@MainActor
final class TubePlayerModel: ObservableObject {
    enum Phase: Equatable {
        case resolving, native, web
    }

    @Published private(set) var videoID: String
    @Published private(set) var details: TubeVideoDetails?
    @Published private(set) var error: String?
    @Published private(set) var phase: Phase = .resolving
    @Published private(set) var native: TubeNativePlayback? { didSet { resources.native = native } }
    @Published private(set) var webTab: TubeWebTab? { didSet { resources.webTab = webTab } }
    /// Web player only: set when the video still hasn't loaded a few seconds after opening.
    @Published private(set) var stall: Stall?
    @Published private(set) var comments: TubeCommentsModel?
    /// Why the native player wasn't used, for the web fallback's banner.
    private(set) var nativeFailure: String?


    struct Stall: Equatable {
        var message: String?
    }

    private let fallback: TubeVideo
    private let resources = Resources()

    /// What has to be torn down when the screen goes away (read from `deinit`).
    private final class Resources: @unchecked Sendable {
        var native: TubeNativePlayback?
        var webTab: TubeWebTab?
    }

    init(video: TubeVideo) {
        videoID = video.id
        fallback = video
    }

    deinit {
        let resources = resources
        Task { @MainActor in
            resources.webTab?.close()
            resources.native?.stop()
        }
    }

    var video: TubeVideo {
        details?.video ?? (videoID == fallback.id ? fallback : TubeVideo(id: videoID, title: ""))
    }

    /// Plays in YouTube's own mobile player. The page is shown untouched and cropped to the player.
    func startPlayback() async {
        guard phase == .resolving else { return }
        webTab = makeWebTab(url: video.watchURL, mode: .player)
        phase = .web
        await watchPlayback()
    }

    private func makeWebTab(url: URL, mode: TubeWebTab.Mode) -> TubeWebTab {
        let tab = TubeWebTab(url: url, mode: mode)
        tab.onNavigate = { [weak self] url in
            guard let self, mode == .player,
                  let id = TubeLinks.videoID(from: url.absoluteString), id != self.videoID else { return }
            self.videoID = id
            self.details = nil
            self.comments = nil
            self.stall = nil
            Task { await self.loadDetails() }
        }
        tab.activate()
        return tab
    }

    /// Leaving the app mid-video starts Picture in Picture, like Apple's player does.
    func appWillResignActive() {
        webTab?.enterPictureInPictureIfPlaying()
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
            updateNowPlaying()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func updateNowPlaying() {
        guard let native, !video.title.isEmpty else { return }
        native.setMetadata(title: video.title, author: video.authorName, artworkURL: video.thumbnailURL)
    }

    func pause() {
        native?.player.pause()
        webTab?.pause()
    }

    /// Leaving the screen pauses playback, unless the video is playing in Picture in Picture.
    func didLeaveScreen() {
        if native?.isPictureInPictureActive == true { return }
        native?.player.pause()
    }

    /// Web player only: watches the first seconds of playback and surfaces why nothing loaded.
    func watchPlayback() async {
        guard let webTab else { return }
        stall = nil
        let id = videoID
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
                stall = Stall(message: message)
                return
            }
        }
        // A paused, unloaded video is just waiting for a tap; only flag one that tried to play.
        if let state = await webTab.playbackState(), state.readyState == 0, !state.paused {
            stall = Stall(message: nil)
        }
    }

    func retry() {
        stall = nil
        webTab?.reload()
    }
}

@available(iOS 18.0, *)
struct TubePlayerView: View {
    @StateObject private var model: TubePlayerModel
    @EnvironmentObject private var library: TubeLibrary
    @State private var expanded = false
    @State private var quality = TubeQuality.preferred

    init(video: TubeVideo) {
        _model = StateObject(wrappedValue: TubePlayerModel(video: video))
    }

    private var video: TubeVideo { model.video }
    private var showsFullPage: Bool { model.webTab?.showsFullPage ?? false }

    var body: some View {
        VStack(spacing: 0) {
            playerArea
            ScrollView {
                details
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let webTab = model.webTab {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { webTab.startPictureInPicture() } label: {
                        Label("Picture in Picture", systemImage: "pip.enter")
                    }
                }
            }
        }
        .onAppear { model.webTab?.activate() }
        .onDisappear { model.didLeaveScreen() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            model.appWillResignActive()
        }
        .task { await model.startPlayback() }
        .task(id: model.videoID) {
            if model.details == nil { await model.loadDetails() }
        }
    }

    // MARK: Player

    @ViewBuilder
    private var playerArea: some View {
        switch model.phase {
        case .resolving:
            ZStack {
                Color.black
                ProgressView().tint(.white)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
        case .native:
            if let native = model.native {
                TubeAVPlayerView(playback: native)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
                    .overlay(alignment: .topLeading) { TubeSkipToast(playback: native) }
            }
        case .web:
            if let webTab = model.webTab {
                webPlayer(webTab)
            }
        }
    }

    private func webPlayer(_ webTab: TubeWebTab) -> some View {
        TubeWebTabView(webTab: webTab)
            .aspectRatio(webTab.showsFullPage ? nil : 16 / 9, contentMode: .fit)
            .frame(maxHeight: webTab.showsFullPage ? .infinity : nil)
            .background(Color.black)
            .overlay(alignment: .bottom) {
                if let stall = model.stall, !webTab.showsFullPage {
                    TubeStallBanner(stall: stall,
                                    retry: { model.retry(); Task { await model.watchPlayback() } },
                                    showPage: { webTab.setShowsFullPage(true) })
                }
            }
            .overlay(alignment: .topTrailing) {
                if webTab.showsFullPage {
                    Button("Back to player") {
                        webTab.setShowsFullPage(false)
                        Task { await model.watchPlayback() }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .padding(10)
                }
            }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(video.title.isEmpty ? (model.webTab?.pageTitle ?? " ") : video.title)
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
                TubeCommentsCard(model: comments, video: video, pause: { model.pause() })
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
                if let native = model.native {
                    Menu {
                        Picker("Quality", selection: $quality) {
                            ForEach(TubeQuality.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Label(quality.label, systemImage: "slider.horizontal.3")
                    }
                    .onChange(of: quality) { _, newValue in native.setQuality(newValue) }
                }
                if let webTab = model.webTab {
                    Button { webTab.startPictureInPicture() } label: {
                        Label("PiP", systemImage: "pip.enter")
                    }
                    if let sponsorBlock = TubeBundledExtensions.installed(.sponsorBlock) {
                        Button {
                            webTab.activate()
                            WebExtensionManager.shared.openPopup(for: sponsorBlock)
                        } label: {
                            Label("SponsorBlock", systemImage: "forward.end.alt")
                        }
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

/// "Skipped sponsor" note over the native player.
@available(iOS 18.0, *)
struct TubeSkipToast: View {
    @ObservedObject var playback: TubeNativePlayback

    var body: some View {
        if let message = playback.skippedMessage {
            Label(message, systemImage: "forward.end.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(10)
                .transition(.opacity)
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
