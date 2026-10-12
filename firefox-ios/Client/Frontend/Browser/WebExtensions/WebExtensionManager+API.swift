// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UIKit
import UserNotifications
import WebKit

typealias WebExtensionReply = @MainActor (Any?, String?) -> Void

// MARK: - Entry point
extension WebExtensionManager {
    func handle(message: WKScriptMessage, reply: @escaping WebExtensionReply) {
        guard let body = message.body as? [String: Any],
              let api = body["api"] as? String else {
            reply(nil, "Malformed extension API call")
            return
        }
        guard let context = makeContext(for: message, body: body) else {
            reply(nil, "This page is not allowed to use the extension API")
            return
        }
        let args = body["args"] as? [Any] ?? []
        let namespace = api.split(separator: ".").first.map(String.init) ?? ""

        switch namespace {
        case "runtime", "popup", "port": handleRuntime(api, args, context, reply)
        case "storage": handleStorage(api, args, context, reply)
        case "tabs", "windows": handleTabs(api, args, context, reply)
        case "scripting": handleScripting(api, args, context, reply)
        case "action": handleAction(api, args, context, reply)
        case "declarativeNetRequest": handleDNR(api, args, context, reply)
        default: handleMisc(api, args, context, reply)
        }
    }

    private func makeContext(for message: WKScriptMessage, body: [String: Any]) -> WebExtensionCallContext? {
        let claimedUUID = body["extensionUUID"] as? String
        let world = message.world
        let uuid: String
        let isContent: Bool
        if let name = world.name, name.hasPrefix("flameferret-ext-") {
            uuid = String(name.dropFirst("flameferret-ext-".count))
            isContent = true
        } else {
            let origin = message.frameInfo.securityOrigin
            guard origin.protocol == WebExtensionURLSchemeHandler.scheme else { return nil }
            uuid = origin.host
            isContent = false
        }
        guard claimedUUID == uuid,
              let webExtension = extensionWith(uuid: uuid),
              webExtension.isEnabled else { return nil }
        return WebExtensionCallContext(webExtension: webExtension,
                                       webView: message.webView,
                                       world: world,
                                       isContentScript: isContent,
                                       isMainFrame: message.frameInfo.isMainFrame,
                                       frameURL: message.frameInfo.request.url)
    }

    func senderInfo(for context: WebExtensionCallContext) -> [String: Any] {
        var sender: [String: Any] = ["id": context.webExtension.id,
                                     "frameId": context.isMainFrame ? 0 : 1]
        if let url = context.frameURL {
            sender["url"] = url.absoluteString
            if let scheme = url.scheme, let host = url.host {
                sender["origin"] = "\(scheme)://\(host)"
            }
        }
        if let tab = tab(for: context.webView) {
            sender["tab"] = tabInfo(tab)
        }
        return sender
    }

    /// Contexts that should receive `runtime.sendMessage` / `runtime.connect` from `context`.
    func runtimeTargets(from context: WebExtensionCallContext) -> [(WKWebView, WKContentWorld)] {
        return extensionPageViews(for: context.webExtension)
            .filter { context.isContentScript || $0 !== context.webView }
            .map { ($0, WKContentWorld.page) }
    }

    func resolveTab(_ value: Any?, context: WebExtensionCallContext) -> Tab? {
        if let id = value as? Int { return tab(withID: id) }
        if let id = (value as? NSNumber)?.intValue { return tab(withID: id) }
        if context.isContentScript, let senderTab = tab(for: context.webView) { return senderTab }
        return selectedTab()
    }
}

// MARK: - runtime, ports, popup
extension WebExtensionManager {
    // swiftlint:disable:next function_body_length
    fileprivate func handleRuntime(_ api: String,
                                   _ args: [Any],
                                   _ context: WebExtensionCallContext,
                                   _ reply: @escaping WebExtensionReply) {
        let webExtension = context.webExtension
        switch api {
        case "runtime.sendMessage":
            deliverMessage(args.first, sender: senderInfo(for: context), to: runtimeTargets(from: context)) { result in
                reply(result, nil)
            }
        case "runtime.openOptionsPage":
            openOptions(for: webExtension)
            reply(nil, nil)
        case "runtime.reload":
            setEnabled(false, for: webExtension)
            setEnabled(true, for: webExtension)
            reply(nil, nil)
        case "popup.close":
            if let webView = context.webView,
               let presenter = topViewController() as? UINavigationController,
               let page = presenter.viewControllers.first as? WebExtensionPageViewController,
               page.webView === webView {
                presenter.dismiss(animated: true)
            }
            reply(nil, nil)
        case "port.connect":
            connectPort(args, context: context)
            reply(nil, nil)
        case "port.post":
            guard let portID = args.first as? String, let port = ports[portID] else {
                reply(nil, nil)
                return
            }
            let payload: [String: Any] = ["portId": portID, "message": args.count > 1 ? args[1] : NSNull()]
            for endpoint in port.endpoints {
                guard let webView = endpoint.box.webView else { continue }
                if webView === context.webView && endpoint.world.name == context.world.name { continue }
                dispatch("portMessage", payload: payload, to: webView, world: endpoint.world) { _ in }
            }
            reply(nil, nil)
        case "port.disconnect":
            guard let portID = args.first as? String, let port = ports[portID] else {
                reply(nil, nil)
                return
            }
            ports[portID] = nil
            for endpoint in port.endpoints {
                guard let webView = endpoint.box.webView else { continue }
                if webView === context.webView && endpoint.world.name == context.world.name { continue }
                dispatch("portDisconnect", payload: ["portId": portID], to: webView, world: endpoint.world) { _ in }
            }
            reply(nil, nil)
        default:
            reply(nil, "\(api) is not supported in Flameferret")
        }
    }

    private func connectPort(_ args: [Any], context: WebExtensionCallContext) {
        guard let portID = args.first as? String, let senderView = context.webView else { return }
        let name = args.count > 1 ? (args[1] as? String ?? "") : ""
        let targetTab = args.count > 2 ? args[2] : nil

        var targets: [(WKWebView, WKContentWorld)] = []
        if let tabValue = targetTab, !(tabValue is NSNull) {
            if let tab = resolveTab(tabValue, context: context), let webView = tab.webView {
                targets = [(webView, context.webExtension.contentWorld)]
            }
        } else {
            targets = runtimeTargets(from: context)
        }

        let port = WebExtensionPort(extensionUUID: context.webExtension.uuid,
                                    endpoints: [(WeakWebViewBox(webView: senderView), context.world)])
        ports[portID] = port
        let payload: [String: Any] = ["portId": portID, "name": name, "sender": senderInfo(for: context)]
        var remaining = targets.count
        let finish = { [weak self] in
            guard let self, let port = self.ports[portID], port.endpoints.count == 1 else { return }
            self.ports[portID] = nil
            self.dispatch("portDisconnect", payload: ["portId": portID], to: senderView, world: context.world) { _ in }
        }
        if targets.isEmpty {
            finish()
            return
        }
        for (webView, world) in targets {
            dispatch("connect", payload: payload, to: webView, world: world) { [weak self] result in
                remaining -= 1
                if let response = result as? [String: Any], response["accepted"] as? Bool == true {
                    self?.ports[portID]?.endpoints.append((WeakWebViewBox(webView: webView), world))
                }
                if remaining == 0 { finish() }
            }
        }
    }
}

// MARK: - storage
extension WebExtensionManager {
    fileprivate func handleStorage(_ api: String,
                                   _ args: [Any],
                                   _ context: WebExtensionCallContext,
                                   _ reply: @escaping WebExtensionReply) {
        let area = args.first as? String ?? "local"
        let uuid = context.webExtension.uuid
        var values = readArea(area, uuid: uuid)
        let keysArg = args.count > 1 ? args[1] : nil

        switch api {
        case "storage.get":
            reply(selectKeys(keysArg, from: values), nil)
        case "storage.set":
            let items = keysArg as? [String: Any] ?? [:]
            var changes: [String: Any] = [:]
            for (key, value) in items {
                var change: [String: Any] = ["newValue": value]
                if let old = values[key] { change["oldValue"] = old }
                changes[key] = change
                values[key] = value
            }
            writeArea(area, values: values, uuid: uuid)
            notifyStorageChange(changes, area: area, webExtension: context.webExtension)
            reply(nil, nil)
        case "storage.remove":
            let keys = (keysArg as? [String]) ?? (keysArg as? String).map { [$0] } ?? []
            var changes: [String: Any] = [:]
            for key in keys {
                if let old = values.removeValue(forKey: key) { changes[key] = ["oldValue": old] }
            }
            writeArea(area, values: values, uuid: uuid)
            notifyStorageChange(changes, area: area, webExtension: context.webExtension)
            reply(nil, nil)
        case "storage.clear":
            let changes = values.mapValues { ["oldValue": $0] as [String: Any] }
            writeArea(area, values: [:], uuid: uuid)
            notifyStorageChange(changes, area: area, webExtension: context.webExtension)
            reply(nil, nil)
        case "storage.getBytesInUse":
            let selected = keysArg == nil || keysArg is NSNull ? values : selectKeys(keysArg, from: values)
            let data = try? JSONSerialization.data(withJSONObject: selected)
            reply(data?.count ?? 0, nil)
        default:
            reply(nil, "\(api) is not supported")
        }
    }

    private func readArea(_ area: String, uuid: String) -> [String: Any] {
        if area == "session" { return sessionStorage["\(uuid)/session"] ?? [:] }
        return store.storage(uuid: uuid, area: area == "sync" ? "sync" : "local")
    }

    private func writeArea(_ area: String, values: [String: Any], uuid: String) {
        if area == "session" {
            sessionStorage["\(uuid)/session"] = values
            return
        }
        store.writeStorage(values, uuid: uuid, area: area == "sync" ? "sync" : "local")
    }

    private func selectKeys(_ keys: Any?, from values: [String: Any]) -> [String: Any] {
        switch keys {
        case nil, is NSNull:
            return values
        case let key as String:
            return values[key].map { [key: $0] } ?? [:]
        case let list as [String]:
            var result: [String: Any] = [:]
            for key in list { result[key] = values[key] }
            return result
        case let defaults as [String: Any]:
            var result: [String: Any] = [:]
            for (key, fallback) in defaults { result[key] = values[key] ?? fallback }
            return result
        default:
            return [:]
        }
    }

    private func notifyStorageChange(_ changes: [String: Any], area: String, webExtension: WebExtension) {
        guard !changes.isEmpty else { return }
        let payload: [String: Any] = ["changes": changes, "areaName": area]
        for view in extensionPageViews(for: webExtension) {
            dispatch("storageChanged", payload: payload, to: view, world: .page) { _ in }
        }
        for tab in allTabs() {
            guard let webView = tab.webView else { continue }
            dispatch("storageChanged", payload: payload, to: webView, world: webExtension.contentWorld) { _ in }
        }
    }
}

// MARK: - tabs, windows
extension WebExtensionManager {
    // swiftlint:disable:next function_body_length
    fileprivate func handleTabs(_ api: String,
                                _ args: [Any],
                                _ context: WebExtensionCallContext,
                                _ reply: @escaping WebExtensionReply) {
        switch api {
        case "tabs.query":
            reply(queryTabs(args.first as? [String: Any] ?? [:], context: context).map { tabInfo($0) }, nil)
        case "tabs.get":
            guard let tab = resolveTab(args.first, context: context) else {
                reply(nil, "Invalid tab ID")
                return
            }
            reply(tabInfo(tab), nil)
        case "tabs.getCurrent":
            if !context.isContentScript, let tab = tab(for: context.webView) {
                reply(tabInfo(tab), nil)
            } else {
                reply(nil, nil)
            }
        case "tabs.create":
            let props = args.first as? [String: Any] ?? [:]
            let url = resolveURL(props["url"] as? String, for: context.webExtension) ?? URL(string: "about:blank")!
            let created = openTab(url: url, active: props["active"] as? Bool ?? true, from: context)
            reply(created.map { tabInfo($0) }, nil)
        case "tabs.update":
            let props = args.count > 1 ? (args[1] as? [String: Any] ?? [:]) : [:]
            guard let tab = resolveTab(args.first, context: context) else {
                reply(nil, "Invalid tab ID")
                return
            }
            if let url = resolveURL(props["url"] as? String, for: context.webExtension) {
                _ = tab.loadRequest(URLRequest(url: url))
            }
            if props["active"] as? Bool == true, let manager = manager(owning: tab) {
                manager.selectTab(tab, previous: manager.selectedTab, immediatePreservation: false)
            } else if props["active"] as? Bool == true, ShellTabRegistry.shared.contains(tab) {
                ShellTabRegistry.shared.setActive(tab)
            }
            reply(tabInfo(tab), nil)
        case "tabs.remove":
            for value in args.first as? [Any] ?? [] {
                if let tab = resolveTab(value, context: context), ShellTabRegistry.shared.contains(tab) {
                    let id = tabID(for: tab)
                    ShellTabRegistry.shared.closeHandler?(tab)
                    for webExtension in enabledExtensions {
                        broadcastEvent(to: webExtension, name: "tabs.onRemoved",
                                       args: [id, ["windowId": 1, "isWindowClosing": false]])
                    }
                } else if let tab = resolveTab(value, context: context), let manager = manager(owning: tab) {
                    let id = tabID(for: tab)
                    manager.removeTab(tab.tabUUID)
                    for webExtension in enabledExtensions {
                        broadcastEvent(to: webExtension, name: "tabs.onRemoved",
                                       args: [id, ["windowId": 1, "isWindowClosing": false]])
                    }
                }
            }
            reply(nil, nil)
        case "tabs.reload":
            resolveTab(args.first, context: context)?.webView?.reload()
            reply(nil, nil)
        case "tabs.duplicate":
            guard let source = resolveTab(args.first, context: context), let url = source.webView?.url ?? source.url else {
                reply(nil, "Invalid tab ID")
                return
            }
            reply(openTab(url: url, active: true, from: context).map { tabInfo($0) }, nil)
        case "tabs.sendMessage":
            guard let tab = resolveTab(args.first, context: context), let webView = tab.webView else {
                reply(["error": "Could not establish connection. Receiving end does not exist."], nil)
                return
            }
            let message = args.count > 1 ? args[1] : nil
            deliverMessage(message, sender: senderInfo(for: context),
                           to: [(webView, context.webExtension.contentWorld)]) { result in
                reply(result, nil)
            }
        case "tabs.executeScript":
            legacyExecuteScript(args, context: context, reply: reply)
        case "tabs.insertCSS", "tabs.removeCSS":
            changeCSS(insert: api == "tabs.insertCSS", args, context: context, reply: reply)
        case "tabs.captureVisibleTab":
            captureVisibleTab(reply: reply)
        case "windows.getCurrent":
            reply(windowInfo(), nil)
        default:
            reply(nil, "\(api) is not supported in Flameferret")
        }
    }

    func manager(owning tab: Tab) -> TabManager? {
        return allTabManagers().first { $0.tabs.contains { $0 === tab } }
    }

    private func resolveURL(_ string: String?, for webExtension: WebExtension) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        if let absolute = URL(string: string), absolute.scheme != nil { return absolute }
        return webExtension.url(for: string)
    }

    private func queryTabs(_ query: [String: Any], context: WebExtensionCallContext) -> [Tab] {
        var tabs = allTabs()
        let currentManager = tab(for: context.webView).flatMap { manager(owning: $0) } ?? allTabManagers().first
        let shellTabs = ShellTabRegistry.shared.tabs
        if query["currentWindow"] as? Bool == true || query["lastFocusedWindow"] as? Bool == true {
            tabs = shellTabs.isEmpty ? (currentManager?.tabs ?? []) : shellTabs
        }
        if let windowID = query["windowId"] as? Int, windowID > 0 {
            tabs = tabs.filter { self.windowID(for: $0) == windowID }
        }
        if let active = query["active"] as? Bool {
            tabs = tabs.filter { isActive($0) == active }
        }
        if let highlighted = query["highlighted"] as? Bool {
            tabs = tabs.filter { isActive($0) == highlighted }
        }
        if let pinned = query["pinned"] as? Bool, pinned {
            tabs = []
        }
        if let status = query["status"] as? String {
            tabs = tabs.filter { (($0.webView?.isLoading ?? false) ? "loading" : "complete") == status }
        }
        let urlPatterns = (query["url"] as? [String]) ?? (query["url"] as? String).map { [$0] } ?? []
        if !urlPatterns.isEmpty {
            let patterns = urlPatterns.compactMap { WebExtensionMatchPattern($0) }
            tabs = tabs.filter { tab in
                guard let url = tab.webView?.url ?? tab.url else { return false }
                return patterns.contains { $0.matches(url) }
            }
        }
        if let index = query["index"] as? Int {
            tabs = tabs.filter { tab in manager(owning: tab)?.tabs.firstIndex { $0 === tab } == index }
        }
        if let title = query["title"] as? String {
            let regex = WebExtensionMatchPattern.userScriptGlobToRegex(title)
            tabs = tabs.filter {
                ($0.webView?.title ?? $0.displayTitle).range(of: regex, options: .regularExpression) != nil
            }
        }
        return tabs
    }

    private func windowInfo() -> [String: Any] {
        let bounds = topViewController()?.view.window?.bounds ?? UIScreen.main.bounds
        return ["id": 1, "focused": true, "top": 0, "left": 0,
                "width": Int(bounds.width), "height": Int(bounds.height),
                "incognito": false, "type": "normal", "state": "fullscreen", "alwaysOnTop": false]
    }

    private func captureVisibleTab(reply: @escaping WebExtensionReply) {
        guard let webView = selectedTab()?.webView else {
            reply(nil, "No active tab")
            return
        }
        webView.takeSnapshot(with: nil) { image, error in
            guard let data = image?.pngData() else {
                reply(nil, error?.localizedDescription ?? "Capture failed")
                return
            }
            reply("data:image/png;base64," + data.base64EncodedString(), nil)
        }
    }
}

// MARK: - scripting / executeScript / insertCSS
extension WebExtensionManager {
    fileprivate func handleScripting(_ api: String,
                                     _ args: [Any],
                                     _ context: WebExtensionCallContext,
                                     _ reply: @escaping WebExtensionReply) {
        let webExtension = context.webExtension
        switch api {
        case "scripting.executeScript":
            let details = args.first as? [String: Any] ?? [:]
            guard let tab = resolveTab(details["tabId"], context: context), let webView = tab.webView else {
                reply(nil, "Invalid tab ID")
                return
            }
            let world: WKContentWorld = (details["world"] as? String)?.uppercased() == "MAIN" ? .page
                : webExtension.contentWorld
            let completion: (Any?, String?) -> Void = { value, error in
                if let error { reply(nil, error) } else { reply([["frameId": 0, "result": value ?? NSNull()]], nil) }
            }
            if let function = details["func"] as? String {
                runFunction(function, args: details["args"] as? [Any] ?? [], in: webView, world: world,
                            webExtension: webExtension, completion: completion)
            } else {
                let files = details["files"] as? [String] ?? []
                let code = files.compactMap { webExtension.readText($0) }.joined(separator: "\n;\n")
                runCode(code, in: webView, world: world, webExtension: webExtension, completion: completion)
            }
        case "scripting.registerContentScripts":
            var current = registeredContentScripts[webExtension.uuid] ?? []
            for script in args.first as? [[String: Any]] ?? [] {
                let id = script["id"] as? String
                if let index = current.firstIndex(where: { ($0["id"] as? String) == id }) {
                    current[index] = current[index].merging(script) { $1 }
                } else {
                    current.append(script)
                }
            }
            registeredContentScripts[webExtension.uuid] = current
            saveRegisteredScripts(for: webExtension)
            refreshAllWebViews()
            reply(nil, nil)
        case "scripting.unregisterContentScripts":
            let filter = args.first as? [String: Any] ?? [:]
            if let ids = filter["ids"] as? [String] {
                registeredContentScripts[webExtension.uuid]?.removeAll { ids.contains($0["id"] as? String ?? "") }
            } else {
                registeredContentScripts[webExtension.uuid] = []
            }
            saveRegisteredScripts(for: webExtension)
            refreshAllWebViews()
            reply(nil, nil)
        case "scripting.getRegisteredContentScripts":
            reply(registeredContentScripts[webExtension.uuid] ?? [], nil)
        default:
            reply(nil, "\(api) is not supported in Flameferret")
        }
    }

    private func legacyExecuteScript(_ args: [Any],
                                     context: WebExtensionCallContext,
                                     reply: @escaping WebExtensionReply) {
        let details = args.count > 1 ? (args[1] as? [String: Any] ?? [:]) : [:]
        guard let tab = resolveTab(args.first, context: context), let webView = tab.webView else {
            reply(nil, "Invalid tab ID")
            return
        }
        let webExtension = context.webExtension
        var code = details["code"] as? String ?? ""
        if let file = details["file"] as? String, let text = webExtension.readText(file) {
            code = text
        }
        runCode(code, in: webView, world: webExtension.contentWorld, webExtension: webExtension) { value, error in
            if let error { reply(nil, error) } else { reply([value ?? NSNull()], nil) }
        }
    }

    private func bootstrapGuard(for webExtension: WebExtension) -> String {
        return "if (!globalThis.__flameferretExt) {\n" + WebExtensionAPISource.source
            + "\n__flameferretInstall(" + configJSON(for: webExtension, isBackground: false, isPopup: false)
            + ", \"content\");\n}\n"
    }

    func runCode(_ code: String,
                 in webView: WKWebView,
                 world: WKContentWorld,
                 webExtension: WebExtension,
                 completion: @escaping (Any?, String?) -> Void) {
        let prefix = world.name == webExtension.contentWorldName ? bootstrapGuard(for: webExtension) : ""
        webView.evaluateJavaScript(prefix + code, in: nil, in: world) { result in
            switch result {
            case .success(let value):
                completion(WebExtensionManager.sanitizeForJS(value), nil)
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain == WKErrorDomain,
                   nsError.code == WKError.Code.javaScriptResultTypeIsUnsupported.rawValue {
                    completion(nil, nil)
                } else {
                    completion(nil, nsError.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                }
            }
        }
    }

    private func runFunction(_ source: String,
                             args: [Any],
                             in webView: WKWebView,
                             world: WKContentWorld,
                             webExtension: WebExtension,
                             completion: @escaping (Any?, String?) -> Void) {
        let prefix = world.name == webExtension.contentWorldName ? bootstrapGuard(for: webExtension) : ""
        let body = prefix + "return await (\(source)).apply(null, __flameferretArgs);"
        webView.callAsyncJavaScript(body,
                                    arguments: ["__flameferretArgs": WebExtensionManager.sanitizeForJS(args)],
                                    in: nil,
                                    in: world) { result in
            switch result {
            case .success(let value):
                completion(WebExtensionManager.sanitizeForJS(value), nil)
            case .failure(let error):
                let nsError = error as NSError
                let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String
                completion(nil, message ?? error.localizedDescription)
            }
        }
    }

    private func changeCSS(insert: Bool,
                           _ args: [Any],
                           context: WebExtensionCallContext,
                           reply: @escaping WebExtensionReply) {
        let details = args.count > 1 ? (args[1] as? [String: Any] ?? [:]) : [:]
        guard let tab = resolveTab(args.first, context: context), let webView = tab.webView else {
            reply(nil, "Invalid tab ID")
            return
        }
        let webExtension = context.webExtension
        var css = details["code"] as? String ?? ""
        let files = (details["files"] as? [String]) ?? (details["file"] as? String).map { [$0] } ?? []
        css += files.compactMap { webExtension.readText($0) }.joined(separator: "\n")
        let key = String(css.hashValue, radix: 36)
        let cssLiteral = WebExtensionManager.jsonString([css])
        let code = insert
            ? """
              (function(){ var s = document.createElement("style"); s.dataset.flameferret = "\(key)";
              s.textContent = \(cssLiteral)[0]; (document.head || document.documentElement).appendChild(s); })();
              """
            : "document.querySelectorAll('style[data-flameferret=\"\(key)\"]').forEach(function(s){ s.remove(); });"
        runCode(code, in: webView, world: webExtension.contentWorld, webExtension: webExtension) { _, error in
            reply(nil, error)
        }
    }
}

// MARK: - action
extension WebExtensionManager {
    fileprivate func handleAction(_ api: String,
                                  _ args: [Any],
                                  _ context: WebExtensionCallContext,
                                  _ reply: @escaping WebExtensionReply) {
        let uuid = context.webExtension.uuid
        var state = actionStates[uuid] ?? WebExtensionActionState()
        let property = args.first as? String ?? ""
        let details = args.count > 1 ? (args[1] as? [String: Any] ?? [:]) : [:]

        switch api {
        case "action.set":
            switch property {
            case "badgeText": state.badgeText = details["text"] as? String ?? ""
            case "badgeBackgroundColor": state.badgeBackgroundColor = WebExtensionManager.parseColor(details["color"])
            case "title": state.title = details["title"] as? String
            case "popup": state.popup = details["popup"] as? String
            case "enabled": state.enabled = details["value"] as? Bool ?? true
            default: break
            }
            actionStates[uuid] = state
            NotificationCenter.default.post(name: .webExtensionsDidChange, object: nil)
            reply(nil, nil)
        case "action.get":
            switch property {
            case "badgeText": reply(state.badgeText, nil)
            case "badgeBackgroundColor": reply(state.badgeBackgroundColor, nil)
            case "title": reply(state.title ?? context.webExtension.manifest.action?.defaultTitle ?? "", nil)
            case "popup":
                let popup = state.popup ?? context.webExtension.manifest.action?.defaultPopup
                reply(popup.map { context.webExtension.url(for: $0).absoluteString } ?? "", nil)
            default: reply(nil, nil)
            }
        case "action.openPopup":
            openPopup(for: context.webExtension)
            reply(nil, nil)
        default:
            reply(nil, "\(api) is not supported")
        }
    }

    static func parseColor(_ value: Any?) -> [Int] {
        if let array = value as? [Int], array.count >= 3 {
            return array.count == 4 ? array : array + [255]
        }
        guard var hex = value as? String else { return [217, 0, 0, 255] }
        hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count >= 6, let number = Int(hex.prefix(6), radix: 16) else { return [217, 0, 0, 255] }
        return [(number >> 16) & 0xff, (number >> 8) & 0xff, number & 0xff, 255]
    }
}

// MARK: - declarativeNetRequest
extension WebExtensionManager {
    fileprivate func handleDNR(_ api: String,
                               _ args: [Any],
                               _ context: WebExtensionCallContext,
                               _ reply: @escaping WebExtensionReply) {
        let webExtension = context.webExtension
        let uuid = webExtension.uuid
        let options = args.first as? [String: Any] ?? [:]
        let removeIDs = Set((options["removeRuleIds"] as? [Int]) ?? [])
        let addRules = options["addRules"] as? [[String: Any]] ?? []
        let filterIDs = (options["ruleIds"] as? [Int]).map(Set.init)

        switch api {
        case "declarativeNetRequest.updateDynamicRules":
            var rules = store.dynamicRules(uuid: uuid).filter { !removeIDs.contains($0["id"] as? Int ?? -1) }
            rules.append(contentsOf: addRules)
            store.writeDynamicRules(rules, uuid: uuid)
            compileRuleLists(for: webExtension)
            reply(nil, nil)
        case "declarativeNetRequest.getDynamicRules":
            let rules = store.dynamicRules(uuid: uuid)
            reply(filterIDs.map { ids in rules.filter { ids.contains($0["id"] as? Int ?? -1) } } ?? rules, nil)
        case "declarativeNetRequest.updateSessionRules":
            var rules = (sessionDNRRules[uuid] ?? []).filter { !removeIDs.contains($0["id"] as? Int ?? -1) }
            rules.append(contentsOf: addRules)
            sessionDNRRules[uuid] = rules
            compileRuleLists(for: webExtension)
            reply(nil, nil)
        case "declarativeNetRequest.getSessionRules":
            let rules = sessionDNRRules[uuid] ?? []
            reply(filterIDs.map { ids in rules.filter { ids.contains($0["id"] as? Int ?? -1) } } ?? rules, nil)
        case "declarativeNetRequest.updateEnabledRulesets":
            var enabled = currentEnabledRulesets(webExtension)
            for id in options["disableRulesetIds"] as? [String] ?? [] { enabled.remove(id) }
            for id in options["enableRulesetIds"] as? [String] ?? [] { enabled.insert(id) }
            store.writeEnabledRulesets(enabled, uuid: uuid)
            compileRuleLists(for: webExtension)
            reply(nil, nil)
        case "declarativeNetRequest.getEnabledRulesets":
            reply(Array(currentEnabledRulesets(webExtension)).sorted(), nil)
        default:
            reply(nil, "\(api) is not supported")
        }
    }

    private func currentEnabledRulesets(_ webExtension: WebExtension) -> Set<String> {
        if let stored = store.enabledRulesets(uuid: webExtension.uuid) { return stored }
        return Set(webExtension.manifest.ruleResources.filter { $0.enabled }.map { $0.id })
    }
}

// MARK: - notifications, cookies, downloads, search, webNavigation
extension WebExtensionManager {
    // swiftlint:disable:next function_body_length
    fileprivate func handleMisc(_ api: String,
                                _ args: [Any],
                                _ context: WebExtensionCallContext,
                                _ reply: @escaping WebExtensionReply) {
        switch api {
        case "notifications.create":
            let id = (args.first as? String) ?? UUID().uuidString
            let options = args.count > 1 ? (args[1] as? [String: Any] ?? [:]) : [:]
            postNotification(id: id, options: options, webExtension: context.webExtension)
            reply(id, nil)
        case "notifications.clear":
            if let id = args.first as? String {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
            }
            reply(true, nil)
        case "cookies.get", "cookies.getAll", "cookies.set", "cookies.remove":
            handleCookies(api, details: args.first as? [String: Any] ?? [:], reply: reply)
        case "downloads.download":
            let options = args.first as? [String: Any] ?? [:]
            if let string = options["url"] as? String, let url = URL(string: string) {
                _ = openTab(url: url, active: true, from: context)
            }
            reply(1, nil)
        case "search.search":
            let props = args.first as? [String: Any] ?? [:]
            let query = (props["query"] as? String ?? props["text"] as? String ?? "")
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "https://duckduckgo.com/?q=\(query)") {
                _ = openTab(url: url, active: true, from: context)
            }
            reply(nil, nil)
        case "net.fetch":
            proxyFetch(args.first as? [String: Any] ?? [:], context: context, reply: reply)
        case "webNavigation.getFrame":
            let details = args.first as? [String: Any] ?? [:]
            guard let tab = resolveTab(details["tabId"], context: context) else {
                reply(nil, nil)
                return
            }
            reply(["url": (tab.webView?.url ?? tab.url)?.absoluteString ?? "", "parentFrameId": -1,
                   "errorOccurred": false, "frameId": 0], nil)
        case "webNavigation.getAllFrames":
            let details = args.first as? [String: Any] ?? [:]
            guard let tab = resolveTab(details["tabId"], context: context) else {
                reply([], nil)
                return
            }
            reply([["url": (tab.webView?.url ?? tab.url)?.absoluteString ?? "", "parentFrameId": -1,
                    "errorOccurred": false, "frameId": 0]], nil)
        default:
            reply(nil, "\(api) is not supported in Flameferret")
        }
    }

    /// Performs a cross-origin request for an extension page that has host permission for it.
    private func proxyFetch(_ details: [String: Any], context: WebExtensionCallContext, reply: @escaping WebExtensionReply) {
        guard !context.isContentScript,
              let urlString = details["url"] as? String,
              let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme ?? ""),
              context.webExtension.hasHostAccess(to: url) else {
            reply(nil, "NetworkError when attempting to fetch resource.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = details["method"] as? String ?? "GET"
        for (key, value) in details["headers"] as? [String: String] ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body = details["body"] as? String {
            request.httpBody = Data(body.utf8)
        }
        let finalRequest = request
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: finalRequest)
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (key, value) in http?.allHeaderFields ?? [:] {
                    headers["\(key)"] = "\(value)"
                }
                reply(["status": http?.statusCode ?? 200,
                       "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 200),
                       "headers": headers,
                       "url": response.url?.absoluteString ?? urlString,
                       "body": data.base64EncodedString()], nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    private func postNotification(id: String, options: [String: Any], webExtension: WebExtension) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = options["title"] as? String ?? webExtension.displayName
        content.body = options["message"] as? String ?? ""
        content.subtitle = webExtension.displayName
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            } else {
                center.add(request)
            }
        }
    }

    private func handleCookies(_ api: String, details: [String: Any], reply: @escaping WebExtensionReply) {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        if api == "cookies.set" {
            guard let cookie = makeCookie(details) else {
                reply(nil, "Invalid cookie details")
                return
            }
            cookieStore.setCookie(cookie) {
                reply(WebExtensionManager.cookieJSON(cookie), nil)
            }
            return
        }
        cookieStore.getAllCookies { cookies in
            let matching = cookies.filter { WebExtensionManager.cookie($0, matches: details) }
            switch api {
            case "cookies.get":
                reply(matching.first.map(WebExtensionManager.cookieJSON), nil)
            case "cookies.getAll":
                reply(matching.map(WebExtensionManager.cookieJSON), nil)
            default:
                let removed = matching.first.map { ["url": details["url"] ?? "", "name": $0.name] as [String: Any] }
                guard !matching.isEmpty else {
                    reply(nil, nil)
                    return
                }
                var remaining = matching.count
                for cookie in matching {
                    cookieStore.delete(cookie) {
                        remaining -= 1
                        if remaining == 0 { reply(removed, nil) }
                    }
                }
            }
        }
    }

    private func makeCookie(_ details: [String: Any]) -> HTTPCookie? {
        guard let urlString = details["url"] as? String, let url = URL(string: urlString), let host = url.host else {
            return nil
        }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: details["name"] as? String ?? "",
            .value: details["value"] as? String ?? "",
            .domain: details["domain"] as? String ?? host,
            .path: details["path"] as? String ?? "/"
        ]
        if details["secure"] as? Bool == true { properties[.secure] = "TRUE" }
        if let expiry = details["expirationDate"] as? Double {
            properties[.expires] = Date(timeIntervalSince1970: expiry)
        }
        return HTTPCookie(properties: properties)
    }

    static func cookie(_ cookie: HTTPCookie, matches details: [String: Any]) -> Bool {
        if let name = details["name"] as? String, cookie.name != name { return false }
        if let domain = details["domain"] as? String {
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let cookieDomain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if !(cookieDomain == bare || cookieDomain.hasSuffix("." + bare)) { return false }
        }
        if let urlString = details["url"] as? String, let host = URL(string: urlString)?.host {
            let cookieDomain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if !(host == cookieDomain || host.hasSuffix("." + cookieDomain)) { return false }
        }
        if let path = details["path"] as? String, cookie.path != path { return false }
        if let secure = details["secure"] as? Bool, cookie.isSecure != secure { return false }
        if let session = details["session"] as? Bool, cookie.isSessionOnly != session { return false }
        return true
    }

    static func cookieJSON(_ cookie: HTTPCookie) -> [String: Any] {
        var json: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "hostOnly": !cookie.domain.hasPrefix("."),
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
            "session": cookie.isSessionOnly,
            "storeId": "firefox-default",
            "firstPartyDomain": ""
        ]
        if let expires = cookie.expiresDate { json["expirationDate"] = expires.timeIntervalSince1970 }
        switch cookie.sameSitePolicy {
        case HTTPCookieStringPolicy.sameSiteLax: json["sameSite"] = "lax"
        case HTTPCookieStringPolicy.sameSiteStrict: json["sameSite"] = "strict"
        default: json["sameSite"] = "no_restriction"
        }
        return json
    }
}
