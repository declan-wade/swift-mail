import SwiftUI
import WebKit

struct HTMLMessageView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else {
            return
        }

        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html.readerStyled(), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML: String?

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

private extension String {
    func readerStyled() -> String {
        let style = """
        <style>
            :root {
                color-scheme: light dark;
            }

            html {
                background: transparent !important;
            }

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
