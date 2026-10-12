// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import WebKit

/// Shows an extension popup (toolbar button) or options page in a sheet.
@MainActor
final class WebExtensionPageViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    let webExtension: WebExtension
    let url: URL
    let isPopup: Bool
    private(set) var webView: WKWebView?
    private weak var manager: WebExtensionManager?

    init(webExtension: WebExtension, url: URL, isPopup: Bool, manager: WebExtensionManager) {
        self.webExtension = webExtension
        self.url = url
        self.isPopup = isPopup
        self.manager = manager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = webExtension.displayName
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done,
                                                            target: self,
                                                            action: #selector(close))
        guard let manager else { return }

        let configuration = manager.makeExtensionPageConfiguration(for: webExtension,
                                                                   isBackground: false,
                                                                   isPopup: isPopup)
        let webView = WKWebView(frame: view.bounds, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.webView = webView
        manager.registerExtensionPage(webView, uuid: webExtension.uuid)
        webView.load(URLRequest(url: url))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true, let webView else { return }
        manager?.unregisterExtensionPage(webView)
    }

    @objc
    private func close() {
        dismiss(animated: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if !isMainFrame || target.scheme == WebExtensionURLSchemeHandler.scheme
            || ["about", "blob", "data", "javascript"].contains(target.scheme ?? "") {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        openInTab(target)
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let target = navigationAction.request.url {
            openInTab(target)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        dismiss(animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor () -> Void) {
        let alert = UIAlertController(title: webExtension.displayName, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = UIAlertController(title: webExtension.displayName, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    private func openInTab(_ target: URL) {
        let manager = self.manager
        dismiss(animated: true) {
            _ = manager?.openTab(url: target, active: true, from: nil)
        }
    }
}
