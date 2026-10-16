// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Saved videos, followed channels and (optional) watch history. Stored only on this device.
@MainActor
final class TubeLibrary: ObservableObject {
    static let shared = TubeLibrary()

    @Published var saved: [TubeVideo] = [] { didSet { persist() } }
    @Published var history: [TubeVideo] = [] { didSet { persist() } }
    @Published var following: [TubeChannel] = [] { didSet { persist() } }
    @Published var historyEnabled: Bool {
        didSet {
            defaults.set(historyEnabled, forKey: Keys.historyEnabled)
            if !historyEnabled { history = [] }
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let saved = "tube.saved"
        static let history = "tube.history"
        static let following = "tube.following"
        static let historyEnabled = "tube.historyEnabled"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        historyEnabled = defaults.bool(forKey: Keys.historyEnabled)
        saved = decode(Keys.saved) ?? []
        history = decode(Keys.history) ?? []
        following = decode(Keys.following) ?? []
    }

    func isSaved(_ id: String) -> Bool { saved.contains { $0.id == id } }

    func toggleSaved(_ video: TubeVideo) {
        if let index = saved.firstIndex(where: { $0.id == video.id }) {
            saved.remove(at: index)
        } else {
            saved.insert(video, at: 0)
        }
    }

    func isFollowing(_ id: String) -> Bool { following.contains { $0.id == id } }

    func toggleFollow(_ channel: TubeChannel) {
        if let index = following.firstIndex(where: { $0.id == channel.id }) {
            following.remove(at: index)
        } else {
            following.append(channel)
        }
    }

    /// Fills in a followed channel's name or avatar once a page has loaded them.
    func refresh(_ channel: TubeChannel) {
        guard let index = following.firstIndex(where: { $0.id == channel.id }) else { return }
        var updated = following[index]
        if !channel.name.isEmpty { updated.name = channel.name }
        if let avatar = channel.avatarURL { updated.avatarURL = avatar }
        if updated != following[index] { following[index] = updated }
    }

    func recordWatch(_ video: TubeVideo) {
        guard historyEnabled, !video.title.isEmpty else { return }
        history.removeAll { $0.id == video.id }
        history.insert(video, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
    }

    func wipeAll() {
        saved = []
        history = []
        following = []
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(saved), forKey: Keys.saved)
        defaults.set(try? JSONEncoder().encode(history), forKey: Keys.history)
        defaults.set(try? JSONEncoder().encode(following), forKey: Keys.following)
    }
}

/// A paged list of videos backed by an InnerTube endpoint.
@MainActor
final class TubeFeed: ObservableObject {
    enum Source: Equatable {
        case browse(String, params: String?)
        case search(String)
    }

    @Published private(set) var videos: [TubeVideo] = []
    @Published private(set) var channels: [TubeChannel] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var loadedOnce = false
    @Published private(set) var rawFirstPage: [String: Any]?

    private var source: Source?
    private var continuation: String?
    private let engine: TubeEngine

    init(engine: TubeEngine = .shared) {
        self.engine = engine
    }

    func load(_ source: Source) async {
        self.source = source
        continuation = nil
        loading = true
        error = nil
        defer {
            loading = false
            loadedOnce = true
        }
        do {
            let json: [String: Any]
            switch source {
            case let .browse(id, params): json = try await engine.browse(id, params: params)
            case let .search(query): json = try await engine.call("search", ["query": query])
            }
            rawFirstPage = json
            let page = TubeParser.page(from: json)
            videos = page.videos
            channels = page.channels
            continuation = page.continuation
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Loads each source in turn and keeps the first one that has videos.
    func load(firstNonEmpty sources: [Source]) async {
        for source in sources {
            await load(source)
            if !videos.isEmpty || Task.isCancelled { return }
        }
    }

    func loadMoreIfNeeded(after video: TubeVideo) async {
        guard video.id == videos.last?.id, let token = continuation, !loading, let source else { return }
        loading = true
        defer { loading = false }
        let endpoint: String
        switch source {
        case .browse: endpoint = "browse"
        case .search: endpoint = "search"
        }
        do {
            let page = TubeParser.page(from: try await engine.continuation(endpoint, token: token))
            let seen = Set(videos.map(\.id))
            videos += page.videos.filter { !seen.contains($0.id) }
            continuation = page.continuation == token ? nil : page.continuation
        } catch {
            continuation = nil
        }
    }
}
