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
    let webTab: TubeWebTab

    private let fallback: TubeVideo

    init(video: TubeVideo) {
        videoID = video.id
        fallback = video
        webTab = TubeWebTab(url: video.watchURL, mode: .player)
        webTab.onNavigate = { [weak self] url in
            guard let self, let id = TubeLinks.videoID(from: url.absoluteString), id != self.videoID else { return }
            self.videoID = id
            self.details = nil
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
            error = nil
            if let details { TubeLibrary.shared.recordWatch(details.video) }
        } catch {
            self.error = error.localizedDescription
        }
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
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
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
            if model.details == nil { await model.loadDetails() }
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
                Button {
                    model.webTab.pause()
                    TubeRouter.shared.pageSheet = .init(url: video.watchURL)
                } label: {
                    Label("Comments", systemImage: "text.bubble")
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
            TubeFollowButton(channel: channel)
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
