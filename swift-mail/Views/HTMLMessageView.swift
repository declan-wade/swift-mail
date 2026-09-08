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
    /// When true, the page is loaded with a content rule list that blocks every
    /// remote resource (images, stylesheets, fonts, media), so merely opening a
    /// message never phones home to the sender.
    var blocksRemoteContent = false

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        applyChrome(to: webView)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        applyChrome(to: webView)

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
    private func applyChrome(to webView: WKWebView) {
        webView.underPageBackgroundColor = chrome == .transparent ? .clear : .white
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
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
