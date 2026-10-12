// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import UIKit
import WebKit

extension Notification.Name {
    static let webExtensionsDidChange = Notification.Name("FlameferretWebExtensionsDidChange")
}

/// Where a call into the extension API came from.
struct WebExtensionCallContext {
    let webExtension: WebExtension
    weak var webView: WKWebView?
    let world: WKContentWorld
    let isContentScript: Bool
    let isMainFrame: Bool
    let frameURL: URL?
}

/// Runtime state an extension can change through `browser.action`.
struct WebExtensionActionState {
    var badgeText = ""
    var badgeBackgroundColor: [Int] = [217, 0, 0, 255]
    var title: String?
    var popup: String?
    var enabled = true
}

/// Owns installed extensions and connects them to every tab, background page and popup.
@MainActor
final class WebExtensionManager: NSObject {
    static let shared = WebExtensionManager()
    static let messageHandlerName = "flameferretExt"

    let store: WebExtensionStore
    private(set) var extensions: [WebExtension] = []
    private(set) lazy var schemeHandler = WebExtensionURLSchemeHandler { [weak self] host in
        self?.extensions.first { $0.uuid == host && $0.isEnabled }
    }

    var backgroundHosts: [String: WebExtensionBackgroundHost] = [:]
    var extensionPageWebViews: [String: [WeakWebViewBox]] = [:]
    var actionStates: [String: WebExtensionActionState] = [:]
    var sessionStorage: [String: [String: Any]] = [:]
    var ports: [String: WebExtensionPort] = [:]
    var registeredContentScripts: [String: [[String: Any]]] = [:]
    var sessionDNRRules: [String: [[String: Any]]] = [:]
    private var tabIDs: [String: Int] = [:]
    private var nextTabID = 1
    private var compiledRuleLists: [String: [WKContentRuleList]] = [:]
    private var ruleGeneration: [String: Int] = [:]
    private var pendingInstallReasons: [String: String] = [:]
    private lazy var messageHandler = WebExtensionMessageHandlerProxy(manager: self)
    private lazy var ruleListStore: WKContentRuleListStore? = {
        let url = store.rootDirectory.appendingPathComponent("CompiledRules", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return WKContentRuleListStore(url: url)
    }()
    private var hasStarted = false

    let logger: Logger

    init(store: WebExtensionStore = WebExtensionStore(), logger: Logger = DefaultLogger.shared) {
        self.store = store
        self.logger = logger
        super.init()
    }

    var enabledExtensions: [WebExtension] { extensions.filter { $0.isEnabled } }

    func extensionWith(uuid: String) -> WebExtension? {
        return extensions.first { $0.uuid == uuid }
    }

    // MARK: - Lifecycle

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        extensions = store.loadExtensions()
        for webExtension in extensions {
            registeredContentScripts[webExtension.uuid] = loadRegisteredScripts(for: webExtension)
        }
        for webExtension in enabledExtensions {
            compileRuleLists(for: webExtension)
            startBackground(for: webExtension, reason: nil)
        }
    }

    func install(packageData: Data, suggestedName: String?) throws -> WebExtension {
        startIfNeeded()
        let installed = try store.install(packageData: packageData, suggestedName: suggestedName)
        let wasInstalled = extensions.contains { $0.uuid == installed.uuid }
        stopBackground(uuid: installed.uuid)
        extensions.removeAll { $0.uuid == installed.uuid }
        extensions.append(installed)
        registeredContentScripts[installed.uuid] = loadRegisteredScripts(for: installed)
        if installed.isEnabled {
            compileRuleLists(for: installed)
            startBackground(for: installed, reason: wasInstalled ? "update" : "install")
        }
        refreshAllWebViews()
        return installed
    }

    func uninstall(_ webExtension: WebExtension) {
        stopBackground(uuid: webExtension.uuid)
        removeRuleLists(uuid: webExtension.uuid)
        extensions.removeAll { $0.uuid == webExtension.uuid }
        actionStates[webExtension.uuid] = nil
        sessionStorage = sessionStorage.filter { !$0.key.hasPrefix(webExtension.uuid) }
        registeredContentScripts[webExtension.uuid] = nil
        store.uninstall(uuid: webExtension.uuid)
        refreshAllWebViews()
    }

    func setEnabled(_ enabled: Bool, for webExtension: WebExtension) {
        webExtension.isEnabled = enabled
        store.setEnabled(enabled, uuid: webExtension.uuid)
        if enabled {
            compileRuleLists(for: webExtension)
            startBackground(for: webExtension, reason: nil)
        } else {
            stopBackground(uuid: webExtension.uuid)
            removeRuleLists(uuid: webExtension.uuid)
        }
        refreshAllWebViews()
    }

    private func startBackground(for webExtension: WebExtension, reason: String?) {
        guard webExtension.hasBackground, backgroundHosts[webExtension.uuid] == nil else { return }
        let host = WebExtensionBackgroundHost(webExtension: webExtension, manager: self)
        backgroundHosts[webExtension.uuid] = host
        host.start(installReason: reason)
    }

    private func stopBackground(uuid: String) {
        backgroundHosts[uuid]?.stop()
        backgroundHosts[uuid] = nil
        for (portID, port) in ports where port.extensionUUID == uuid {
            ports[portID] = nil
        }
    }

    /// Re-runs user script injection for every open tab so script changes take effect on next load.
    func refreshAllWebViews() {
        for tab in allTabs() {
            tab.reinjectUserScripts()
        }
        NotificationCenter.default.post(name: .webExtensionsDidChange, object: nil)
    }

    // MARK: - Tabs

    func allTabManagers() -> [TabManager] {
        let windowManager: WindowManager = AppContainer.shared.resolve()
        return windowManager.allWindowTabManagers()
    }

    func allTabs() -> [Tab] {
        return allTabManagers().flatMap { $0.tabs }
    }

    func tabID(for tab: Tab) -> Int {
        if let existing = tabIDs[tab.tabUUID] { return existing }
        let newID = nextTabID
        nextTabID += 1
        tabIDs[tab.tabUUID] = newID
        return newID
    }

    func tab(withID id: Int) -> Tab? {
        guard let uuid = tabIDs.first(where: { $0.value == id })?.key else { return nil }
        return allTabs().first { $0.tabUUID == uuid }
    }

    func tab(for webView: WKWebView?) -> Tab? {
        guard let webView else { return nil }
        return allTabs().first { $0.webView === webView }
    }

    func selectedTab() -> Tab? {
        return allTabManagers().first?.selectedTab
    }

    func windowID(for tab: Tab) -> Int {
        let managers = allTabManagers()
        let index = managers.firstIndex { $0.tabs.contains { $0 === tab } } ?? 0
        return index + 1
    }

    func tabInfo(_ tab: Tab) -> [String: Any] {
        let managers = allTabManagers()
        let manager = managers.first { $0.tabs.contains { $0 === tab } }
        let index = manager?.tabs.firstIndex { $0 === tab } ?? 0
        let isActive = manager?.selectedTab === tab
        var info: [String: Any] = [
            "id": tabID(for: tab),
            "index": index,
            "windowId": windowID(for: tab),
            "active": isActive,
            "highlighted": isActive,
            "selected": isActive,
            "pinned": false,
            "discarded": tab.webView == nil,
            "incognito": tab.isPrivate,
            "status": (tab.webView?.isLoading ?? false) ? "loading" : "complete",
            "audible": false,
            "mutedInfo": ["muted": false],
            "lastAccessed": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let url = tab.webView?.url ?? tab.url {
            info["url"] = url.absoluteString
        }
        info["title"] = tab.webView?.title ?? tab.displayTitle
        if let favicon = tab.faviconURL {
            info["favIconUrl"] = favicon
        }
        if let size = tab.webView?.bounds.size {
            info["width"] = Int(size.width)
            info["height"] = Int(size.height)
        }
        return info
    }

    /// Called by the browser on navigation so extensions get `tabs.onUpdated` and `webNavigation` events.
    func tabDidNavigate(_ tab: Tab, finished: Bool) {
        guard !enabledExtensions.isEmpty else { return }
        let id = tabID(for: tab)
        let url = (tab.webView?.url ?? tab.url)?.absoluteString ?? ""
        let timestamp = Date().timeIntervalSince1970 * 1000
        let navigationDetails: [String: Any] = ["tabId": id, "url": url, "frameId": 0,
                                                "parentFrameId": -1, "timeStamp": timestamp]
        var change: [String: Any] = ["status": finished ? "complete" : "loading"]
        if !finished { change["url"] = url }
        if finished, let title = tab.webView?.title { change["title"] = title }
        for webExtension in enabledExtensions {
            broadcastEvent(to: webExtension, name: "tabs.onUpdated", args: [id, change, tabInfo(tab)])
            if finished {
                broadcastEvent(to: webExtension, name: "webNavigation.onDOMContentLoaded", args: [navigationDetails])
                broadcastEvent(to: webExtension, name: "webNavigation.onCompleted", args: [navigationDetails])
            } else {
                broadcastEvent(to: webExtension, name: "webNavigation.onCommitted",
                               args: [navigationDetails.merging(["transitionType": "link",
                                                                 "transitionQualifiers": [String]()]) { $1 }])
            }
        }
    }

    // MARK: - Injection into tab web views

    /// Adds every enabled extension's scripts, message handlers and rule lists to a tab's web view.
    /// Called right after the browser's own user scripts are (re)installed.
    func injectExtensions(into webView: WKWebView?) {
        guard let webView else { return }
        startIfNeeded()
        let controller = webView.configuration.userContentController

        controller.removeScriptMessageHandler(forName: WebExtensionManager.messageHandlerName, contentWorld: .page)
        controller.addScriptMessageHandler(messageHandler, contentWorld: .page, name: WebExtensionManager.messageHandlerName)

        for webExtension in extensions {
            controller.removeScriptMessageHandler(forName: WebExtensionManager.messageHandlerName,
                                                  contentWorld: webExtension.contentWorld)
        }

        let enabled = enabledExtensions
        guard !enabled.isEmpty else { return }

        controller.addUserScript(extensionPageBootstrapScript(for: enabled))

        for webExtension in enabled {
            controller.addScriptMessageHandler(messageHandler,
                                               contentWorld: webExtension.contentWorld,
                                               name: WebExtensionManager.messageHandlerName)
            for script in contentUserScripts(for: webExtension) {
                controller.addUserScript(script)
            }
            for list in compiledRuleLists[webExtension.uuid] ?? [] {
                controller.remove(list)
                controller.add(list)
            }
        }
    }

    /// Called after the browser resets content rule lists (tracking protection changes).
    func reapplyRuleLists(to webView: WKWebView?) {
        guard let controller = webView?.configuration.userContentController else { return }
        for webExtension in enabledExtensions {
            for list in compiledRuleLists[webExtension.uuid] ?? [] {
                controller.add(list)
            }
        }
    }

    func prepareConfiguration(_ configuration: WKWebViewConfiguration) {
        if configuration.urlSchemeHandler(forURLScheme: WebExtensionURLSchemeHandler.scheme) == nil {
            configuration.setURLSchemeHandler(schemeHandler, forURLScheme: WebExtensionURLSchemeHandler.scheme)
        }
    }

    /// A configuration for background pages, popups and options pages.
    func makeExtensionPageConfiguration(for webExtension: WebExtension,
                                        isBackground: Bool,
                                        isPopup: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        prepareConfiguration(configuration)
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        let source = WebExtensionAPISource.source + "\n__flameferretInstall("
            + configJSON(for: webExtension, isBackground: isBackground, isPopup: isPopup) + ", \"page\");"
        controller.addUserScript(WKUserScript(source: source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true,
                                              in: .page))
        controller.addScriptMessageHandler(messageHandler, contentWorld: .page, name: WebExtensionManager.messageHandlerName)
        configuration.userContentController = controller
        return configuration
    }

    func registerExtensionPage(_ webView: WKWebView, uuid: String) {
        var boxes = extensionPageWebViews[uuid] ?? []
        boxes.removeAll { $0.webView == nil || $0.webView === webView }
        boxes.append(WeakWebViewBox(webView: webView))
        extensionPageWebViews[uuid] = boxes
    }

    func unregisterExtensionPage(_ webView: WKWebView) {
        for (uuid, boxes) in extensionPageWebViews {
            extensionPageWebViews[uuid] = boxes.filter { $0.webView != nil && $0.webView !== webView }
        }
    }

    func configJSON(for webExtension: WebExtension, isBackground: Bool, isPopup: Bool) -> String {
        var manifest = webExtension.manifest.raw
        manifest["name"] = webExtension.displayName
        manifest["description"] = webExtension.displayDescription
        let config: [String: Any] = [
            "id": webExtension.id,
            "uuid": webExtension.uuid,
            "manifest": manifest,
            "messages": webExtension.localization.jsonMessages,
            "uiLanguage": Locale.preferredLanguages.first ?? "en-US",
            "appVersion": AppInfo.appVersion,
            "permissions": webExtension.manifest.permissions,
            "hostPermissions": webExtension.manifest.hostPermissions,
            "isBackground": isBackground,
            "isPopup": isPopup
        ]
        return WebExtensionManager.jsonString(config)
    }

    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        // U+2028/2029 are valid in JSON but end a line in older JavaScript parsers.
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// Installs the API into `moz-extension://` pages opened in ordinary tabs.
    private func extensionPageBootstrapScript(for enabled: [WebExtension]) -> WKUserScript {
        let configs = enabled.map { "\"\($0.uuid)\": " + configJSON(for: $0, isBackground: false, isPopup: false) }
        let source = """
        (function() {
          if (location.protocol !== "moz-extension:") { return; }
          var configs = {\(configs.joined(separator: ",\n"))};
          var config = configs[location.host];
          if (!config) { return; }
          \(WebExtensionAPISource.source)
          __flameferretInstall(config, "page");
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    // MARK: - Content scripts

    func contentUserScripts(for webExtension: WebExtension) -> [WKUserScript] {
        var scripts: [WKUserScript] = []
        let bootstrap = WebExtensionAPISource.source + "\n__flameferretInstall("
            + configJSON(for: webExtension, isBackground: false, isPopup: false) + ", \"content\");"
        scripts.append(WKUserScript(source: bootstrap,
                                    injectionTime: .atDocumentStart,
                                    forMainFrameOnly: false,
                                    in: webExtension.contentWorld))

        let declared = webExtension.manifest.contentScripts
        let registered = (registeredContentScripts[webExtension.uuid] ?? []).map(contentScript(fromRegistration:))
        for entry in declared + registered {
            if let script = makeUserScript(for: entry, in: webExtension) {
                scripts.append(script)
            }
        }
        return scripts
    }

    private func contentScript(fromRegistration json: [String: Any]) -> WebExtensionManifest.ContentScript {
        return WebExtensionManifest.ContentScript(
            matches: json["matches"] as? [String] ?? [],
            excludeMatches: json["excludeMatches"] as? [String] ?? [],
            includeGlobs: json["includeGlobs"] as? [String] ?? [],
            excludeGlobs: json["excludeGlobs"] as? [String] ?? [],
            js: json["js"] as? [String] ?? [],
            css: json["css"] as? [String] ?? [],
            runAt: WebExtensionManifest.RunAt(rawValue: json["runAt"] as? String ?? "") ?? .documentIdle,
            allFrames: json["allFrames"] as? Bool ?? false,
            matchAboutBlank: json["matchOriginAsFallback"] as? Bool ?? false,
            world: (json["world"] as? String ?? "ISOLATED").uppercased()
        )
    }

    private func makeUserScript(for entry: WebExtensionManifest.ContentScript,
                                in webExtension: WebExtension) -> WKUserScript? {
        let matches = entry.matches.compactMap { WebExtensionMatchPattern($0)?.regexSource }
        guard !matches.isEmpty else { return nil }
        let excludes = entry.excludeMatches.compactMap { WebExtensionMatchPattern($0)?.regexSource }
        let includeGlobs = entry.includeGlobs.map { WebExtensionMatchPattern.userScriptGlobToRegex($0) }
        let excludeGlobs = entry.excludeGlobs.map { WebExtensionMatchPattern.userScriptGlobToRegex($0) }

        let css = entry.css.compactMap { webExtension.readText($0) }.joined(separator: "\n")
        let jsFiles = entry.js.compactMap { path -> String? in
            guard let text = webExtension.readText(path) else { return nil }
            return text + "\n//# sourceURL=\(webExtension.url(for: path).absoluteString)\n"
        }
        guard !css.isEmpty || !jsFiles.isEmpty else { return nil }

        let guardSource = """
        (function() {
          var href = String(location.href).split("#")[0];
          var test = function(list) { return list.some(function(s) { return new RegExp(s).test(href); }); };
          var aboutBlank = \(entry.matchAboutBlank ? "true" : "false")
            && (href === "about:blank" || href === "about:srcdoc");
          var ok = aboutBlank || test(\(WebExtensionManager.jsonString(matches)));
          if (ok && test(\(WebExtensionManager.jsonString(excludes)))) { ok = false; }
          var inc = \(WebExtensionManager.jsonString(includeGlobs));
          if (ok && inc.length && !test(inc)) { ok = false; }
          if (ok && test(\(WebExtensionManager.jsonString(excludeGlobs)))) { ok = false; }
          if (!ok) { throw "__flameferret_skip__"; }
        })();
        """

        var cssSource = ""
        if !css.isEmpty {
            cssSource = """
            (function(css) {
              var apply = function() {
                try {
                  var sheet = new CSSStyleSheet();
                  sheet.replaceSync(css);
                  document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
                } catch (e) {
                  var style = document.createElement("style");
                  style.textContent = css;
                  (document.head || document.documentElement).appendChild(style);
                }
              };
              if (document.documentElement) { apply(); }
              else { document.addEventListener("readystatechange", apply, { once: true }); }
            })(\(WebExtensionManager.jsonString([css])).pop());
            """
        }

        let jsSource = jsFiles.joined(separator: "\n;\n")
        let source = guardSource + "\n" + cssSource + "\n" + jsSource
        let injectionTime: WKUserScriptInjectionTime = entry.runAt == .documentStart ? .atDocumentStart : .atDocumentEnd
        let world: WKContentWorld = entry.world == "MAIN" ? .page : webExtension.contentWorld
        return WKUserScript(source: source,
                            injectionTime: injectionTime,
                            forMainFrameOnly: !entry.allFrames,
                            in: world)
    }

    private func loadRegisteredScripts(for webExtension: WebExtension) -> [[String: Any]] {
        let url = webExtension.rootDirectory.appendingPathComponent("registered-scripts.json")
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    func saveRegisteredScripts(for webExtension: WebExtension) {
        let all = registeredContentScripts[webExtension.uuid] ?? []
        let persistent = all.filter { $0["persistAcrossSessions"] as? Bool ?? true }
        let url = webExtension.rootDirectory.appendingPathComponent("registered-scripts.json")
        if let data = try? JSONSerialization.data(withJSONObject: persistent) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - declarativeNetRequest

    /// Rule sources gathered on the main actor, converted on a background task.
    struct DNRSource: Sendable {
        var files: [URL]
        var inline: [Data]
    }

    struct PreparedRules: Sendable {
        let signature: String
        let chunks: [String]?
        let skipped: Int
    }

    private struct CompiledRulesRecord: Codable {
        let signature: String
        let chunkCount: Int
    }

    func dnrSource(for webExtension: WebExtension) -> DNRSource {
        let enabledSets = store.enabledRulesets(uuid: webExtension.uuid)
        let files = webExtension.manifest.ruleResources.compactMap { resource -> URL? in
            guard enabledSets?.contains(resource.id) ?? resource.enabled else { return nil }
            return webExtension.fileURL(for: resource.path)
        }
        var inline: [Data] = []
        for rules in [store.dynamicRules(uuid: webExtension.uuid), sessionDNRRules[webExtension.uuid] ?? []]
        where !rules.isEmpty {
            if let data = try? JSONSerialization.data(withJSONObject: rules) { inline.append(data) }
        }
        return DNRSource(files: files, inline: inline)
    }

    /// Reads, fingerprints and converts the rules. Returns no chunks when `knownSignature` still matches.
    nonisolated static func prepareRules(_ source: DNRSource, knownSignature: String?) -> PreparedRules {
        let blobs = source.files.compactMap { try? Data(contentsOf: $0) } + source.inline
        var hash: UInt64 = 0xcbf29ce484222325
        for blob in blobs {
            for byte in blob {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
            hash = (hash ^ 0xff) &* 0x100000001b3
        }
        let signature = "v1-\(blobs.count)-\(String(hash, radix: 16))"
        if signature == knownSignature {
            return PreparedRules(signature: signature, chunks: nil, skipped: 0)
        }
        var rules: [[String: Any]] = []
        for blob in blobs {
            if let list = try? JSONSerialization.jsonObject(with: blob) as? [[String: Any]] {
                rules.append(contentsOf: list)
            }
        }
        let output = WebExtensionDNRConverter.convert(rules)
        let chunkSize = 50_000
        let chunks = stride(from: 0, to: output.rules.count, by: chunkSize).map { start -> String in
            let slice = Array(output.rules[start..<min(start + chunkSize, output.rules.count)])
            let data = (try? JSONSerialization.data(withJSONObject: slice)) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }
        return PreparedRules(signature: signature, chunks: chunks, skipped: output.skipped)
    }

    private func compiledRecordURL(uuid: String) -> URL {
        return store.directory(forUUID: uuid).appendingPathComponent("dnr-compiled.json")
    }

    private func loadCompiledRecord(uuid: String) -> CompiledRulesRecord? {
        guard let data = try? Data(contentsOf: compiledRecordURL(uuid: uuid)) else { return nil }
        return try? JSONDecoder().decode(CompiledRulesRecord.self, from: data)
    }

    private func saveCompiledRecord(_ record: CompiledRulesRecord, uuid: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: compiledRecordURL(uuid: uuid), options: .atomic)
    }

    func compileRuleLists(for webExtension: WebExtension, forceRecompile: Bool = false) {
        let uuid = webExtension.uuid
        let source = dnrSource(for: webExtension)
        guard !source.files.isEmpty || !source.inline.isEmpty else {
            removeRuleLists(uuid: uuid)
            compiledRuleLists[uuid] = []
            return
        }
        ruleGeneration[uuid, default: 0] += 1
        let generation = ruleGeneration[uuid] ?? 0
        let record = forceRecompile ? nil : loadCompiledRecord(uuid: uuid)
        let name = webExtension.displayName
        Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) {
                WebExtensionManager.prepareRules(source, knownSignature: record?.signature)
            }.value
            guard let self, self.ruleGeneration[uuid] == generation else { return }
            if prepared.skipped > 0 {
                self.logger.log("\(name): skipped \(prepared.skipped) rules WebKit can't express",
                                level: .info, category: .adblock)
            }
            if let chunks = prepared.chunks {
                self.compileChunks(chunks, uuid: uuid, signature: prepared.signature, generation: generation)
            } else if let record {
                self.lookUpChunks(count: record.chunkCount, uuid: uuid, generation: generation) { found in
                    if !found {
                        self.compileRuleLists(for: webExtension, forceRecompile: true)
                    }
                }
            }
        }
    }

    private func lookUpChunks(count: Int, uuid: String, generation: Int, completion: @escaping (Bool) -> Void) {
        guard let ruleListStore, count > 0 else {
            install([], uuid: uuid, generation: generation)
            completion(true)
            return
        }
        var lists: [WKContentRuleList] = []
        var remaining = count
        var missing = false
        for index in 0..<count {
            ruleListStore.lookUpContentRuleList(forIdentifier: "\(uuid)-\(index)") { list, _ in
                if let list { lists.append(list) } else { missing = true }
                remaining -= 1
                guard remaining == 0 else { return }
                if !missing { self.install(lists, uuid: uuid, generation: generation) }
                completion(!missing)
            }
        }
    }

    private func compileChunks(_ chunks: [String], uuid: String, signature: String, generation: Int) {
        guard let ruleListStore, !chunks.isEmpty else {
            install([], uuid: uuid, generation: generation)
            saveCompiledRecord(CompiledRulesRecord(signature: signature, chunkCount: 0), uuid: uuid)
            return
        }
        var compiled: [WKContentRuleList] = []
        var remaining = chunks.count
        var failed = false
        let finishChunk: (WKContentRuleList?) -> Void = { [weak self] list in
            if let list { compiled.append(list) } else { failed = true }
            remaining -= 1
            guard remaining == 0, let self else { return }
            self.install(compiled, uuid: uuid, generation: generation)
            if !failed {
                self.saveCompiledRecord(CompiledRulesRecord(signature: signature, chunkCount: chunks.count), uuid: uuid)
            }
        }
        for (index, json) in chunks.enumerated() {
            let identifier = "\(uuid)-\(index)"
            ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list {
                    finishChunk(list)
                    return
                }
                self.logger.log("Rule list compile failed: \(error?.localizedDescription ?? "unknown")",
                                level: .warning, category: .adblock)
                self.compileFallback(json: json, identifier: identifier, completion: finishChunk)
            }
        }
    }

    private func install(_ lists: [WKContentRuleList], uuid: String, generation: Int) {
        guard ruleGeneration[uuid] == generation else { return }
        detach(compiledRuleLists[uuid] ?? [])
        compiledRuleLists[uuid] = lists
        for tab in allTabs() {
            reapplyRuleLists(to: tab.webView)
        }
    }

    /// Retries a chunk without regex-derived rules, which are the usual cause of compile errors.
    private func compileFallback(json: String,
                                 identifier: String,
                                 completion: @escaping (WKContentRuleList?) -> Void) {
        let chunk = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
        let simple = chunk.filter { rule in
            let filter = (rule["trigger"] as? [String: Any])?["url-filter"] as? String ?? ""
            return !filter.contains("(") && !filter.contains("[")
        }
        guard !simple.isEmpty, let ruleListStore else {
            completion(nil)
            return
        }
        ruleListStore.compileContentRuleList(forIdentifier: identifier,
                                             encodedContentRuleList: WebExtensionManager.jsonString(simple)) { list, _ in
            completion(list)
        }
    }

    private func detach(_ lists: [WKContentRuleList]) {
        guard !lists.isEmpty else { return }
        for tab in allTabs() {
            for list in lists {
                tab.webView?.configuration.userContentController.remove(list)
            }
        }
    }

    private func removeRuleLists(uuid: String) {
        ruleGeneration[uuid, default: 0] += 1
        detach(compiledRuleLists[uuid] ?? [])
        compiledRuleLists[uuid] = nil
    }

    // MARK: - Delivering to JavaScript contexts

    /// Every web view running this extension's pages (background, popups, options, extension tabs).
    func extensionPageViews(for webExtension: WebExtension) -> [WKWebView] {
        var views: [WKWebView] = []
        if let background = backgroundHosts[webExtension.uuid]?.webView { views.append(background) }
        views.append(contentsOf: (extensionPageWebViews[webExtension.uuid] ?? []).compactMap { $0.webView })
        for tab in allTabs() {
            if let webView = tab.webView,
               webView.url?.scheme == WebExtensionURLSchemeHandler.scheme,
               webView.url?.host == webExtension.uuid,
               !views.contains(where: { $0 === webView }) {
                views.append(webView)
            }
        }
        return views
    }

    /// Runs `__flameferretExt.dispatch(type, payload)` in a context and returns its result.
    func dispatch(_ type: String,
                  payload: [String: Any],
                  to webView: WKWebView,
                  world: WKContentWorld,
                  completion: @escaping (Any?) -> Void) {
        let body = """
        if (!globalThis.__flameferretExt) { return null; }
        return await globalThis.__flameferretExt.dispatch(type, payload);
        """
        let arguments: [String: Any] = ["type": type, "payload": WebExtensionManager.sanitizeForJS(payload)]
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
            switch result {
            case .success(let value): completion(value)
            case .failure: completion(nil)
            }
        }
    }

    func broadcastEvent(to webExtension: WebExtension, name: String, args: [Any], includeContentScripts: Bool = false) {
        let payload: [String: Any] = ["name": name, "args": args]
        for view in extensionPageViews(for: webExtension) {
            dispatch("event", payload: payload, to: view, world: .page) { _ in }
        }
        guard includeContentScripts else { return }
        for tab in allTabs() {
            guard let webView = tab.webView else { continue }
            dispatch("event", payload: payload, to: webView, world: webExtension.contentWorld) { _ in }
        }
    }

    /// Sends a message to a list of contexts and resolves with the first real response.
    func deliverMessage(_ message: Any?,
                        sender: [String: Any],
                        to targets: [(WKWebView, WKContentWorld)],
                        completion: @escaping ([String: Any]) -> Void) {
        guard !targets.isEmpty else {
            completion(["error": "Could not establish connection. Receiving end does not exist."])
            return
        }
        var remaining = targets.count
        var finished = false
        let payload: [String: Any] = ["message": message ?? NSNull(), "sender": sender]
        for (webView, world) in targets {
            dispatch("message", payload: payload, to: webView, world: world) { result in
                remaining -= 1
                guard !finished else { return }
                if let response = result as? [String: Any], response["responded"] as? Bool == true {
                    finished = true
                    if let error = response["error"] as? String {
                        completion(["error": error])
                    } else {
                        completion(["value": response["value"] ?? NSNull()])
                    }
                } else if remaining == 0 {
                    finished = true
                    completion([:])
                }
            }
        }
    }

    /// Strips values that can't cross into JavaScript.
    static func sanitizeForJS(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { sanitizeForJS($0) }
        case let array as [Any]:
            return array.map { sanitizeForJS($0) }
        case is String, is NSNumber, is NSNull, is Bool, is Int, is Double:
            return value
        case let date as Date:
            return date.timeIntervalSince1970 * 1000
        default:
            return NSNull()
        }
    }

    // MARK: - Presenting extension UI

    func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    func openPopup(for webExtension: WebExtension) {
        let state = actionStates[webExtension.uuid]
        guard let popup = state?.popup ?? webExtension.manifest.action?.defaultPopup, !popup.isEmpty else {
            if let tab = selectedTab() {
                broadcastEvent(to: webExtension, name: "action.onClicked", args: [tabInfo(tab), ["button": 0]])
            }
            return
        }
        presentPage(for: webExtension, path: popup, isPopup: true)
    }

    func openOptions(for webExtension: WebExtension) {
        guard let options = webExtension.manifest.optionsPage else { return }
        presentPage(for: webExtension, path: options, isPopup: false)
    }

    private func presentPage(for webExtension: WebExtension, path: String, isPopup: Bool) {
        let controller = WebExtensionPageViewController(webExtension: webExtension,
                                                        url: webExtension.url(for: path),
                                                        isPopup: isPopup,
                                                        manager: self)
        let navigation = UINavigationController(rootViewController: controller)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = isPopup ? [.medium(), .large()] : [.large()]
            sheet.prefersGrabberVisible = true
        }
        topViewController()?.present(navigation, animated: true)
    }

    func openTab(url: URL, active: Bool, from context: WebExtensionCallContext?) -> Tab? {
        let manager = allTabManagers().first
        let current = manager?.selectedTab
        let isPrivate = context.flatMap { tab(for: $0.webView)?.isPrivate } ?? false
        guard let newTab = manager?.addTab(URLRequest(url: url),
                                           afterTab: current,
                                           zombie: false,
                                           isPrivate: isPrivate) else {
            return nil
        }
        if active {
            manager?.selectTab(newTab, previous: current, immediatePreservation: false)
            if let presented = topViewController(), presented is UINavigationController,
               (presented as? UINavigationController)?.viewControllers.first is WebExtensionPageViewController {
                presented.dismiss(animated: true)
            }
        }
        for webExtension in enabledExtensions {
            broadcastEvent(to: webExtension, name: "tabs.onCreated", args: [tabInfo(newTab)])
        }
        return newTab
    }

    func noteInstallReason(_ reason: String?, uuid: String) {
        pendingInstallReasons[uuid] = reason
    }

    func consumeInstallReason(uuid: String) -> String? {
        defer { pendingInstallReasons[uuid] = nil }
        return pendingInstallReasons[uuid]
    }
}

final class WeakWebViewBox {
    weak var webView: WKWebView?
    init(webView: WKWebView) { self.webView = webView }
}

/// A `runtime.connect` / `tabs.connect` channel between two or more contexts.
final class WebExtensionPort {
    let extensionUUID: String
    var endpoints: [(box: WeakWebViewBox, world: WKContentWorld)]

    init(extensionUUID: String, endpoints: [(box: WeakWebViewBox, world: WKContentWorld)]) {
        self.extensionUUID = extensionUUID
        self.endpoints = endpoints
    }
}

/// Breaks the retain cycle between WKUserContentController and the manager.
final class WebExtensionMessageHandlerProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var manager: WebExtensionManager?

    init(manager: WebExtensionManager) {
        self.manager = manager
    }

    @MainActor
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let manager else {
            replyHandler(nil, "Extension runtime unavailable")
            return
        }
        manager.handle(message: message, reply: replyHandler)
    }
}
