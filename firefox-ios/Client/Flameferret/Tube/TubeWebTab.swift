// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import AVFoundation
import Common
import Shared
import SwiftUI
import UIKit
import WebKit

/// A Ferret browser tab used by the YouTube shell. It runs AdGuard and the bundled extensions
/// (SponsorBlock), keeps playing in the background and only stays on YouTube.
@MainActor
final class TubeWebTab: NSObject, ObservableObject, WKNavigationDelegate {
    enum Mode {
        /// Only the video player is shown; the rest of the YouTube page is hidden.
        case player
        /// A normal page (sign-in, comments, anything the native screens don't cover).
        case page
        /// YouTube's embed player (what DuckDuckGo's Duck Player uses): fills the view, letterboxed.
        case embed
    }

    static let windowUUID = WindowUUID()

    let tab: Tab
    let mode: Mode
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var pageTitle: String?

    /// Called when the page moves somewhere new (e.g. an end-screen video).
    var onNavigate: ((URL) -> Void)?

    private var observers: [NSKeyValueObservation] = []
    private var isClosed = false

    /// Whether the page may start the video by itself. Off while the native player looks for a stream.
    private let autoplay: Bool

    init(url: URL, mode: Mode, autoplay: Bool = true) {
        self.autoplay = autoplay
        let profile: Profile = AppContainer.shared.resolve()
        tab = Tab(profile: profile, windowUUID: TubeWebTab.windowUUID)
        self.mode = mode
        super.init()
        ShellTabRegistry.shared.register(tab)
        tab.navigationDelegate = self
        tab.createWebview(configuration: Self.makeConfiguration(autoplay: autoplay))
        if let webView = tab.webView {
            webView.customUserAgent = UserAgent.mobileUserAgent()
            webView.allowsBackForwardNavigationGestures = mode == .page
            webView.scrollView.layer.masksToBounds = true
            if mode != .page {
                webView.scrollView.isScrollEnabled = false
                webView.scrollView.contentInsetAdjustmentBehavior = .never
                webView.isOpaque = false
                webView.backgroundColor = .black
                webView.scrollView.backgroundColor = .black
            }
            installPageScripts(in: webView)
            observers.append(webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.urlDidChange(view.url) }
            })
            observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            })
            observers.append(webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.pageTitle = view.title }
            })
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(extensionsDidChange),
                                               name: .webExtensionsDidChange,
                                               object: nil)
        if mode == .embed, let webView = tab.webView {
            // The embed player refuses to load without an embedding page (YouTube's errors 152/153),
            // so it goes in an iframe on a small page, the way Google's iOS player helper does it.
            webView.loadHTMLString(Self.embedHTML(for: url), baseURL: URL(string: "https://www.youtube.com/"))
        } else {
            tab.loadRequest(URLRequest(url: url))
        }
    }

    var webView: WKWebView? { tab.webView }

    static func makeConfiguration(autoplay: Bool = true) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = autoplay ? [] : .all
        return configuration
    }

    func activate() {
        ShellTabRegistry.shared.setActive(tab)
    }

    func load(_ url: URL) {
        tab.loadRequest(URLRequest(url: url))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        observers.forEach { $0.invalidate() }
        observers = []
        NotificationCenter.default.removeObserver(self)
        ShellTabRegistry.shared.unregister(tab)
        let tab = tab
        Task { await tab.close() }
    }

    /// A snapshot of the player page's state, for diagnostics.
    func debugState() async -> String {
        let js = """
            const v = (() => { const f = document.getElementById('flameferret-embed'); try { return (f && f.contentDocument) || document; } catch (e) { return document; } })().querySelector('video');
            const p = document.querySelector('#player-container-id, .player-container');
            const r = p ? p.getBoundingClientRect() : null;
            return JSON.stringify({
              url: location.href, title: document.title, video: !!v,
              readyState: v ? v.readyState : -1, paused: v ? v.paused : null,
              currentTime: v ? v.currentTime : null, src: v ? (v.currentSrc || '').slice(0, 60) : null,
              player: r ? [r.x, r.y, r.width, r.height] : null,
              ad: !!document.querySelector('.ad-showing, .ad-interrupting'),
              sponsorBlock: !!document.querySelector('[id^="sponsorBlock"], .sponsorBlockCategory, #previewbar'),
              text: (document.body ? document.body.innerText : '').slice(0, 160)
            });
            """
        guard let webView else { return "no web view" }
        let result = try? await webView.callAsyncJavaScript(js, contentWorld: .page)
        return result as? String ?? "no result"
    }

    /// Whether YouTube's own page is shown instead of just the player.
    @Published private(set) var showsFullPage = false

    func setShowsFullPage(_ show: Bool) {
        showsFullPage = show
        webView?.scrollView.isScrollEnabled = show || mode == .page
        let js = show
            ? "window.__flameferretRawPage = true; const s = document.getElementById('flameferret-shell-css'); if (s) s.remove();"
            : "window.__flameferretRawPage = false; location.reload();"
        webView?.evaluateJavaScript(js, in: nil, in: .page)
    }

    struct PlaybackState: Equatable {
        var hasVideo: Bool
        var readyState: Int
        var paused: Bool
        var message: String?
    }

    /// The player's state, plus any message YouTube shows instead of the video (errors, sign-in walls).
    func playbackState() async -> PlaybackState? {
        let js = """
            const v = (() => { const f = document.getElementById('flameferret-embed'); try { return (f && f.contentDocument) || document; } catch (e) { return document; } })().querySelector('video');
            const doc = (() => { const f = document.getElementById('flameferret-embed'); try { return (f && f.contentDocument) || document; } catch (e) { return document; } })();
            const body = doc.body ? (doc.body.innerText || doc.body.textContent || '') : '';
            let message = '';
            for (const sel of ['.ytp-error', 'ytm-player-error-message-renderer', '.player-error-message-container']) {
              const e = doc.querySelector(sel);
              if (e && (e.textContent || '').trim()) { message = e.textContent.trim(); break; }
            }
            if (!message) {
              const walls = ['not a bot', 'Sign in to confirm', 'Video unavailable', 'This video is private',
                             'age-restricted', 'Something went wrong', 'An error occurred',
                             'Playback on other websites', 'Watch on YouTube', 'Watch this video on YouTube',
                             'Error 15'];
              for (const w of walls) {
                if (body.indexOf(w) >= 0) {
                  const lines = body.split(String.fromCharCode(10)).filter(l => l.indexOf(w) >= 0);
                  message = (lines[0] || w).trim();
                  break;
                }
              }
            }
            return [v ? 1 : 0, v ? v.readyState : 0, (!v || v.paused) ? 1 : 0, message.slice(0, 200)];
            """
        guard let webView else { return nil }
        do {
            let result = try await webView.callAsyncJavaScript(js, contentWorld: .page)
            guard let values = result as? [Any], values.count == 4 else {
                TubeEngine.log("playback: unexpected \(String(describing: result))")
                return nil
            }
            let number = { (value: Any) -> Int in (value as? NSNumber)?.intValue ?? 0 }
            let message = values[3] as? String ?? ""
            let state = PlaybackState(hasVideo: number(values[0]) == 1, readyState: number(values[1]),
                                      paused: number(values[2]) == 1, message: message.isEmpty ? nil : message)
            TubeEngine.log("playback: \(state)")
            return state
        } catch {
            TubeEngine.log("playback: failed \(error.localizedDescription)")
            return nil
        }
    }

    struct PageStream: Sendable {
        let url: URL
        let userAgent: String
    }

    /// The HLS stream the YouTube page itself was given for `videoID`, if it got one. The page's
    /// request passes YouTube's checks (sign-in, bot checks), so Apple's player can play its stream.
    func pageStream(videoID: String) async -> PageStream? {
        let js = """
            let r = null;
            try {
              const p = document.querySelector('#movie_player');
              if (p && typeof p.getPlayerResponse === 'function') { r = p.getPlayerResponse(); }
            } catch (e) {}
            if (!r || !r.videoDetails || r.videoDetails.videoId !== videoID) { r = window.ytInitialPlayerResponse || r; }
            if (!r || !r.videoDetails || r.videoDetails.videoId !== videoID) { return null; }
            const status = r.playabilityStatus ? r.playabilityStatus.status : '';
            const hls = r.streamingData ? r.streamingData.hlsManifestUrl : null;
            return [status || '', hls || '', navigator.userAgent];
            """
        guard let webView,
              let values = try? await webView.callAsyncJavaScript(js, arguments: ["videoID": videoID],
                                                                   contentWorld: .page) as? [Any],
              values.count == 3, let hls = values[1] as? String, !hls.isEmpty, let url = URL(string: hls) else {
            return nil
        }
        return PageStream(url: url, userAgent: values[2] as? String ?? "")
    }

    /// Starts Picture in Picture if the video is playing (used when leaving the app).
    func enterPictureInPictureIfPlaying() {
        let js = """
            const v = (() => { const f = document.getElementById('flameferret-embed'); try { return (f && f.contentDocument) || document; } catch (e) { return document; } })().querySelector('video');
            if (v && !v.paused && v.webkitSupportsPresentationMode
                && v.webkitSupportsPresentationMode('picture-in-picture')) {
              v.webkitSetPresentationMode('picture-in-picture');
            }
            """
        webView?.evaluateJavaScript(js, in: nil, in: .page)
    }

    /// Asks the page to start the video (YouTube sometimes waits for a tap).
    func play() {
        webView?.evaluateJavaScript("const v = (() => { const f = document.getElementById('flameferret-embed'); try { return (f && f.contentDocument) || document; } catch (e) { return document; } })().querySelector('video'); if (v && v.paused) { v.play().catch(() => {}); }",
                                    in: nil, in: .page)
    }

    func reload() {
        webView?.reload()
    }

    func pause() {
        webView?.evaluateJavaScript("(() => { const f = document.getElementById('flameferret-embed'); try { return (f && f.contentDocument) || document; } catch (e) { return document; } })().querySelectorAll('video').forEach(v => v.pause());", in: nil, in: .page)
    }

    /// Starts Picture in Picture on the playing video.
    func startPictureInPicture() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let js = """
            const v = (() => { const f = document.getElementById('flameferret-embed'); try { return (f && f.contentDocument) || document; } catch (e) { return document; } })().querySelector('video');
            if (v) {
                if (v.paused) { v.play(); }
                if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
                    v.webkitSetPresentationMode('picture-in-picture');
                } else if (v.requestPictureInPicture) {
                    v.requestPictureInPicture();
                }
            }
            """
        webView?.evaluateJavaScript(js, in: nil, in: .page)
    }

    // MARK: Page scripts

    @objc
    private func extensionsDidChange() {
        // Extension changes reinstall the tab's user scripts, which drops ours.
        if let webView { installPageScripts(in: webView) }
    }

    /// AdGuard reinstalls the tab's user scripts when a page's rules change, which drops ours.
    private func ensurePageScripts(in webView: WKWebView) {
        let scripts = webView.configuration.userContentController.userScripts
        if !scripts.contains(where: { $0.source.contains("flameferret-shell-css") }) {
            installPageScripts(in: webView)
        }
    }

    private func installPageScripts(in webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.chromeHidingJS(for: mode),
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: mode != .embed,
                                              in: .page))
    }

    private static func chromeHidingJS(for mode: Mode) -> String {
        let css: String
        switch mode {
        case .player: css = playerCSS
        case .page: css = pageCSS
        case .embed: css = embedCSS
        }
        let escaped = css.replacingOccurrences(of: "`", with: "\\`")
        return """
            (() => {
              if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) { return; }
              const apply = () => {
                if (window.__flameferretRawPage || document.getElementById('flameferret-shell-css')) { return; }
                const style = document.createElement('style');
                style.id = 'flameferret-shell-css';
                style.textContent = `\(escaped)`;
                (document.head || document.documentElement).appendChild(style);
              };
              apply();
              document.addEventListener('DOMContentLoaded', apply);
              new MutationObserver(apply).observe(document.documentElement, { childList: true });
            })();
            """
    }

    /// Hides YouTube's own top bar, bottom tabs and promos so the shell's native screens frame the page.
    private static let pageCSS = """
        ytm-mobile-topbar-renderer, #header-bar, ytm-pivot-bar-renderer, .pivot-bar-renderer,
        ytm-app-promo-renderer, ytm-mealbar-promo-renderer, .mealbar-promo-renderer, ytm-promoted-sparkles-web-renderer,
        ytm-statement-banner-renderer, ytm-companion-slot, ytm-promoted-video-renderer, .open-app-button,
        ytm-paid-content-overlay-renderer { display: none !important; }
        body, #app, .page-container, .mobile-topbar-header-content { padding-top: 0 !important; margin-top: 0 !important; }
        :root { --ytm-header-height: 0px !important; --ytm-pivot-bar-height: 0px !important; }
        """

    private static func embedHTML(for url: URL) -> String {
        let source = url.absoluteString.replacingOccurrences(of: "\"", with: "&quot;")
        return """
            <!doctype html><html><head>
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
            <style>html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
            iframe { position: fixed; inset: 0; width: 100%; height: 100%; border: 0; }</style>
            </head><body>
            <iframe id="flameferret-embed" src="\(source)" referrerpolicy="strict-origin-when-cross-origin"
              allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
            </body></html>
            """
    }

    /// The embed player already fills the page; only its title bar and "more videos" overlay go.
    private static let embedCSS = """
        html, body { background: #000 !important; }
        .ytp-chrome-top, .ytp-pause-overlay, .ytp-show-cards-title, .ytp-watermark,
        .ytp-youtube-button, .ytp-impression-link { display: none !important; }
        """

    /// Shows only the video player. YouTube's own layout puts the player at the top of the page at
    /// 16:9 of its width, which matches the web view, so nothing is repositioned; the page just can't scroll.
    private static let playerCSS = pageCSS + """
        html, body { background: #000 !important; overflow: hidden !important; }
        .watch-below-the-player, ytm-single-column-watch-next-results-renderer, ytm-item-section-renderer,
        ytm-engagement-panel-section-list-renderer { visibility: hidden !important; }
        #player-control-container, ytm-custom-control, .player-controls-background {
          background: transparent !important;
        }
        #movie_player, .html5-video-player, .html5-video-container {
          width: 100% !important; height: 100% !important; left: 0 !important; top: 0 !important;
        }
        video.video-stream, .html5-main-video {
          width: 100% !important; height: 100% !important; left: 0 !important; top: 0 !important;
          object-fit: contain !important;
        }
        """

    // MARK: Navigation

    private func urlDidChange(_ url: URL?) {
        currentURL = url
        guard let url else { return }
        onNavigate?(url)
        WebExtensionManager.shared.tabDidNavigate(tab, finished: false)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if TubeLinks.isInternal(url) {
            if navigationAction.targetFrame?.isMainFrame != false {
                AdGuardManager.shared.prepareMainFrameNavigation(to: url, in: tab)
                ensurePageScripts(in: webView)
            }
            decisionHandler(.allow)
            return
        }
        // Anything off YouTube opens outside the app.
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame?.isMainFrame != false {
            if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) {
                UIApplication.shared.open(url)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        WebExtensionManager.shared.tabDidNavigate(tab, finished: true)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

/// Hosts a `TubeWebTab`'s web view in SwiftUI.
struct TubeWebTabView: UIViewRepresentable {
    @ObservedObject var webTab: TubeWebTab

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = webTab.mode == .page ? .systemBackground : .black
        attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attach(to: uiView)
    }

    private func attach(to container: UIView) {
        guard let webView = webTab.webView, webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
