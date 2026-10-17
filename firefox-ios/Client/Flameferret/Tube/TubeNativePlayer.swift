// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import AVKit
import Common
import CryptoKit
import Foundation
import Shared
import SwiftUI
import UIKit

// MARK: - Streams

/// Asks YouTube for a video's stream the way its own mobile apps do, straight from the phone and
/// without cookies, so playback isn't tied to the signed-in account.
enum TubeStreams {
    struct Stream: Sendable {
        let url: URL
        let userAgent: String
        let client: String
    }

    enum Failure: LocalizedError {
        case unplayable(String)
        case noStream

        var errorDescription: String? {
            switch self {
            case .unplayable(let reason): return reason
            case .noStream: return "YouTube didn't offer a stream for this video."
            }
        }
    }

    private struct Client {
        let name: String
        let id: String
        let version: String
        let userAgent: String
        let extra: [String: Any]
    }

    private static var clients: [Client] { [
        Client(name: "IOS", id: "5", version: "20.10.4",
               userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
               extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone",
                       "osVersion": "18.3.2.22D82"]),
        Client(name: "ANDROID_VR", id: "28", version: "1.62.27",
               userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 "
                   + "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
               extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32,
                       "osName": "Android", "osVersion": "12L"]),
    ] }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    static func resolve(videoID: String) async throws -> Stream {
        var lastError: Error = Failure.noStream
        for client in clients {
            do {
                if let stream = try await request(videoID: videoID, client: client) { return stream }
            } catch let error as Failure {
                lastError = error
            } catch {
                lastError = error
            }
            if Task.isCancelled { throw CancellationError() }
        }
        throw lastError
    }

    private static func request(videoID: String, client: Client) async throws -> Stream? {
        let parts = (Locale.preferredLanguages.first ?? "en-US").split(separator: "-").map(String.init)
        var clientContext: [String: Any] = [
            "clientName": client.name, "clientVersion": client.version,
            "hl": parts.first ?? "en",
            "gl": (Locale.current as NSLocale).countryCode ?? "US",
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
        ]
        clientContext.merge(client.extra) { current, _ in current }
        let body: [String: Any] = [
            "context": ["client": clientContext],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.id, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? "UNKNOWN"
        NSLog("[FFTube] stream %@: %@", client.name, status)
        guard status == "OK" else {
            throw Failure.unplayable(playability?["reason"] as? String ?? "This video can't be played here.")
        }
        guard let streaming = json["streamingData"] as? [String: Any] else { return nil }
        if let hls = streaming["hlsManifestUrl"] as? String, let url = URL(string: hls) {
            return Stream(url: url, userAgent: client.userAgent, client: client.name)
        }
        let muxed = (streaming["formats"] as? [[String: Any]] ?? []).filter {
            ($0["url"] as? String) != nil && (($0["mimeType"] as? String) ?? "").hasPrefix("video/mp4")
        }
        if let best = muxed.max(by: { ($0["height"] as? Int ?? 0) < ($1["height"] as? Int ?? 0) }),
           let string = best["url"] as? String, let url = URL(string: string) {
            return Stream(url: url, userAgent: client.userAgent, client: client.name)
        }
        return nil
    }
}

// MARK: - SponsorBlock

/// Sponsor skipping for the native player, using SponsorBlock's public database. Only the first
/// four characters of the video ID's SHA-256 hash are sent, so the server can't tell which video it is.
enum TubeSponsorBlock {
    struct Segment: Sendable, Equatable {
        let start: Double
        let end: Double
        let category: String
    }

    enum Category: String, CaseIterable, Identifiable {
        case sponsor, selfpromo, interaction, intro, outro, preview, music_offtopic, filler

        var id: String { rawValue }

        var label: String {
            switch self {
            case .sponsor: return "Sponsors"
            case .selfpromo: return "Self-promotion"
            case .interaction: return "Subscribe reminders"
            case .intro: return "Intros"
            case .outro: return "Outros and end cards"
            case .preview: return "Previews and recaps"
            case .music_offtopic: return "Non-music in music videos"
            case .filler: return "Filler and tangents"
            }
        }

        var shortLabel: String {
            switch self {
            case .sponsor: return "sponsor"
            case .selfpromo: return "self-promotion"
            case .interaction: return "subscribe reminder"
            case .intro: return "intro"
            case .outro: return "outro"
            case .preview: return "preview"
            case .music_offtopic: return "non-music section"
            case .filler: return "filler"
            }
        }

        static let defaults: Set<Category> = [.sponsor, .selfpromo, .interaction]
    }

    private static let key = "tube.sponsorBlock.categories"

    static var enabled: Set<Category> {
        get {
            guard let raw = UserDefaults.standard.stringArray(forKey: key) else { return Category.defaults }
            return Set(raw.compactMap(Category.init(rawValue:)))
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: key) }
    }

    static func segments(for videoID: String) async -> [Segment] {
        let categories = enabled
        guard !categories.isEmpty else { return [] }
        let hash = SHA256.hash(data: Data(videoID.utf8)).map { String(format: "%02x", $0) }.joined()
        let list = "[" + categories.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")!
        components.queryItems = [URLQueryItem(name: "categories", value: list),
                                 URLQueryItem(name: "actionType", value: "skip")]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        guard let (data, response) = try? await URLSession(configuration: configuration).data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let videos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let match = videos.first(where: { $0["videoID"] as? String == videoID }),
              let segments = match["segments"] as? [[String: Any]] else { return [] }
        return segments.compactMap { item in
            guard let range = item["segment"] as? [Double], range.count == 2, range[1] > range[0],
                  let category = item["category"] as? String else { return nil }
            return Segment(start: range[0], end: range[1], category: category)
        }
        .sorted { $0.start < $1.start }
    }
}

// MARK: - Playback

/// One native playback: the AVPlayer, sponsor skipping, lock-screen info and background audio.
@MainActor
final class TubeNativePlayback: ObservableObject {
    let player: AVPlayer
    let stream: TubeStreams.Stream
    @Published private(set) var skippedMessage: String?
    @Published var isPictureInPictureActive = false

    private let videoID: String
    private var segments: [TubeSponsorBlock.Segment] = []
    private var skipped: Set<Int> = []
    private var timeObserver: Any?
    private var toastTask: Task<Void, Never>?

    init(stream: TubeStreams.Stream, videoID: String) {
        self.stream = stream
        self.videoID = videoID
        let asset = AVURLAsset(url: stream.url, options: [
            AVURLAssetHTTPCookiesKey: [HTTPCookie](),
            "AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": stream.userAgent],
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredMaximumResolution = TubeQuality.preferred.maxSize
        player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        Task { [weak self] in
            let found = await TubeSponsorBlock.segments(for: videoID)
            self?.segments = found
        }
    }

    func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func setMetadata(title: String, author: String?, artworkURL: URL?) {
        guard let item = player.currentItem else { return }
        var metadata: [AVMetadataItem] = [Self.metadata(.commonIdentifierTitle, title)]
        if let author { metadata.append(Self.metadata(.commonIdentifierArtist, author)) }
        item.externalMetadata = metadata
        guard let artworkURL else { return }
        Task { [weak item] in
            guard let image = await TubeImageCache.image(for: artworkURL),
                  let data = image.jpegData(compressionQuality: 0.8), let item else { return }
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = data as NSData
            artwork.dataType = kCMMetadataBaseDataType_JPEG as String
            item.externalMetadata = metadata + [artwork]
        }
    }

    func setQuality(_ quality: TubeQuality) {
        TubeQuality.preferred = quality
        player.currentItem?.preferredMaximumResolution = quality.maxSize
    }

    func stop() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        for (index, segment) in segments.enumerated()
        where !skipped.contains(index) && time >= segment.start && time < segment.end - 0.5 {
            skipped.insert(index)
            player.seek(to: CMTime(seconds: segment.end, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            let name = TubeSponsorBlock.Category(rawValue: segment.category)?.shortLabel ?? segment.category
            showToast("Skipped \(name)")
            break
        }
    }

    private func showToast(_ message: String) {
        skippedMessage = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.skippedMessage = nil
        }
    }

    private static func metadata(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}

enum TubeQuality: String, CaseIterable, Identifiable {
    case auto, p1080, p720, p480, p360

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p360: return "360p"
        }
    }

    var maxSize: CGSize {
        switch self {
        case .auto: return .zero
        case .p1080: return CGSize(width: 1920, height: 1080)
        case .p720: return CGSize(width: 1280, height: 720)
        case .p480: return CGSize(width: 854, height: 480)
        case .p360: return CGSize(width: 640, height: 360)
        }
    }

    static var preferred: TubeQuality {
        get { TubeQuality(rawValue: UserDefaults.standard.string(forKey: "tube.quality") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tube.quality") }
    }
}

// MARK: - Player view

/// Apple's player: full screen, Picture in Picture (also automatically when you leave the app),
/// AirPlay and speed controls. Keeps audio playing in the background when that setting is on.
struct TubeAVPlayerView: UIViewControllerRepresentable {
    @ObservedObject var playback: TubeNativePlayback

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = playback.player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        controller.delegate = context.coordinator
        context.coordinator.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detachObservers()
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let playback: TubeNativePlayback
        weak var controller: AVPlayerViewController?
        private var observers: [NSObjectProtocol] = []

        init(playback: TubeNativePlayback) {
            self.playback = playback
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterBackground() }
            })
            observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willEnterForeground() }
            })
        }

        func detachObservers() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
        }

        /// With the video layer attached, iOS pauses playback in the background. Detaching it keeps the
        /// audio going (unless Picture in Picture has taken over the video).
        private func didEnterBackground() {
            guard !playback.isPictureInPictureActive, playback.player.rate > 0,
                  BackgroundAudioHelper.isEnabled(Self.prefs) else { return }
            controller?.player = nil
        }

        private func willEnterForeground() {
            if controller?.player == nil { controller?.player = playback.player }
        }

        private static var prefs: Prefs {
            let profile: Profile = AppContainer.shared.resolve()
            return profile.prefs
        }

        nonisolated func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
            MainActor.assumeIsolated { playback.isPictureInPictureActive = true }
        }

        nonisolated func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
            MainActor.assumeIsolated { playback.isPictureInPictureActive = false }
        }

        nonisolated func playerViewController(
            _ controller: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
        ) {
            completion(true)
        }
    }
}
