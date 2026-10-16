// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import SwiftUI
import UIKit

// MARK: - Video list

@available(iOS 18.0, *)
struct TubeVideoList<Header: View>: View {
    @ObservedObject var feed: TubeFeed
    var emptyText: String
    var header: Header

    init(feed: TubeFeed, emptyText: String, @ViewBuilder header: () -> Header) {
        self.feed = feed
        self.emptyText = emptyText
        self.header = header()
    }

    var body: some View {
        List {
            header
            if let error = feed.error {
                TubeErrorRow(message: error)
            }
            ForEach(feed.videos) { video in
                NavigationLink(value: video) { TubeVideoRow(video: video) }
                    .task { await feed.loadMoreIfNeeded(after: video) }
            }
            if feed.loading {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay {
            if feed.videos.isEmpty && !feed.loading && feed.error == nil && feed.loadedOnce
                && Header.self == EmptyView.self {
                TubeEmptyState(icon: "play.rectangle", text: emptyText)
            }
        }
    }
}

@available(iOS 18.0, *)
extension TubeVideoList where Header == EmptyView {
    init(feed: TubeFeed, emptyText: String) {
        self.init(feed: feed, emptyText: emptyText) { EmptyView() }
    }
}

@available(iOS 18.0, *)
struct TubeErrorRow: View {
    let message: String
    @EnvironmentObject private var engine: TubeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            Button("Try again") { engine.reload() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .listRowSeparator(.hidden)
    }
}

// MARK: - Home

@available(iOS 18.0, *)
struct TubeHomeView: View {
    @StateObject private var feed = TubeFeed()
    @StateObject private var followed = TubeFollowingFeed()
    @EnvironmentObject private var engine: TubeEngine
    @EnvironmentObject private var router: TubeRouter
    @EnvironmentObject private var library: TubeLibrary

    var body: some View {
        NavigationStack(path: $router.homePath) {
            Group {
                if showsFollowed {
                    List {
                        ForEach(followed.videos) { video in
                            NavigationLink(value: video) { TubeVideoRow(video: video) }
                        }
                    }
                    .listStyle(.plain)
                } else {
                    TubeVideoList(feed: feed, emptyText: emptyText)
                }
            }
            .navigationTitle("Home")
            .tubeDestinations()
            .refreshable { await load() }
            .task(id: engine.sessionGeneration) {
                await load()
                await openForSimulatorCheck()
            }
        }
    }

    /// YouTube gives signed-out users no recommendations, so Home shows the newest videos from
    /// channels followed in this app instead.
    private var showsFollowed: Bool {
        feed.videos.isEmpty && !followed.videos.isEmpty
    }

    private func load() async {
        await feed.load(.browse("FEwhat_to_watch", params: nil))
        if feed.videos.isEmpty, !library.following.isEmpty {
            await followed.load(local: library.following, signedIn: false, engine: engine)
        }
    }

    private var emptyText: String {
        engine.isSignedIn
            ? "Nothing to show yet. Pull down to refresh."
            : "Sign in from Settings for recommendations, or follow channels to see their newest videos here."
    }

    /// Used only by the CI simulator check: `-openFirstVideo` or `-openVideo <id>`.
    private func openForSimulatorCheck() async {
        let args = ProcessInfo.processInfo.arguments
        guard router.homePath.isEmpty else { return }
        var target: TubeVideo?
        if args.contains("-openFirstVideo") {
            target = feed.videos.first
        }
        guard let target else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        router.homePath.append(target)
    }
}

// MARK: - Search

@available(iOS 18.0, *)
struct TubeSearchView: View {
    @StateObject private var feed = TubeFeed()
    @EnvironmentObject private var router: TubeRouter
    @State private var query = ""
    @State private var searched = false

    var body: some View {
        NavigationStack(path: $router.searchPath) {
            TubeVideoList(feed: feed, emptyText: searched
                          ? "No results. Try different words."
                          : "Search YouTube with ads, trackers and sponsor segments removed.") {
                if !feed.channels.isEmpty {
                    ForEach(feed.channels.prefix(3)) { channel in
                        NavigationLink(value: channel) {
                            HStack(spacing: 12) {
                                TubeAvatar(url: channel.avatarURL, size: 44)
                                Text(channel.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .tubeDestinations()
            .searchable(text: $query, prompt: "Search or paste a YouTube link")
            .onSubmit(of: .search) { Task { await submit() } }
            .task {
                let args = ProcessInfo.processInfo.arguments
                if !searched, let index = args.firstIndex(of: "-search"), index + 1 < args.count {
                    query = args[index + 1]
                    await submit()
                }
            }
            .overlay {
                if !searched && feed.videos.isEmpty {
                    TubeEmptyState(icon: "magnifyingglass",
                                   text: "Search YouTube with ads, trackers and sponsor segments removed.")
                }
            }
        }
    }

    private func submit() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = TubeLinks.videoID(from: text),
           text.lowercased().contains("youtu") || text.count == 11 {
            router.searchPath.append(TubeVideo(id: id, title: ""))
            return
        }
        searched = true
        await feed.load(.search(text))
    }
}

// MARK: - Following

@available(iOS 18.0, *)
@MainActor
final class TubeFollowingFeed: ObservableObject {
    @Published var videos: [TubeVideo] = []
    @Published var accountChannels: [TubeChannel] = []
    @Published var loading = false
    @Published var error: String?

    /// Newest videos from YouTube subscriptions (when signed in) plus channels followed in this app.
    func load(local: [TubeChannel], signedIn: Bool, engine: TubeEngine) async {
        loading = true
        error = nil
        defer { loading = false }
        var all: [TubeVideo] = []
        if signedIn {
            do {
                all += TubeParser.page(from: try await engine.browse("FEsubscriptions")).videos
            } catch {
                self.error = error.localizedDescription
            }
            if let channels = try? await engine.browse("FEchannels") {
                accountChannels = TubeParser.page(from: channels).channels
            }
        } else {
            accountChannels = []
        }
        let channelTasks = local.map { channel in
            Task { @MainActor () -> [TubeVideo] in
                guard let json = try? await engine.browse(channel.id, params: TubeChannelView.videosTabParams) else {
                    return []
                }
                return TubeParser.page(from: json).videos
            }
        }
        for task in channelTasks {
            all += await task.value
        }
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0.id).inserted }
        let dated = unique.enumerated().sorted { lhs, rhs in
            let l = lhs.element.approximateDate, r = rhs.element.approximateDate
            switch (l, r) {
            case let (l?, r?): return l > r
            default: return lhs.offset < rhs.offset
            }
        }
        videos = Array(dated.map(\.element).prefix(300))
    }
}

@available(iOS 18.0, *)
struct TubeFollowingView: View {
    @EnvironmentObject private var library: TubeLibrary
    @EnvironmentObject private var engine: TubeEngine
    @EnvironmentObject private var router: TubeRouter
    @StateObject private var feed = TubeFollowingFeed()

    private var channels: [TubeChannel] {
        var seen = Set<String>()
        return (library.following + feed.accountChannels).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        NavigationStack(path: $router.followingPath) {
            Group {
                if channels.isEmpty && !engine.isSignedIn {
                    TubeEmptyState(icon: "person.2",
                                   text: "Follow channels to see their newest videos here. "
                                       + "Your list stays on this phone. No account needed.")
                } else {
                    List {
                        if !channels.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    ForEach(channels) { channel in
                                        NavigationLink(value: channel) {
                                            VStack(spacing: 6) {
                                                TubeAvatar(url: channel.avatarURL, size: 56)
                                                Text(channel.name.isEmpty ? "Channel" : channel.name)
                                                    .font(.caption).lineLimit(1).frame(width: 72)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .listRowSeparator(.hidden)
                        }
                        if let error = feed.error { TubeErrorRow(message: error) }
                        ForEach(feed.videos) { video in
                            NavigationLink(value: video) { TubeVideoRow(video: video) }
                        }
                        if feed.loading && feed.videos.isEmpty {
                            HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await reload() }
                }
            }
            .navigationTitle("Following")
            .tubeDestinations()
            .task(id: "\(library.following.map(\.id))-\(engine.sessionGeneration)-\(engine.isSignedIn)") {
                await reload()
            }
        }
    }

    private func reload() async {
        await feed.load(local: library.following, signedIn: engine.isSignedIn, engine: engine)
    }
}

// MARK: - Channel

@available(iOS 18.0, *)
struct TubeChannelView: View {
    static let videosTabParams = "EgZ2aWRlb3PyBgQKAjoA"

    let channel: TubeChannel
    @StateObject private var feed = TubeFeed()
    @State private var expanded = false

    private var info: TubeChannelInfo? {
        feed.rawFirstPage.map { TubeParser.channelInfo(from: $0, fallback: channel) }
    }

    var body: some View {
        let shown = info?.channel ?? channel
        TubeVideoList(feed: feed, emptyText: "No videos yet.") {
            VStack(spacing: 12) {
                TubeAvatar(url: shown.avatarURL, size: 84)
                Text(shown.name.isEmpty ? " " : shown.name)
                    .font(.title2.weight(.bold)).multilineTextAlignment(.center)
                let stats = [info?.subscriberText, info?.videoCountText].compactMap { $0 }
                if !stats.isEmpty {
                    Text(stats.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                }
                TubeFollowButton(channel: shown)
                if let description = info?.description {
                    Text(description).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(expanded ? nil : 3)
                        .onTapGesture { withAnimation { expanded.toggle() } }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
        }
        .navigationTitle(shown.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await feed.load(.browse(channel.id, params: Self.videosTabParams)) }
        .task {
            if !feed.loadedOnce { await feed.load(.browse(channel.id, params: Self.videosTabParams)) }
            if let loaded = info?.channel { TubeLibrary.shared.refresh(loaded) }
        }
    }
}

@available(iOS 18.0, *)
struct TubeFollowButton: View {
    let channel: TubeChannel
    @EnvironmentObject private var library: TubeLibrary

    var body: some View {
        let following = library.isFollowing(channel.id)
        Button {
            library.toggleFollow(channel)
        } label: {
            Label(following ? "Following" : "Follow",
                  systemImage: following ? "checkmark" : "plus")
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(following ? Color.secondary : Color.accentColor)
        .controlSize(.small)
    }
}

// MARK: - Playlist (Watch later, Liked, YouTube history)

@available(iOS 18.0, *)
struct TubePlaylistView: View {
    let playlist: TubePlaylist
    @StateObject private var feed = TubeFeed()

    var body: some View {
        TubeVideoList(feed: feed, emptyText: "This list is empty.")
            .navigationTitle(playlist.title)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await feed.load(.browse(playlist.browseID, params: nil)) }
            .task { if !feed.loadedOnce { await feed.load(.browse(playlist.browseID, params: nil)) } }
    }
}

// MARK: - Saved

@available(iOS 18.0, *)
struct TubeSavedView: View {
    @EnvironmentObject private var library: TubeLibrary
    @EnvironmentObject private var engine: TubeEngine
    @EnvironmentObject private var router: TubeRouter

    var body: some View {
        NavigationStack(path: $router.savedPath) {
            List {
                if engine.isSignedIn {
                    Section("On YouTube") {
                        NavigationLink(value: TubePlaylist(browseID: "VLWL", title: "Watch later")) {
                            Label("Watch later", systemImage: "clock")
                        }
                        NavigationLink(value: TubePlaylist(browseID: "VLLL", title: "Liked videos")) {
                            Label("Liked videos", systemImage: "hand.thumbsup")
                        }
                        NavigationLink(value: TubePlaylist(browseID: "FEhistory", title: "YouTube history")) {
                            Label("YouTube history", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
                Section("Saved") {
                    if library.saved.isEmpty {
                        Text("Nothing saved yet").foregroundStyle(.secondary)
                    }
                    ForEach(library.saved) { video in
                        NavigationLink(value: video) { TubeVideoRow(video: video) }
                    }
                    .onDelete { library.saved.remove(atOffsets: $0) }
                }
                if library.historyEnabled {
                    Section("History") {
                        ForEach(library.history) { video in
                            NavigationLink(value: video) { TubeVideoRow(video: video) }
                        }
                        .onDelete { library.history.remove(atOffsets: $0) }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Saved")
            .tubeDestinations()
        }
    }
}

// MARK: - Rows

@available(iOS 18.0, *)
struct TubeVideoRow: View {
    let video: TubeVideo
    @EnvironmentObject private var library: TubeLibrary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                TubeImage(url: video.thumbnailURL)
                    .frame(width: 148, height: 83)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let duration = video.durationText, !duration.isEmpty {
                    Text(duration)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(duration == "LIVE" ? Color.red : Color.black.opacity(0.72),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(.white).padding(5)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(video.title.isEmpty ? "Video" : video.title)
                    .font(.subheadline.weight(.medium)).lineLimit(3)
                if let author = video.authorName, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !video.metadataLine.isEmpty {
                    Text(video.metadataLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button { library.toggleSaved(video) } label: {
                library.isSaved(video.id)
                    ? Label("Remove from Saved", systemImage: "bookmark.slash")
                    : Label("Save", systemImage: "bookmark")
            }
            if let channel = video.channel {
                Button { library.toggleFollow(channel) } label: {
                    library.isFollowing(channel.id)
                        ? Label("Unfollow \(channel.name)", systemImage: "person.badge.minus")
                        : Label("Follow \(channel.name)", systemImage: "person.badge.plus")
                }
            }
            ShareLink(item: video.shareURL) { Label("Share", systemImage: "square.and.arrow.up") }
            Button { UIPasteboard.general.url = video.shareURL } label: { Label("Copy link", systemImage: "link") }
        }
    }
}

// MARK: - Helpers

@MainActor
enum TubeImageCache {
    static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 400
        return cache
    }()
}

@available(iOS 18.0, *)
struct TubeImage: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.fill.tertiary)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .task(id: url) {
            guard let url else { return }
            if let cached = TubeImageCache.cache.object(forKey: url as NSURL) {
                image = cached
                return
            }
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            guard let result = try? await URLSession.shared.data(for: request),
                  let loaded = UIImage(data: result.0) else { return }
            TubeImageCache.cache.setObject(loaded, forKey: url as NSURL)
            image = loaded
        }
    }
}

@available(iOS 18.0, *)
struct TubeAvatar: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        TubeImage(url: url)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
    }
}

@available(iOS 18.0, *)
struct TubeEmptyState: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
