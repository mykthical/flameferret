// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation
import WebKit

enum TubeError: LocalizedError {
    case notReady(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notReady(let why): return why
        case .badResponse(let why): return why
        }
    }
}

/// Talks to YouTube from inside a hidden web view on youtube.com, so requests carry the same
/// sign-in cookies as the player and nothing else in the app needs access to them.
@MainActor
final class TubeEngine: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = TubeEngine()

    enum State: Equatable {
        case idle, loading, ready, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isSignedIn = false
    /// Bumped whenever the sign-in state may have changed, so feeds can reload.
    @Published private(set) var sessionGeneration = 0

    private var webView: WKWebView?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var usesFallbackContext = false

    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    func start() {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.customUserAgent = Self.desktopUserAgent
        view.navigationDelegate = self
        webView = view
        load()
    }

    /// Reloads the hidden page, picking up a new sign-in state.
    func reload() {
        guard webView != nil else {
            start()
            return
        }
        load()
    }

    private func load() {
        state = .loading
        usesFallbackContext = false
        webView?.load(URLRequest(url: URL(string: "https://www.youtube.com/feed/you")!))
    }

    func waitUntilReady() async throws {
        if webView == nil { start() }
        switch state {
        case .ready: return
        case .failed(let why): throw TubeError.notReady(why)
        default: break
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters.append(continuation)
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        switch result {
        case .success: state = .ready
        case .failure(let error): state = .failed(error.localizedDescription)
        }
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(with: result) }
    }

    // MARK: InnerTube

    /// POSTs to `/youtubei/v1/<endpoint>` with the page's own client context and sign-in.
    func call(_ endpoint: String, _ payload: [String: Any]) async throws -> [String: Any] {
        try await waitUntilReady()
        guard let webView else { throw TubeError.notReady("YouTube isn't loaded") }
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
        let result = try await webView.callAsyncJavaScript(Self.innertubeJS,
                                                           arguments: ["endpoint": endpoint,
                                                                       "payloadJSON": payloadJSON],
                                                           contentWorld: .page)
        guard let text = result as? String, let data = text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TubeError.badResponse("YouTube sent something unexpected")
        }
        if let error = json["error"] as? [String: Any] {
            throw TubeError.badResponse(error["message"] as? String ?? "YouTube returned an error")
        }
        if let loggedIn = TubeParser.isLoggedIn(json), loggedIn != isSignedIn {
            isSignedIn = loggedIn
        }
        return json
    }

    func browse(_ browseID: String, params: String? = nil) async throws -> [String: Any] {
        var payload: [String: Any] = ["browseId": browseID]
        if let params { payload["params"] = params }
        return try await call("browse", payload)
    }

    func continuation(_ endpoint: String, token: String) async throws -> [String: Any] {
        return try await call(endpoint, ["continuation": token])
    }

    // MARK: Session

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let google = records.filter { record in
            let name = record.displayName.lowercased()
            return name.contains("youtube") || name.contains("google")
        }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: google)
        isSignedIn = false
        sessionGeneration += 1
        reload()
    }

    func didSignIn() {
        sessionGeneration += 1
        reload()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await inspectLoadedPage(webView) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func inspectLoadedPage(_ webView: WKWebView) async {
        let host = webView.url?.host?.lowercased() ?? ""
        let probe = try? await webView.callAsyncJavaScript(Self.probeJS, contentWorld: .page) as? [String: Any]
        if let probe, probe["ready"] as? Bool == true, host.hasSuffix("youtube.com") {
            isSignedIn = probe["loggedIn"] as? Bool ?? false
            finish(.success(()))
            return
        }
        // Consent screens (EU) and blocked pages have no client config: fall back to a plain
        // same-origin page and a built-in signed-out context.
        if !usesFallbackContext {
            usesFallbackContext = true
            webView.load(URLRequest(url: URL(string: "https://www.youtube.com/robots.txt")!))
            return
        }
        isSignedIn = false
        finish(.success(()))
    }

    private static let probeJS = """
        const cfg = window.ytcfg && typeof ytcfg.get === 'function' ? ytcfg : null;
        return { ready: !!(cfg && cfg.get('INNERTUBE_CONTEXT')), loggedIn: !!(cfg && cfg.get('LOGGED_IN')) };
        """

    private static let innertubeJS = """
        const cfg = window.ytcfg && typeof ytcfg.get === 'function' ? ytcfg : null;
        const lang = (navigator.language || 'en-US').split('-');
        const context = (cfg && cfg.get('INNERTUBE_CONTEXT')) || {
            client: { clientName: 'WEB', clientVersion: '2.20261008.01.00', hl: lang[0] || 'en', gl: lang[1] || 'US' }
        };
        const clientVersion = (context.client && context.client.clientVersion) || '2.20261008.01.00';
        const headers = {
            'Content-Type': 'application/json',
            'X-Youtube-Client-Name': '1',
            'X-Youtube-Client-Version': clientVersion,
            'X-Origin': location.origin,
            'X-Goog-AuthUser': String((cfg && cfg.get('SESSION_INDEX')) || 0)
        };
        if (cfg && cfg.get('DELEGATED_SESSION_ID')) {
            headers['X-Goog-PageId'] = cfg.get('DELEGATED_SESSION_ID');
        }
        const cookie = name => {
            const m = document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]+)'));
            return m ? m[1] : null;
        };
        const hash = async value => {
            const ts = Math.floor(Date.now() / 1000);
            const digest = await crypto.subtle.digest('SHA-1',
                new TextEncoder().encode(ts + ' ' + value + ' ' + location.origin));
            const hex = Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
            return ts + '_' + hex;
        };
        const parts = [];
        const sapisid = cookie('SAPISID') || cookie('__Secure-3PAPISID');
        if (sapisid) { parts.push('SAPISIDHASH ' + await hash(sapisid)); }
        const p1 = cookie('__Secure-1PAPISID');
        if (p1) { parts.push('SAPISID1PHASH ' + await hash(p1)); }
        const p3 = cookie('__Secure-3PAPISID');
        if (p3) { parts.push('SAPISID3PHASH ' + await hash(p3)); }
        if (parts.length) { headers['Authorization'] = parts.join(' '); }
        const body = Object.assign({ context: context }, JSON.parse(payloadJSON));
        const response = await fetch('/youtubei/v1/' + endpoint + '?prettyPrint=false', {
            method: 'POST', credentials: 'include', headers: headers, body: JSON.stringify(body)
        });
        return await response.text();
        """
}
