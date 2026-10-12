// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

/// Reads YouTube's InnerTube JSON. It walks the whole response looking for known item shapes rather than
/// following fixed paths, so small layout changes on YouTube's side don't break the lists.
enum TubeParser {
    typealias JSON = [String: Any]

    private static let videoKeys: Set<String> = [
        "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer",
        "videoWithContextRenderer", "playlistPanelVideoRenderer", "compactAutoplayRenderer",
    ]
    private static let channelKeys: Set<String> = ["channelRenderer", "gridChannelRenderer", "compactChannelRenderer"]
    private static let skippedKeys: Set<String> = [
        "adSlotRenderer", "promotedVideoRenderer", "inFeedAdLayoutRenderer", "promotedSparklesWebRenderer",
        "promotedSparklesTextSearchRenderer", "displayAdRenderer", "searchPyvRenderer", "statementBannerRenderer",
        "reelShelfRenderer", "reelItemRenderer", "shortsLockupViewModel", "brandVideoShelfRenderer",
        "brandVideoSingletonRenderer", "mealbarPromoRenderer", "backgroundPromoRenderer",
    ]

    // MARK: Lists

    static func page(from json: JSON) -> TubePage {
        var page = TubePage()
        var seenVideos = Set<String>()
        var seenChannels = Set<String>()

        walk(json) { key, value in
            if skippedKeys.contains(key) { return true }
            if videoKeys.contains(key) {
                if let video = video(fromRenderer: value), seenVideos.insert(video.id).inserted {
                    page.videos.append(video)
                }
                return true
            }
            if key == "lockupViewModel" {
                if let video = video(fromLockup: value), seenVideos.insert(video.id).inserted {
                    page.videos.append(video)
                }
                return true
            }
            if channelKeys.contains(key) {
                if let channel = channel(fromRenderer: value), seenChannels.insert(channel.id).inserted {
                    page.channels.append(channel)
                }
                return true
            }
            if key == "continuationItemRenderer" {
                if let token = continuationToken(in: value) { page.continuation = token }
                return true
            }
            return false
        }
        return page
    }

    // MARK: Channel

    static func channelInfo(from json: JSON, fallback: TubeChannel) -> TubeChannelInfo {
        var channel = fallback
        var info = TubeChannelInfo(channel: fallback)
        if let metadata = findFirst("channelMetadataRenderer", in: json) {
            if let title = metadata["title"] as? String, !title.isEmpty { channel.name = title }
            if let description = metadata["description"] as? String, !description.isEmpty {
                info.description = description
            }
            if let avatar = thumbnailURL(metadata["avatar"]) { channel.avatarURL = avatar }
        }
        if let header = (json["header"] as? JSON) {
            let strings = allStrings(in: header)
            info.subscriberText = strings.first { $0.localizedCaseInsensitiveContains("subscriber") }
            info.videoCountText = strings.first {
                $0.localizedCaseInsensitiveContains("video") && $0.rangeOfCharacter(from: .decimalDigits) != nil
            }
            if channel.avatarURL == nil, let avatar = findFirst("avatar", in: header).flatMap({ imageURL(in: $0) }) {
                channel.avatarURL = avatar
            }
        }
        info.channel = channel
        return info
    }

    // MARK: Watch page

    static func videoDetails(from json: JSON, videoID: String, fallback: TubeVideo?) -> TubeVideoDetails {
        var video = fallback ?? TubeVideo(id: videoID, title: "")
        var details = TubeVideoDetails(video: video, related: [])

        if let primary = findFirst("videoPrimaryInfoRenderer", in: json) {
            if let title = text(primary["title"]), !title.isEmpty { video.title = title }
            if let views = findFirst("videoViewCountRenderer", in: primary) {
                video.viewsText = text(views["viewCount"]) ?? text(views["shortViewCount"]) ?? video.viewsText
            }
            details.dateText = text(primary["dateText"])
            if let relative = text(primary["relativeDateText"]) { video.publishedText = relative }
        }
        if let secondary = findFirst("videoSecondaryInfoRenderer", in: json) {
            if let owner = findFirst("videoOwnerRenderer", in: secondary) {
                if let name = text(owner["title"]) { video.authorName = name }
                if let id = browseID(in: owner) { video.channelID = id }
                if let avatar = thumbnailURL(owner["thumbnail"]) { video.authorAvatarURL = avatar }
                details.subscriberText = text(owner["subscriberCountText"])
            }
            if let attributed = secondary["attributedDescription"] as? JSON,
               let content = attributed["content"] as? String {
                details.description = content
            } else {
                details.description = text(secondary["description"])
            }
        }
        if let secondaryResults = findFirst("secondaryResults", in: json) {
            details.related = page(from: secondaryResults).videos.filter { $0.id != videoID }
        }
        details.video = video
        return details
    }

    static func isLoggedIn(_ json: JSON) -> Bool? {
        guard let context = json["responseContext"] as? JSON,
              let params = context["serviceTrackingParams"] as? [JSON] else { return nil }
        for service in params {
            for param in service["params"] as? [JSON] ?? [] where param["key"] as? String == "logged_in" {
                return (param["value"] as? String) == "1"
            }
        }
        return nil
    }

    // MARK: Item shapes

    static func video(fromRenderer r: JSON) -> TubeVideo? {
        guard let id = r["videoId"] as? String, id.count == 11 else { return nil }
        let title = text(r["title"]) ?? text(r["headline"]) ?? ""
        let byline = (r["ownerText"] ?? r["shortBylineText"] ?? r["longBylineText"]) as? JSON
        var duration = text(r["lengthText"])
        if duration == nil {
            duration = allStrings(in: r["thumbnailOverlays"] ?? [Any]()).first(where: isDuration)
        }
        let isLive = allStrings(in: r["badges"] ?? [Any]()).contains { $0.uppercased() == "LIVE" }
        return TubeVideo(
            id: id,
            title: title,
            thumbnailURL: thumbnailURL(r["thumbnail"]),
            durationText: isLive ? "LIVE" : duration,
            authorName: text(byline),
            channelID: byline.flatMap { browseID(in: $0) },
            authorAvatarURL: avatarURL(fromRenderer: r),
            viewsText: text(r["shortViewCountText"]) ?? text(r["viewCountText"]),
            publishedText: text(r["publishedTimeText"])
        )
    }

    static func video(fromLockup l: JSON) -> TubeVideo? {
        let type = l["contentType"] as? String ?? ""
        guard type.isEmpty || type.contains("VIDEO") else { return nil }
        guard let id = l["contentId"] as? String, id.count == 11 else { return nil }
        let metadata = findFirst("lockupMetadataViewModel", in: l)
        let title = metadata.flatMap { text($0["title"]) } ?? ""

        var rows: [[String]] = []
        if let rowList = metadata.flatMap({ findFirst("contentMetadataViewModel", in: $0) })?["metadataRows"] as? [JSON] {
            rows = rowList.map { row in
                (row["metadataParts"] as? [JSON] ?? []).compactMap { text($0["text"]) }
            }
        }
        let author = rows.first?.first
        let stats = rows.dropFirst().first ?? []
        let views = stats.first { $0.localizedCaseInsensitiveContains("view") || $0.localizedCaseInsensitiveContains("watching") }
        let published = stats.first { $0 != views }

        let contentImage = l["contentImage"] as? JSON ?? [:]
        let duration = allStrings(in: contentImage).first(where: isDuration)
        let isLive = allStrings(in: contentImage).contains { $0.uppercased() == "LIVE" }
        let avatar = findFirst("decoratedAvatarViewModel", in: l).flatMap { imageURL(in: $0) }

        return TubeVideo(
            id: id,
            title: title,
            thumbnailURL: imageURL(in: contentImage),
            durationText: isLive ? "LIVE" : duration,
            authorName: author,
            channelID: browseID(in: l),
            authorAvatarURL: avatar,
            viewsText: views,
            publishedText: published
        )
    }

    private static func avatarURL(fromRenderer r: JSON) -> URL? {
        if let supported = r["channelThumbnailSupportedRenderers"] as? JSON,
           let thumbnail = findValue("thumbnail", in: supported) {
            return thumbnailURL(thumbnail)
        }
        return thumbnailURL(r["channelThumbnail"])
    }

    static func channel(fromRenderer r: JSON) -> TubeChannel? {
        guard let id = r["channelId"] as? String else { return nil }
        let name = text(r["title"]) ?? text(r["displayName"]) ?? ""
        return TubeChannel(id: id, name: name, avatarURL: thumbnailURL(r["thumbnail"]))
    }

    // MARK: Helpers

    /// Visits every dictionary value with its key. Returning `true` stops descent into that value.
    static func walk(_ node: Any, _ visit: (String, JSON) -> Bool) {
        if let dict = node as? JSON {
            for (key, value) in dict {
                if let child = value as? JSON, visit(key, child) { continue }
                walk(value, visit)
            }
        } else if let array = node as? [Any] {
            for item in array { walk(item, visit) }
        }
    }

    static func findFirst(_ key: String, in node: Any) -> JSON? {
        var result: JSON?
        walk(node) { k, v in
            if result != nil { return true }
            if k == key { result = v; return true }
            return false
        }
        return result
    }

    static func findValue(_ key: String, in node: JSON) -> Any? {
        if let value = node[key] { return value }
        var result: Any?
        walkAny(node) { k, v in
            if result == nil, k == key { result = v }
            return result != nil
        }
        return result
    }

    private static func walkAny(_ node: Any, _ visit: (String, Any) -> Bool) {
        if let dict = node as? JSON {
            for (key, value) in dict {
                if visit(key, value) { return }
                walkAny(value, visit)
            }
        } else if let array = node as? [Any] {
            for item in array { walkAny(item, visit) }
        }
    }

    /// Reads `simpleText`, `runs`, `content` and accessibility labels.
    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string.isEmpty ? nil : string }
        guard let dict = value as? JSON else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let content = dict["content"] as? String { return content }
        if let runs = dict["runs"] as? [JSON] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        if let accessibility = dict["accessibility"] as? JSON,
           let data = accessibility["accessibilityData"] as? JSON,
           let label = data["label"] as? String {
            return label
        }
        return nil
    }

    static func thumbnailURL(_ value: Any?) -> URL? {
        guard let dict = value as? JSON else { return nil }
        let list = (dict["thumbnails"] as? [JSON]) ?? ((dict["thumbnail"] as? JSON)?["thumbnails"] as? [JSON])
        guard let best = list?.max(by: { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }) ?? list?.last,
              let url = best["url"] as? String else { return nil }
        return normalizedURL(url)
    }

    /// Picks the largest image from a view-model `sources` list anywhere under `node`.
    static func imageURL(in node: Any) -> URL? {
        var best: (Int, String)?
        walkAny(node) { key, value in
            guard key == "sources", let sources = value as? [JSON] else { return false }
            for source in sources {
                guard let url = source["url"] as? String else { continue }
                let width = source["width"] as? Int ?? 0
                if best == nil || width > best!.0 { best = (width, url) }
            }
            return best != nil
        }
        return best.flatMap { normalizedURL($0.1) }
    }

    static func normalizedURL(_ string: String) -> URL? {
        if string.hasPrefix("//") { return URL(string: "https:" + string) }
        return URL(string: string)
    }

    static func browseID(in node: Any) -> String? {
        var found: String?
        walkAny(node) { key, value in
            if key == "browseEndpoint", let endpoint = value as? JSON,
               let id = endpoint["browseId"] as? String, id.hasPrefix("UC") {
                found = id
            }
            return found != nil
        }
        return found
    }

    static func continuationToken(in node: Any) -> String? {
        var token: String?
        walkAny(node) { key, value in
            if key == "continuationCommand", let command = value as? JSON, let t = command["token"] as? String {
                token = t
            } else if key == "nextContinuationData", let data = value as? JSON,
                      let t = data["continuation"] as? String {
                token = t
            }
            return token != nil
        }
        return token
    }

    static func allStrings(in node: Any) -> [String] {
        var strings: [String] = []
        if let text = text(node) { strings.append(text) }
        walkAny(node) { _, value in
            if let s = value as? String, !s.isEmpty { strings.append(s) }
            if let t = text(value), !(value is String) { strings.append(t) }
            return false
        }
        return strings
    }

    static func isDuration(_ string: String) -> Bool {
        return string.range(of: #"^\d{1,2}(:\d{2}){1,2}$"#, options: .regularExpression) != nil
    }
}
