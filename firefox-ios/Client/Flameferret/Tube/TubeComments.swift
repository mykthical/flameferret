// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import SwiftUI

struct TubeComment: Identifiable, Equatable, Sendable {
    let id: String
    var author: String
    var authorAvatarURL: URL?
    var authorChannelID: String?
    var text: String
    var publishedText: String?
    var likeText: String?
    var replyText: String?
    var isPinned = false
}

struct TubeCommentPage: Sendable {
    var comments: [TubeComment] = []
    var continuation: String?
    var countText: String?
}

extension TubeParser {
    /// The token that loads a video's first page of comments, from a `next` response.
    static func commentsToken(from json: JSON) -> String? {
        var token: String?
        walk(json) { _, dict in
            guard token == nil else { return true }
            if dict["sectionIdentifier"] as? String == "comment-item-section" {
                token = continuationToken(in: dict)
                return true
            }
            return false
        }
        if token != nil { return token }
        walk(json) { _, dict in
            guard token == nil else { return true }
            if dict["panelIdentifier"] as? String == "engagement-panel-comments-section" {
                token = continuationToken(in: dict)
                return true
            }
            return false
        }
        return token
    }

    /// "1.2K" style comment count shown on the watch page, when YouTube includes it.
    static func commentCountText(from json: JSON) -> String? {
        if let header = findFirst("commentsEntryPointHeaderRenderer", in: json),
           let count = text(header["commentCount"]) {
            return count
        }
        var found: String?
        walk(json) { _, dict in
            guard found == nil else { return true }
            if dict["panelIdentifier"] as? String == "engagement-panel-comments-section",
               let header = findFirst("engagementPanelTitleHeaderRenderer", in: dict) {
                found = text(header["contextualInfo"])
                return true
            }
            return false
        }
        return found
    }

    /// Reads one page of comments from a `next` continuation response. Handles YouTube's entity
    /// format (`commentViewModel` + `commentEntityPayload` mutations) and the older `commentRenderer`.
    static func commentPage(from json: JSON) -> TubeCommentPage {
        var page = TubeCommentPage()
        var payloads: [String: JSON] = [:]
        if let updates = json["frameworkUpdates"] as? JSON,
           let batch = updates["entityBatchUpdate"] as? JSON,
           let mutations = batch["mutations"] as? [JSON] {
            for mutation in mutations {
                guard let key = mutation["entityKey"] as? String, let payload = mutation["payload"] as? JSON else { continue }
                if let comment = payload["commentEntityPayload"] as? JSON { payloads[key] = comment }
            }
        }

        var items: [JSON] = []
        for key in ["onResponseReceivedEndpoints", "onResponseReceivedActions"] {
            for endpoint in json[key] as? [JSON] ?? [] {
                for command in ["reloadContinuationItemsCommand", "appendContinuationItemsAction"] {
                    if let body = endpoint[command] as? JSON, let list = body["continuationItems"] as? [JSON] {
                        items += list
                    }
                }
            }
        }

        for item in items {
            if let header = item["commentsHeaderRenderer"] as? JSON {
                page.countText = text(header["countText"]) ?? text(header["commentsCount"])
            } else if let thread = item["commentThreadRenderer"] as? JSON {
                let replyText = (thread["replies"] as? JSON).flatMap { replies in
                    findFirst("commentRepliesRenderer", in: replies).flatMap { text($0["viewReplies"]) }
                }
                if let model = findFirst("commentViewModel", in: thread),
                   let commentKey = (model["commentViewModel"] as? JSON)?["commentKey"] as? String
                    ?? model["commentKey"] as? String,
                   let payload = payloads[commentKey],
                   var comment = comment(fromEntity: payload) {
                    if comment.replyText == nil { comment.replyText = replyText }
                    if (model["commentViewModel"] as? JSON)?["pinnedText"] != nil || model["pinnedText"] != nil {
                        comment.isPinned = true
                    }
                    page.comments.append(comment)
                } else if let renderer = findFirst("commentRenderer", in: thread),
                          var comment = comment(fromRenderer: renderer) {
                    if comment.replyText == nil { comment.replyText = replyText }
                    page.comments.append(comment)
                }
            } else if item["continuationItemRenderer"] != nil {
                page.continuation = continuationToken(in: item)
            }
        }
        return page
    }

    private static func comment(fromEntity payload: JSON) -> TubeComment? {
        guard let properties = payload["properties"] as? JSON,
              let id = properties["commentId"] as? String else { return nil }
        let author = payload["author"] as? JSON ?? [:]
        let toolbar = payload["toolbar"] as? JSON ?? [:]
        let body = text(properties["content"]) ?? ""
        var replies = toolbar["replyCount"] as? String
        if let count = replies, count.isEmpty || count == "0" { replies = nil }
        let likes = (toolbar["likeCountNotliked"] as? String).flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
        return TubeComment(
            id: id,
            author: author["displayName"] as? String ?? "",
            authorAvatarURL: (author["avatarThumbnailUrl"] as? String).flatMap(normalizedURL)
                ?? (payload["avatar"]).flatMap { imageURL(in: $0) },
            authorChannelID: author["channelId"] as? String,
            text: body,
            publishedText: properties["publishedTime"] as? String,
            likeText: likes,
            replyText: replies.map { $0 == "1" ? "1 reply" : "\($0) replies" }
        )
    }

    private static func comment(fromRenderer r: JSON) -> TubeComment? {
        guard let id = r["commentId"] as? String else { return nil }
        let likes = text(r["voteCount"])
        let replyCount = r["replyCount"] as? Int ?? 0
        return TubeComment(
            id: id,
            author: text(r["authorText"]) ?? "",
            authorAvatarURL: thumbnailURL(r["authorThumbnail"]),
            authorChannelID: r["authorEndpoint"].flatMap { browseID(in: $0) },
            text: text(r["contentText"]) ?? "",
            publishedText: text(r["publishedTimeText"]),
            likeText: likes,
            replyText: replyCount > 0 ? (replyCount == 1 ? "1 reply" : "\(replyCount) replies") : nil,
            isPinned: r["pinnedCommentBadge"] != nil
        )
    }
}

/// Loads a video's comments page by page.
@MainActor
final class TubeCommentsModel: ObservableObject, Identifiable {
    @Published private(set) var comments: [TubeComment] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var countText: String?
    @Published private(set) var loadedOnce = false
    private var next: String?

    init(token: String, countText: String?) {
        self.next = token
        self.countText = countText
    }

    var hasMore: Bool { next != nil }

    func loadMore() async {
        guard let token = next, !loading else { return }
        loading = true
        error = nil
        defer {
            loading = false
            loadedOnce = true
        }
        do {
            let json = try await TubeEngine.shared.continuation("next", token: token)
            let page = TubeParser.commentPage(from: json)
            let seen = Set(comments.map(\.id))
            comments += page.comments.filter { !seen.contains($0.id) }
            if let count = page.countText { countText = count }
            next = page.continuation == token ? nil : page.continuation
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The comments preview on the watch page; tapping opens the full list.
@available(iOS 18.0, *)
struct TubeCommentsCard: View {
    @ObservedObject var model: TubeCommentsModel
    let video: TubeVideo
    let pause: () -> Void
    @State private var showAll = false

    var body: some View {
        Button { showAll = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Comments").font(.headline)
                    if let count = model.countText {
                        Text(count).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                if let first = model.comments.first {
                    HStack(alignment: .top, spacing: 8) {
                        TubeAvatar(url: first.authorAvatarURL, size: 24)
                        Text(first.text).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                    }
                } else if model.loading || !model.loadedOnce {
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                } else if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("No comments yet.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .task {
            if !model.loadedOnce { await model.loadMore() }
            if ProcessInfo.processInfo.arguments.contains("-openComments") { showAll = true }
        }
        .sheet(isPresented: $showAll) {
            TubeCommentsSheet(model: model, video: video, pause: pause)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

@available(iOS 18.0, *)
struct TubeCommentsSheet: View {
    @ObservedObject var model: TubeCommentsModel
    let video: TubeVideo
    let pause: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.comments) { comment in
                    TubeCommentRow(comment: comment)
                        .task { if comment.id == model.comments.last?.id { await model.loadMore() } }
                }
                if model.loading {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .navigationTitle(model.countText.map { "Comments · \($0)" } ?? "Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        pause()
                        dismiss()
                        TubeRouter.shared.pageSheet = .init(url: video.watchURL)
                    } label: {
                        Label("Add a comment", systemImage: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { if !model.loadedOnce { await model.loadMore() } }
        }
    }
}

@available(iOS 18.0, *)
struct TubeCommentRow: View {
    let comment: TubeComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TubeAvatar(url: comment.authorAvatarURL, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if comment.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(comment.author).font(.caption.weight(.semibold)).lineLimit(1)
                    if let published = comment.publishedText {
                        Text("· \(published)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(comment.text).font(.callout).textSelection(.enabled)
                HStack(spacing: 14) {
                    if let likes = comment.likeText {
                        Label(likes, systemImage: "hand.thumbsup").labelStyle(.titleAndIcon)
                    }
                    if let replies = comment.replyText {
                        Text(replies)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
