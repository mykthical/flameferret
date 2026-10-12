// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import WebKit

/// Runs an extension's background page (MV2 scripts/page or MV3 service worker) in a hidden web view.
@MainActor
final class WebExtensionBackgroundHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webExtension: WebExtension
    private(set) var webView: WKWebView?
    private weak var manager: WebExtensionManager?
    private var installReason: String?
    private var hasFinishedFirstLoad = false

    init(webExtension: WebExtension, manager: WebExtensionManager) {
        self.webExtension = webExtension
        self.manager = manager
    }

    func start(installReason: String?) {
        guard let manager, webView == nil else { return }
        self.installReason = installReason
        let configuration = manager.makeExtensionPageConfiguration(for: webExtension, isBackground: true, isPopup: false)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        let path = webExtension.manifest.background?.page ?? WebExtensionURLSchemeHandler.generatedBackgroundPage
        webView.load(URLRequest(url: webExtension.url(for: path)))
    }

    func stop() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard !hasFinishedFirstLoad, let manager else { return }
        hasFinishedFirstLoad = true
        if let reason = installReason {
            manager.dispatch("event",
                             payload: ["name": "runtime.onInstalled", "args": [["reason": reason, "temporary": false]]],
                             to: webView,
                             world: .page) { _ in }
        } else {
            manager.dispatch("event", payload: ["name": "runtime.onStartup", "args": []], to: webView, world: .page) { _ in }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme == WebExtensionURLSchemeHandler.scheme || url.scheme == "about" || url.scheme == "blob"
            || url.scheme == "data" || navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        // A background page never navigates away; open anything else in a tab instead.
        _ = manager?.openTab(url: url, active: true, from: nil)
        decisionHandler(.cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hasFinishedFirstLoad = true
        webView.reload()
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            _ = manager?.openTab(url: url, active: true, from: nil)
        }
        return nil
    }
}
