// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import UniformTypeIdentifiers
import WebKit

/// Serves `moz-extension://<uuid>/<path>` from the extension's unpacked files.
@MainActor
final class WebExtensionURLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "moz-extension"
    nonisolated static let generatedBackgroundPage = "_generated_background_page.html"

    private let extensionForHost: (String) -> WebExtension?

    init(extensionForHost: @escaping (String) -> WebExtension?) {
        self.extensionForHost = extensionForHost
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let host = url.host,
              let webExtension = extensionForHost(host) else {
            fail(urlSchemeTask, code: NSURLErrorFileDoesNotExist)
            return
        }

        let path = url.path.isEmpty ? "/" : url.path
        let body: Data
        let mimeType: String

        if path == "/" + WebExtensionURLSchemeHandler.generatedBackgroundPage {
            body = Data(generatedBackgroundHTML(for: webExtension).utf8)
            mimeType = "text/html"
        } else if let fileURL = webExtension.fileURL(for: path),
                  let data = try? Data(contentsOf: fileURL) {
            body = data
            mimeType = WebExtensionURLSchemeHandler.mimeType(for: fileURL.pathExtension)
        } else {
            fail(urlSchemeTask, code: NSURLErrorFileDoesNotExist)
            return
        }

        let isText = mimeType.hasPrefix("text/") || mimeType.contains("javascript") || mimeType.contains("json")
        let headers = [
            "Content-Type": isText ? "\(mimeType); charset=utf-8" : mimeType,
            "Content-Length": "\(body.count)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache"
        ]
        guard let response = HTTPURLResponse(url: url,
                                              statusCode: 200,
                                              httpVersion: "HTTP/1.1",
                                              headerFields: headers) else {
            fail(urlSchemeTask, code: NSURLErrorUnknown)
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(body)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
    }

    private func generatedBackgroundHTML(for webExtension: WebExtension) -> String {
        guard let background = webExtension.manifest.background else { return "<!DOCTYPE html><html></html>" }
        let scriptType = background.isModule ? " type=\"module\"" : ""
        var scripts = background.scripts
        if let worker = background.serviceWorker {
            scripts = [worker]
        }
        let tags = scripts.map { path -> String in
            let escaped = path.replacingOccurrences(of: "\"", with: "&quot;")
            let relative = escaped.hasPrefix("/") ? String(escaped.dropFirst()) : escaped
            return "<script\(scriptType) src=\"/\(relative)\"></script>"
        }.joined(separator: "\n")
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\n\(tags)\n</body></html>"
    }

    static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "wasm": return "application/wasm"
        case "txt": return "text/plain"
        default:
            return UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
