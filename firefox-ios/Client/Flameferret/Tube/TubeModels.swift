// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

struct TubeVideo: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var thumbnailURL: URL?
    var durationText: String?
    var authorName: String?
    var channelID: String?
    var authorAvatarURL: URL?
    var viewsText: String?
    var publishedText: String?

    init(id: String,
         title: String,
         thumbnailURL: URL? = nil,
         durationText: String? = nil,
         authorName: String? = nil,
         channelID: String? = nil,
         authorAvatarURL: URL? = nil,
         viewsText: String? = nil,
         publishedText: String? = nil) {
        self.id = id
        self.title = title
        self.thumbnailURL = thumbnailURL ?? URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
        self.durationText = durationText
        self.authorName = authorName
        self.channelID = channelID
        self.authorAvatarURL = authorAvatarURL
        self.viewsText = viewsText
        self.publishedText = publishedText
    }

    var shareURL: URL { URL(string: "https://youtu.be/\(id)") ?? TubeLinks.home }
    var watchURL: URL { URL(string: "https://m.youtube.com/watch?v=\(id)") ?? TubeLinks.home }
    /// YouTube's embed player for this video.
    var embedURL: URL {
        URL(string: "https://www.youtube.com/embed/\(id)?playsinline=1&autoplay=1&rel=0&iv_load_policy=3&fs=1")
            ?? watchURL
    }

    var channel: TubeChannel? {
        guard let channelID else { return nil }
        return TubeChannel(id: channelID, name: authorName ?? "", avatarURL: authorAvatarURL)
    }

    var approximateDate: Date? { TubeRelativeTime.date(from: publishedText) }

    var metadataLine: String {
        [viewsText, publishedText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct TubeChannel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var avatarURL: URL?
}

/// A YouTube playlist or feed shown as a list (Watch later, Liked videos, history).
struct TubePlaylist: Hashable, Sendable {
    let browseID: String
    let title: String
}

struct TubePage: Sendable {
    var videos: [TubeVideo] = []
    var channels: [TubeChannel] = []
    var continuation: String?
}

struct TubeChannelInfo: Sendable {
    var channel: TubeChannel
    var description: String?
    var subscriberText: String?
    var videoCountText: String?
}

struct TubeVideoDetails: Sendable {
    var video: TubeVideo
    var dateText: String?
    var description: String?
    var subscriberText: String?
    var related: [TubeVideo]
}

enum TubeLinks {
    static let home = URL(string: "https://m.youtube.com/")!

    /// Extracts a video ID from a YouTube URL, a youtu.be link or a bare 11-character ID.
    static func videoID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 11, trimmed.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return trimmed
        }
        guard let url = URL(string: trimmed.hasPrefix("http") ? trimmed : "https://" + trimmed),
              let host = url.host?.lowercased() else { return nil }
        if host == "youtu.be" {
            let id = url.path.split(separator: "/").first.map(String.init)
            return id.flatMap { $0.count == 11 ? $0 : nil }
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com"
                || host.hasSuffix(".youtube-nocookie.com") else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, v.count == 11 {
            return v
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]), parts[1].count == 11 {
            return parts[1]
        }
        return nil
    }

    /// Hosts the player and sign-in screens may navigate to inside the app.
    static func isInternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if ["about", "blob", "data", "moz-extension"].contains(scheme) { return true }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return false }
        let allowed = ["youtube.com", "youtu.be", "youtube-nocookie.com", "ytimg.com", "googlevideo.com",
                       "accounts.google.com", "accounts.youtube.com", "consent.youtube.com", "consent.google.com",
                       "myaccount.google.com", "gds.google.com", "sponsor.ajay.app"]
        if allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        // Google's sign-in flow hops through a few country domains (google.de, google.co.uk...).
        return host.hasPrefix("www.google.") || host.hasPrefix("accounts.google.")
    }
}

enum TubeRelativeTime {
    private static let units: [(String, TimeInterval)] = [
        ("second", 1), ("minute", 60), ("hour", 3600), ("day", 86_400),
        ("week", 604_800), ("month", 2_592_000), ("year", 31_536_000),
    ]

    /// Turns "3 days ago" / "Streamed 2 weeks ago" into an approximate date (English only).
    static func date(from text: String?, now: Date = Date()) -> Date? {
        guard let text = text?.lowercased(),
              let range = text.range(of: #"(\d+)\s+(second|minute|hour|day|week|month|year)s?\s+ago"#,
                                     options: .regularExpression) else { return nil }
        let words = text[range].split(separator: " ")
        guard words.count >= 2, let amount = Double(words[0]) else { return nil }
        let unitWord = words[1].hasSuffix("s") ? String(words[1].dropLast()) : String(words[1])
        guard let seconds = units.first(where: { $0.0 == unitWord })?.1 else { return nil }
        return now.addingTimeInterval(-amount * seconds)
    }
}
