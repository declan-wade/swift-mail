import SwiftUI
import WebKit

struct HTMLMessageView: NSViewRepresentable {
    /// How the web view's own page background interacts with the surrounding
    /// window.
    enum Chrome {
        /// Shows the app's own window chrome through — used for the message
        /// reader, where the incoming HTML is expected to declare its own
        /// background.
        case transparent
        /// Renders on its own opaque white page regardless of the app's
        /// appearance — used for compose's "As Recipient Sees It", which must
        /// look identical to what ships, not to whatever theme the app is in.
        case opaque
    }

    let html: String
    var chrome: Chrome = .transparent
    /// Resolves a `cid:` reference to renderable bytes. Supplied by the reader
    /// so a message with dozens of inline parts fetches only the ones the web
    /// view actually asks to draw.
    var inlineImageResolver: InlineImageResolver?
    /// When true, the page is loaded with a content rule list that blocks every
    /// remote resource (images, stylesheets, fonts, media), so merely opening a
    /// message never phones home to the sender.
    var blocksRemoteContent = false

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Registered unconditionally: a scheme handler can only be attached to
        // a configuration before the web view exists, so the handler object is
        // stable and its resolver is swapped per message in `updateNSView`.
        configuration.setURLSchemeHandler(context.coordinator.inlineImages, forURLScheme: "cid")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        applyChrome(to: webView)

        return webView
    }

    /// A `WKWebView` scrolls its own content, so it must never report a height
    /// back to SwiftUI. Left to the default representable sizing, it hands
    /// SwiftUI its `fittingSize`, which feeds the reader's minimum height and
    /// from there the window's `contentMinSize` — measured here as tens of
    /// points of extra minimum height that grew with the window's width, so
    /// the window got harder to shrink the wider it was. Accepting the
    /// proposal outright makes the view purely elastic, like `Color`.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: proposal.height ?? 240)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        applyChrome(to: webView)
        context.coordinator.inlineImages.resolve = inlineImageResolver

        let needsReload = context.coordinator.loadedHTML != html
            || context.coordinator.loadedChrome != chrome
            || context.coordinator.loadedBlocksRemoteContent != blocksRemoteContent

        guard needsReload else {
            return
        }

        context.coordinator.loadedHTML = html
        context.coordinator.loadedChrome = chrome
        context.coordinator.loadedBlocksRemoteContent = blocksRemoteContent

        let styledHTML = html.readerStyled(transparent: chrome == .transparent)
        let shouldBlock = blocksRemoteContent

        Task { @MainActor in
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()

            if shouldBlock, let ruleList = await RemoteContentBlocker.ruleList() {
                controller.add(ruleList)
            }

            // A late-arriving update may already have superseded this load.
            guard context.coordinator.loadedHTML == html,
                  context.coordinator.loadedBlocksRemoteContent == shouldBlock else {
                return
            }

            webView.loadHTMLString(styledHTML, baseURL: nil)
        }
    }

    /// `underPageBackgroundColor` (macOS 13+) is the supported way to make a
    /// `WKWebView` see-through. Earlier code reached for the private
    /// `drawsBackground` KVC key, which `WKWebView` doesn't declare publicly —
    /// an SDK update could turn that into an `NSUnknownKeyException` crash the
    /// moment any message is opened.
    ///
    /// The opaque page also forces a light `appearance`: `prefers-color-scheme`
    /// follows the view's appearance, not the page's `color-scheme`, so in a
    /// dark app the message's own dark-mode rules would paint light text onto
    /// the forced white background.
    private func applyChrome(to webView: WKWebView) {
        webView.underPageBackgroundColor = chrome == .transparent ? .clear : .white
        webView.appearance = chrome == .transparent ? nil : NSAppearance(named: .aqua)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let inlineImages = InlineImageSchemeHandler()
        var loadedHTML: String?
        var loadedChrome: Chrome?
        var loadedBlocksRemoteContent: Bool?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}

/// Compiles — once per launch — a `WKContentRuleList` that blocks remote
/// resource loads from message HTML. Reused across every reader web view.
enum RemoteContentBlocker {
    private static let identifier = "swift-mail.block-remote-content"

    private static let encodedRuleList = """
    [
      {
        "trigger": {
          "url-filter": "^https?://",
          "resource-type": ["image", "style-sheet", "font", "media", "raw", "svg-document", "fetch", "websocket", "other", "ping"]
        },
        "action": { "type": "block" }
      }
    ]
    """

    private static let compiled = Task<WKContentRuleList?, Never> {
        guard let store = WKContentRuleListStore.default() else {
            return nil
        }

        return try? await store.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: encodedRuleList
        )
    }

    static func ruleList() async -> WKContentRuleList? {
        await compiled.value
    }
}

private extension String {
    func readerStyled(transparent: Bool) -> String {
        let backgroundRule = transparent
            ? "html { background: transparent !important; }"
            : "html { background: #ffffff !important; }"

        let style = """
        <style>
            :root {
                color-scheme: \(transparent ? "light dark" : "light");
            }

            \(backgroundRule)

            body {
                box-sizing: border-box !important;
                margin: 0 auto !important;
                max-width: 900px !important;
                min-height: 100vh !important;
                overflow-wrap: anywhere !important;
                padding: 28px 36px !important;
            }

            img, video {
                height: auto !important;
                max-width: 100% !important;
            }

            table {
                max-width: 100% !important;
            }

            pre {
                white-space: pre-wrap !important;
            }
        </style>
        """

        if let headEnd = range(of: "</head>", options: [.caseInsensitive, .backwards]) {
            var html = self
            html.insert(contentsOf: style, at: headEnd.lowerBound)
            return html
        }

        return """
        <!doctype html>
        <html>
        <head>\(style)</head>
        <body>\(self)</body>
        </html>
        """
    }
}


/// Resolves a message's `cid:` reference to bytes the reader can draw, or nil
/// if there is no such inline part.
typealias InlineImageResolver = @MainActor (String) async -> (data: Data, mimeType: String)?

/// Serves `cid:` inline parts to the reader's web view on demand.
///
/// Lazy by construction: WebKit asks only for the parts it is about to draw, so
/// a reply chain carrying seventy inline images downloads the handful actually
/// on screen instead of all of them when the message opens.
@MainActor
final class InlineImageSchemeHandler: NSObject, WKURLSchemeHandler {
    var resolve: InlineImageResolver?

    /// Tasks WebKit has not cancelled. Calling back into a stopped task raises
    /// an Objective-C exception, so every response is gated on still being here.
    private var live: Set<ObjectIdentifier> = []

    nonisolated func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        MainActor.assumeIsolated {
            let key = ObjectIdentifier(task)
            live.insert(key)

            guard let contentID = Self.contentID(from: task.request.url), let resolve else {
                finish(task, key: key, with: nil)
                return
            }

            Task { @MainActor in
                let resolved = await resolve(contentID)
                finish(task, key: key, with: resolved)
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        MainActor.assumeIsolated {
            live.remove(ObjectIdentifier(task))
        }
    }

    private func finish(_ task: any WKURLSchemeTask, key: ObjectIdentifier, with resolved: (data: Data, mimeType: String)?) {
        guard live.remove(key) != nil else {
            return
        }

        guard let resolved, let url = task.request.url else {
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: resolved.mimeType,
            expectedContentLength: resolved.data.count,
            textEncodingName: nil
        )

        task.didReceive(response)
        task.didReceive(resolved.data)
        task.didFinish()
    }

    /// `cid:` URLs are opaque, so the id is whatever follows the scheme.
    /// Senders quote it inconsistently, hence the percent-decode.
    private static func contentID(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "cid" else {
            return nil
        }

        let raw = String(url.absoluteString.dropFirst("cid:".count))

        return (raw.removingPercentEncoding ?? raw).nilIfEmpty
    }
}
