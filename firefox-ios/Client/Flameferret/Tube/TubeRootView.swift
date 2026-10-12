// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import SwiftUI
import UIKit

enum TubeAppTab: Hashable {
    case home, following, saved, settings, search
}

/// Routes links (from extensions, the player or other apps) to the right screen.
@available(iOS 18.0, *)
@MainActor
final class TubeRouter: ObservableObject {
    static let shared = TubeRouter()

    struct PageSheet: Identifiable {
        let id = UUID()
        let url: URL
    }

    @Published var selection: TubeAppTab = .home
    @Published var homePath = NavigationPath()
    @Published var followingPath = NavigationPath()
    @Published var savedPath = NavigationPath()
    @Published var searchPath = NavigationPath()
    @Published var pageSheet: PageSheet?
    @Published var showSignIn = false

    func open(_ url: URL) {
        if let id = TubeLinks.videoID(from: url.absoluteString) {
            push(TubeVideo(id: id, title: ""))
        } else if let channelID = Self.channelID(from: url) {
            push(TubeChannel(id: channelID, name: ""))
        } else if TubeLinks.isInternal(url) {
            pageSheet = PageSheet(url: url)
        } else if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            UIApplication.shared.open(url)
        }
    }

    func push<Value: Hashable>(_ value: Value) {
        switch selection {
        case .home: homePath.append(value)
        case .following: followingPath.append(value)
        case .saved: savedPath.append(value)
        case .search: searchPath.append(value)
        case .settings:
            selection = .home
            homePath.append(value)
        }
    }

    private static func channelID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.hasSuffix("youtube.com") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "channel", parts[1].hasPrefix("UC") { return parts[1] }
        return nil
    }
}

/// The app's main screen: native tabs on top of the Flameferret engine.
@available(iOS 18.0, *)
struct TubeRootView: View {
    @ObservedObject private var library = TubeLibrary.shared
    @ObservedObject private var engine = TubeEngine.shared
    @ObservedObject private var router = TubeRouter.shared

    var body: some View {
        TabView(selection: $router.selection) {
            SwiftUI.Tab("Home", systemImage: "house", value: TubeAppTab.home) { TubeHomeView() }
            SwiftUI.Tab("Following", systemImage: "person.2", value: TubeAppTab.following) { TubeFollowingView() }
            SwiftUI.Tab("Saved", systemImage: "bookmark", value: TubeAppTab.saved) { TubeSavedView() }
            SwiftUI.Tab("Settings", systemImage: "gearshape", value: TubeAppTab.settings) { TubeSettingsView() }
            SwiftUI.Tab(value: TubeAppTab.search, role: .search) { TubeSearchView() }
        }
        .modifier(TubeMinimizeTabBarOnScroll())
        .environmentObject(library)
        .environmentObject(engine)
        .environmentObject(router)
        .sheet(item: $router.pageSheet) { sheet in
            TubePageSheet(url: sheet.url)
        }
        .sheet(isPresented: $router.showSignIn) {
            TubeSignInView()
                .environmentObject(engine)
        }
        .task { applyLaunchArguments() }
    }

    /// Used by the CI simulator check: `-tab search|following|saved|settings`.
    private func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-tab"), index + 1 < args.count else { return }
        switch args[index + 1] {
        case "search": router.selection = .search
        case "following": router.selection = .following
        case "saved": router.selection = .saved
        case "settings": router.selection = .settings
        default: break
        }
    }
}

/// iOS 26: the tab bar shrinks to a small glass pill while you scroll down.
@available(iOS 18.0, *)
struct TubeMinimizeTabBarOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
extension View {
    /// Every tab can open videos, channels and YouTube playlists.
    func tubeDestinations() -> some View {
        navigationDestination(for: TubeVideo.self) { TubePlayerView(video: $0) }
            .navigationDestination(for: TubeChannel.self) { TubeChannelView(channel: $0) }
            .navigationDestination(for: TubePlaylist.self) { TubePlaylistView(playlist: $0) }
    }
}

/// Shown on systems older than iOS 18.
final class TubeUnsupportedViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "Flameferret needs iOS 18 or later."
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .headline)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }
}
