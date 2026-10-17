// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import WebKit

/// Labels add-ons on addons.mozilla.org with whether they'll work in Culpeo: a badge next to every
/// add-on link, and a banner with the reasons on each add-on's page.
@MainActor
final class WebExtensionStoreLabels: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = WebExtensionStoreLabels()
    static let handlerName = "ferretStoreLabels"
    static let contentWorld = WKContentWorld.world(name: "ferret-store-labels")

    func inject(into webView: WKWebView?) {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.contentWorld)
        controller.addScriptMessageHandler(self, contentWorld: Self.contentWorld, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true,
                                              in: Self.contentWorld))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard Self.isStoreHost(message.frameInfo.securityOrigin.host),
              let addon = message.body as? [String: Any] else {
            replyHandler(nil, "Not available on this site")
            return
        }
        replyHandler(WebExtensionCompatibility.assess(amoAddon: addon).dictionary, nil)
    }

    static func isStoreHost(_ host: String) -> Bool {
        return host == "addons.mozilla.org"
    }

    /// Runs only on addons.mozilla.org. Looks each add-on up in the store's own API (same origin), asks
    /// Culpeo for a verdict, and keeps up with the store's single-page navigation.
    static let script = #"""
    (function () {
      if (location.hostname !== "addons.mozilla.org" || window.__ferretStoreLabels) { return; }
      window.__ferretStoreLabels = true;
      var handler = window.webkit && window.webkit.messageHandlers.ferretStoreLabels;
      if (!handler) { return; }
      var COLORS = { works: "#1A365C", partial: "#7E5F21", incompatible: "#9E2B2B", unsupportedType: "#5C5F66" };
      var ICONS = { works: "✓", partial: "◐", incompatible: "✕", unsupportedType: "–" };
      var reports = new Map();
      var ADDON_PATH = /^\/(?:[^\/]+\/)?(?:firefox|android)\/addon\/([^\/?#]+)\/?$/;

      function slugFor(href) {
        try {
          var url = new URL(href, location.href);
          if (url.hostname !== location.hostname) { return null; }
          var match = ADDON_PATH.exec(url.pathname);
          return match ? decodeURIComponent(match[1]) : null;
        } catch (e) { return null; }
      }

      function report(slug) {
        if (!reports.has(slug)) {
          reports.set(slug, fetch("/api/v5/addons/addon/" + encodeURIComponent(slug) + "/", { credentials: "omit" })
            .then(function (r) { if (!r.ok) { throw new Error("lookup failed"); } return r.json(); })
            .then(function (addon) {
              var file = (addon.current_version && addon.current_version.file) || {};
              return handler.postMessage({
                type: addon.type || "extension",
                permissions: file.permissions || [],
                optional_permissions: file.optional_permissions || []
              });
            })
            .catch(function () { reports.delete(slug); return null; }));
        }
        return reports.get(slug);
      }

      function badge(result) {
        var el = document.createElement("span");
        el.className = "ferret-compat-badge";
        el.textContent = ICONS[result.verdict] + " " + result.label;
        el.title = result.notes.join("\n");
        el.style.cssText = "display:inline-block;margin:4px 0 0;padding:2px 8px;border-radius:999px;" +
          "font:600 12px/1.5 -apple-system,system-ui,sans-serif;letter-spacing:.2px;color:#fff;" +
          "background:" + COLORS[result.verdict] + ";white-space:nowrap;vertical-align:middle";
        return el;
      }

      function banner(result) {
        var box = document.createElement("div");
        box.className = "ferret-compat-banner";
        box.style.cssText = "margin:12px 0;padding:12px 14px;border-radius:10px;border-left:4px solid " +
          COLORS[result.verdict] + ";background:#F4F1E8;color:#0F1A2A;font:14px/1.45 -apple-system,system-ui,sans-serif";
        var title = document.createElement("div");
        title.style.cssText = "font-weight:700;color:" + COLORS[result.verdict];
        title.textContent = ICONS[result.verdict] + " " + result.label;
        box.appendChild(title);
        if (result.notes.length) {
          var list = document.createElement("ul");
          list.style.cssText = "margin:6px 0 0;padding-left:18px";
          result.notes.forEach(function (note) {
            var item = document.createElement("li");
            item.textContent = note;
            list.appendChild(item);
          });
          box.appendChild(list);
        } else {
          var line = document.createElement("div");
          line.textContent = "Everything this add-on asks for is supported.";
          box.appendChild(line);
        }
        return box;
      }

      function labelLinks() {
        document.querySelectorAll("a[href*='/addon/']:not([data-ferret-compat])").forEach(function (link) {
          link.setAttribute("data-ferret-compat", "1");
          var slug = slugFor(link.getAttribute("href"));
          if (!slug || !link.textContent.trim() || link.closest(".ferret-compat-banner")) { return; }
          report(slug).then(function (result) {
            if (result && link.isConnected && !link.querySelector(".ferret-compat-badge")) {
              link.appendChild(document.createElement("br"));
              link.appendChild(badge(result));
            }
          });
        });
      }

      var bannerSlug = null;
      function labelPage() {
        var slug = slugFor(location.href);
        var existing = document.querySelector(".ferret-compat-banner");
        if (slug === bannerSlug && existing) { return; }
        if (existing) { existing.remove(); }
        bannerSlug = slug;
        if (!slug) { return; }
        report(slug).then(function (result) {
          var heading = document.querySelector("main h1, h1");
          if (!result || slug !== bannerSlug || !heading || document.querySelector(".ferret-compat-banner")) { return; }
          heading.insertAdjacentElement("afterend", banner(result));
        });
      }

      var pending = null;
      function scan() {
        pending = null;
        labelPage();
        labelLinks();
      }
      new MutationObserver(function () {
        if (!pending) { pending = setTimeout(scan, 250); }
      }).observe(document.documentElement, { childList: true, subtree: true });
      scan();
    })();
    """#
}
