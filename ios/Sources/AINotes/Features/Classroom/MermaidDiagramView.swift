import os
import SwiftUI
import WebKit

/// Renders backend-generated Mermaid using a locally bundled JS runtime.
/// There is no CDN fallback; a failed parse shows a polished card instead.
struct MermaidDiagramView: View {
    let source: String
    var caption: String = ""
    var bodyText: String = ""

    @State private var failed = false
    @State private var failureMessage = ""

    var body: some View {
        ZStack {
            if failed {
                fallback
            } else {
                MermaidWebView(
                    source: source,
                    onFailure: { message in
                        failed = true
                        failureMessage = message
                        Logger.mermaid.error("Mermaid render failed: \(message, privacy: .public)")
                    }
                )
                .opacity(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
            }
        }
        .onChange(of: source) { _, _ in
            failed = false
            failureMessage = ""
        }
        .onAppear {
            if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failed = true
                failureMessage = "empty mermaid source"
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failed ? "Diagram unavailable" : "Lesson diagram")
        .accessibilityValue(caption)
    }

    private var fallback: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.title2.weight(.semibold))
                .foregroundStyle(NomiTheme.blue)
            Text("Diagram unavailable")
                .font(.title3.weight(.bold))
                .foregroundStyle(NomiTheme.ink)
            if !caption.isEmpty {
                Text(caption)
                    .font(.body)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .multilineTextAlignment(.center)
            } else if !bodyText.isEmpty {
                Text(bodyText)
                    .font(.body)
                    .foregroundStyle(NomiTheme.secondaryInk)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(
            NomiTheme.paper,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(NomiTheme.hairline, lineWidth: 1)
        }
    }
}

private extension Logger {
    static let mermaid = Logger(subsystem: "com.izaanqaiser.nomi", category: "Mermaid")
}

private struct MermaidWebView: UIViewRepresentable {
    let source: String
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "classroomMermaid")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContent
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isInspectable = false
        context.coordinator.webView = webView
        context.coordinator.loadHostPage()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        context.coordinator.render(source)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "classroomMermaid")
        uiView.navigationDelegate = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onFailure: (String) -> Void
        weak var webView: WKWebView?
        private var pageReady = false
        private var pendingSource: String?
        private var renderedSource: String?

        init(onFailure: @escaping (String) -> Void) {
            self.onFailure = onFailure
        }

        func loadHostPage() {
            guard let html = Bundle.main.url(forResource: "mermaid", withExtension: "html") else {
                Logger.mermaid.error("Bundled mermaid.html is missing")
                onFailure("Mermaid runtime is missing from the app bundle")
                return
            }
            let directory = html.deletingLastPathComponent()
            webView?.loadFileURL(html, allowingReadAccessTo: directory)
        }

        func render(_ source: String) {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != renderedSource else { return }
            pendingSource = trimmed
            guard pageReady, webView != nil else { return }
            flushPending()
        }

        private func flushPending() {
            guard pageReady, let source = pendingSource, let webView else { return }
            pendingSource = nil
            renderedSource = source
            guard let payload = try? JSONEncoder().encode(source),
                  let json = String(data: payload, encoding: .utf8) else {
                onFailure("Could not encode diagram source")
                return
            }
            webView.evaluateJavaScript("renderDiagram(\(json))") { _, error in
                if let error {
                    Logger.mermaid.error("evaluateJavaScript failed: \(error.localizedDescription, privacy: .public)")
                    self.renderedSource = nil
                    self.onFailure(error.localizedDescription)
                }
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "classroomMermaid" else { return }
            let body = message.body as? [String: Any] ?? [:]
            if body["ready"] as? Bool == true {
                pageReady = true
                flushPending()
                return
            }
            if body["ok"] as? Bool == true {
                return
            }
            let error = body["error"] as? String ?? "Unknown Mermaid error"
            renderedSource = nil
            onFailure(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let isLocalFile = url.isFileURL
            let isBlank = url.absoluteString == "about:blank"
            if (isLocalFile || isBlank) && navigationAction.targetFrame != nil {
                decisionHandler(.allow)
            } else {
                Logger.mermaid.error("Blocked Mermaid navigation to \(url.absoluteString, privacy: .public)")
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFailure(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure(error.localizedDescription)
        }
    }
}
