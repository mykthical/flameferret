// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Foundation
import JavaScriptCore
import WebKit
import class FilterEngine.WebExtension

extension Notification.Name {
    static let adGuardStateDidChange = Notification.Name("FlameferretAdGuardStateDidChange")
}

/// What AdGuard applies to one page: cosmetic rules for the isolated world and code for the page world.
struct AdGuardPageRules: Equatable {
    let css: [String]
    let extendedCss: [String]
    let pageCode: String

    var isEmpty: Bool { css.isEmpty && extendedCss.isEmpty && pageCode.isEmpty }

    var cosmeticsJSON: [String: Any] { ["css": css, "extendedCss": extendedCss] }
}

/// Flameferret's built-in AdGuard ad blocker.
///
/// Network and basic element-hiding rules run as WebKit content blockers. Scriptlets, script
/// rules and Extended CSS are looked up per page with AdGuard's FilterEngine. Main-frame rules
/// are installed as user scripts before the page starts loading, so scriptlets run ahead of the
/// site's own code; frame rules are looked up when each frame starts.
@MainActor
final class AdGuardManager: NSObject {
    static let shared = AdGuardManager()
    static let messageHandlerName = "flameferretAdguard"
    static let contentWorld = WKContentWorld.world(name: "flameferret-adguard")
    static let updateInterval: TimeInterval = 24 * 60 * 60

    let store: AdGuardStore
    private(set) var settings: AdGuardSettings
    private(set) var compiledState: AdGuardCompiledState?
    private(set) var isUpdating = false

    private var ruleLists: [WKContentRuleList] = []
    private var lookupEngine: FilterEngine.WebExtension?
    private var pageRules: [ObjectIdentifier: AdGuardPageRules] = [:]
    private var scriptletCodeCache: [String: String] = [:]
    private var hasStarted = false
    private lazy var messageHandler = AdGuardMessageHandler(manager: self)
    private lazy var ruleListStore: WKContentRuleListStore? = WKContentRuleListStore(url: store.ruleListsDirectory)
    private lazy var scriptletContext: JSContext? = {
        let context: JSContext? = JSContext()
        context?.evaluateScript(AdGuardJSSource.scriptlets)
        return context
    }()
    private let logger: Logger

    init(store: AdGuardStore = AdGuardStore(), logger: Logger = DefaultLogger.shared) {
        self.store = store
        self.settings = store.loadSettings()
        self.compiledState = store.loadCompiledState()
        self.logger = logger
        super.init()
    }

    var isActive: Bool { settings.isEnabled && compiledState != nil }

    // MARK: - Lifecycle

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        guard settings.isEnabled else { return }

        if let compiledState {
            restoreCompiledLists(compiledState)
            lookupEngine = try? FilterEngine.WebExtension(containerURL: store.engineDirectory)
        }
        let isStale = settings.lastUpdated.map { Date().timeIntervalSince($0) > AdGuardManager.updateInterval } ?? true
        if compiledState == nil || isStale {
            Task { await updateFilters(downloading: true) }
        }
    }

    func updateSettings(recompile: Bool, _ change: (inout AdGuardSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        let wasEnabled = settings.isEnabled
        settings = updated
        store.saveSettings(updated)

        if !updated.isEnabled {
            removeRuleListsEverywhere()
            pageRules.removeAll()
            refreshAllTabs()
        } else if !wasEnabled {
            hasStarted = false
            startIfNeeded()
            refreshAllTabs()
        } else if recompile {
            Task { await updateFilters(downloading: false) }
        }
        notifyChanged()
    }

    /// Downloads enabled filter lists (when asked), recompiles everything and applies it to every tab.
    func updateFilters(downloading: Bool) async {
        guard settings.isEnabled, !isUpdating else { return }
        isUpdating = true
        notifyChanged()
        defer {
            isUpdating = false
            notifyChanged()
        }

        let filters = settings.enabledFilters
        var downloadError: String?
        if downloading {
            downloadError = await download(filters)
        }

        let store = self.store
        let filterTexts = filters.compactMap { filter in
            store.cachedFilterText(for: filter).map { (filter.group, $0) }
        }
        let userRules = AdGuardRuleBuilder.userRuleLines(settings.userRules)
        let allowlistRules = AdGuardRuleBuilder.allowlistRules(settings.allowlist)

        let result: Result<AdGuardCompiler.Output, Error> = await Task.detached(priority: .utility) {
            let output = AdGuardCompiler.compile(filterTexts: filterTexts,
                                                 userRules: userRules,
                                                 allowlistRules: allowlistRules)
            do {
                try AdGuardCompiler.buildEngine(rules: output.advancedRules, directory: store.engineDirectory)
                return .success(output)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let output):
            let lists = await compileRuleLists(output.groups)
            installRuleLists(lists)
            lookupEngine = try? FilterEngine.WebExtension(containerURL: store.engineDirectory)
            let state = AdGuardCompiledState(ruleListIDs: output.groups.map { $0.id },
                                             safariRuleCount: output.groups.reduce(0) { $0 + $1.ruleCount },
                                             advancedRuleCount: output.advancedRuleCount,
                                             skippedRuleCount: output.skippedRuleCount,
                                             compiledAt: Date())
            compiledState = state
            store.saveCompiledState(state)
            settings.lastUpdated = downloading ? Date() : settings.lastUpdated
            settings.lastUpdateError = downloadError
            store.saveSettings(settings)
            pageRules.removeAll()
            refreshAllTabs()
        case .failure(let error):
            settings.lastUpdateError = error.localizedDescription
            store.saveSettings(settings)
            logger.log("AdGuard engine build failed: \(error)", level: .warning, category: .adblock)
        }
    }

    private func download(_ filters: [AdGuardFilter]) async -> String? {
        let store = self.store
        var failures: [String] = []
        await withTaskGroup(of: (AdGuardFilter, Data?).self) { group in
            for filter in filters {
                group.addTask {
                    var request = URLRequest(url: filter.url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.timeoutInterval = 60
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                          !data.isEmpty else {
                        return (filter, nil)
                    }
                    return (filter, data)
                }
            }
            for await (filter, data) in group {
                if let data {
                    store.saveFilterText(data, for: filter)
                } else if store.cachedFilterText(for: filter) == nil {
                    failures.append(filter.name)
                } else {
                    failures.append(filter.name + " (using the saved copy)")
                }
            }
        }
        return failures.isEmpty ? nil : "Couldn't download: " + failures.sorted().joined(separator: ", ")
    }

    // MARK: - Content rule lists

    private func compileRuleLists(_ groups: [AdGuardCompiler.Group]) async -> [WKContentRuleList] {
        guard let ruleListStore else { return [] }
        var lists: [WKContentRuleList] = []
        for group in groups {
            let list: WKContentRuleList? = await withCheckedContinuation { continuation in
                ruleListStore.compileContentRuleList(forIdentifier: group.id,
                                                     encodedContentRuleList: group.json) { list, error in
                    if let error {
                        self.logger.log("AdGuard \(group.id) failed to compile: \(error.localizedDescription)",
                                        level: .warning, category: .adblock)
                    }
                    continuation.resume(returning: list)
                }
            }
            if let list { lists.append(list) }
        }
        return lists
    }

    private func restoreCompiledLists(_ state: AdGuardCompiledState) {
        guard let ruleListStore else { return }
        Task {
            var lists: [WKContentRuleList] = []
            for id in state.ruleListIDs {
                let list: WKContentRuleList? = await withCheckedContinuation { continuation in
                    ruleListStore.lookUpContentRuleList(forIdentifier: id) { list, _ in
                        continuation.resume(returning: list)
                    }
                }
                if let list { lists.append(list) }
            }
            if lists.count < state.ruleListIDs.count {
                await updateFilters(downloading: false)
            } else {
                installRuleLists(lists)
            }
        }
    }

    private func installRuleLists(_ lists: [WKContentRuleList]) {
        removeRuleListsEverywhere()
        ruleLists = settings.isEnabled ? lists : []
        for tab in WebExtensionManager.shared.allTabs() {
            reapplyRuleLists(to: tab.webView)
        }
    }

    private func removeRuleListsEverywhere() {
        for tab in WebExtensionManager.shared.allTabs() {
            for list in ruleLists {
                tab.webView?.configuration.userContentController.remove(list)
            }
        }
        ruleLists = []
    }

    /// Re-adds AdGuard's content blockers after the browser resets a tab's rule lists.
    func reapplyRuleLists(to webView: WKWebView?) {
        guard let controller = webView?.configuration.userContentController, settings.isEnabled else { return }
        for list in ruleLists {
            controller.remove(list)
            controller.add(list)
        }
    }

    // MARK: - Page rules

    /// Called before a main-frame navigation starts so its scriptlets can be installed ahead of the page.
    func prepareMainFrameNavigation(to url: URL, in tab: Tab) {
        guard let webView = tab.webView else { return }
        let key = ObjectIdentifier(webView)
        let rules = rulesForPage(url, topURL: nil)
        if pageRules[key] == rules { return }
        pageRules[key] = rules
        tab.reinjectUserScripts()
    }

    func webViewWillClose(_ webView: WKWebView) {
        pageRules[ObjectIdentifier(webView)] = nil
    }

    func rulesForPage(_ url: URL, topURL: URL?) -> AdGuardPageRules? {
        guard isActive, let scheme = url.scheme, ["http", "https"].contains(scheme),
              !AdGuardRuleBuilder.isAllowlisted(url, hosts: settings.allowlist),
              !(topURL.map { AdGuardRuleBuilder.isAllowlisted($0, hosts: settings.allowlist) } ?? false),
              let configuration = lookupEngine?.lookup(pageUrl: url, topUrl: topURL) else {
            return nil
        }
        var pieces: [String] = []
        for scriptlet in configuration.scriptlets {
            let code = scriptletCode(name: scriptlet.name, args: scriptlet.args)
            if !code.isEmpty { pieces.append(code) }
        }
        pieces.append(contentsOf: configuration.js)
        let pageCode = pieces.map { "try {\n\($0)\n} catch (e) {}" }.joined(separator: "\n")
        let rules = AdGuardPageRules(css: configuration.css,
                                     extendedCss: configuration.extendedCss,
                                     pageCode: pageCode.isEmpty ? "" : "(function() {\n\(pageCode)\n})();")
        return rules.isEmpty ? nil : rules
    }

    private func scriptletCode(name: String, args: [String]) -> String {
        let key = ([name] + args).joined(separator: "\u{1F}")
        if let cached = scriptletCodeCache[key] { return cached }
        let function = scriptletContext?.objectForKeyedSubscript("__flameferretScriptletCode")
        let code = function?.call(withArguments: [name, args])?.toString() ?? ""
        let result = code == "undefined" ? "" : code
        if scriptletCodeCache.count > 2000 { scriptletCodeCache.removeAll() }
        scriptletCodeCache[key] = result
        return result
    }

    // MARK: - Injection

    /// Installs AdGuard into a tab's web view. Called whenever the tab's user scripts are rebuilt.
    func inject(into webView: WKWebView?) {
        guard let webView else { return }
        startIfNeeded()
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: AdGuardManager.messageHandlerName,
                                              contentWorld: AdGuardManager.contentWorld)
        guard settings.isEnabled else { return }
        reapplyRuleLists(to: webView)
        guard isActive else { return }

        controller.addScriptMessageHandler(messageHandler,
                                           contentWorld: AdGuardManager.contentWorld,
                                           name: AdGuardManager.messageHandlerName)
        controller.addUserScript(WKUserScript(source: AdGuardJSSource.content,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false,
                                              in: AdGuardManager.contentWorld))

        guard let rules = pageRules[ObjectIdentifier(webView)] else { return }
        if !rules.pageCode.isEmpty {
            controller.addUserScript(WKUserScript(source: rules.pageCode,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true,
                                                  in: .page))
        }
        if !rules.css.isEmpty || !rules.extendedCss.isEmpty {
            let json = WebExtensionManager.jsonString(rules.cosmeticsJSON)
            let source = "globalThis.__flameferretAdguard && globalThis.__flameferretAdguard.applyCosmetics(\(json));"
            controller.addUserScript(WKUserScript(source: source,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true,
                                                  in: AdGuardManager.contentWorld))
        }
    }

    /// A frame asked for its rules: reply with cosmetics and run its scriptlets in the frame's page world.
    func handleLookup(_ message: WKScriptMessage, reply: @escaping @MainActor (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "lookup",
              let webView = message.webView else {
            reply(nil, nil)
            return
        }
        let topURL = webView.url
        var frameURL = (body["url"] as? String).flatMap(URL.init(string:)) ?? message.frameInfo.request.url
        if let url = frameURL, !["http", "https"].contains(url.scheme ?? "") {
            frameURL = topURL
        }
        guard let url = frameURL, let rules = rulesForPage(url, topURL: topURL) else {
            reply(nil, nil)
            return
        }
        if !rules.pageCode.isEmpty {
            webView.evaluateJavaScript(rules.pageCode, in: message.frameInfo, in: .page) { _ in }
        }
        reply(rules.cosmeticsJSON, nil)
    }

    // MARK: - Helpers

    func allowlistContains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return AdGuardRuleBuilder.isAllowlisted(url, hosts: settings.allowlist)
    }

    func setAllowlisted(_ allowlisted: Bool, host: String) {
        updateSettings(recompile: true) { settings in
            settings.allowlist.removeAll { $0 == host }
            if allowlisted { settings.allowlist.append(host) }
            settings.allowlist.sort()
        }
    }

    private func refreshAllTabs() {
        for tab in WebExtensionManager.shared.allTabs() {
            tab.reinjectUserScripts()
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .adGuardStateDidChange, object: nil)
    }
}

/// Breaks the retain cycle between WKUserContentController and the manager.
final class AdGuardMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var manager: AdGuardManager?

    init(manager: AdGuardManager) {
        self.manager = manager
    }

    @MainActor
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let manager else {
            replyHandler(nil, nil)
            return
        }
        manager.handleLookup(message, reply: replyHandler)
    }
}
