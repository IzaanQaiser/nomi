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
                    source: Self.repairedMermaid(source),
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

    private static func repairedMermaid(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return source
        }
        let kind = header.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        guard kind == "flowchart" || kind == "graph" else { return source }

        let arrow = try? NSRegularExpression(
            pattern: #"(\s*(?:-->|---|==>|-\.->|<-->)\s*(?:\|[^|]*\|\s*)?)"#
        )
        return lines.enumerated().map { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0 || trimmed.isEmpty || trimmed.hasPrefix("%%") {
                return line
            }
            guard let arrow else { return line }
            let nsLine = trimmed as NSString
            let matches = arrow.matches(
                in: trimmed,
                range: NSRange(location: 0, length: nsLine.length)
            )
            var parts: [String] = []
            var cursor = 0
            for match in matches {
                if match.range.location > cursor {
                    parts.append(
                        repairNode(nsLine.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
                    )
                }
                parts.append(nsLine.substring(with: match.range))
                cursor = match.range.location + match.range.length
            }
            if cursor < nsLine.length {
                parts.append(repairNode(nsLine.substring(from: cursor)))
            }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            return indent + parts.joined()
        }
        .joined(separator: "\n")
    }

    private static func repairNode(_ raw: String) -> String {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return raw }
        var quoted = token
        if let start = quoted.firstIndex(of: "["),
           let end = quoted.lastIndex(of: "]"),
           start < end {
            let inner = quoted[quoted.index(after: start)..<end]
            let innerText = inner.trimmingCharacters(in: .whitespaces)
            if !innerText.hasPrefix("\""), innerText.contains(where: { $0.isWhitespace || ":()/,=".contains($0) }) {
                let safe = innerText.replacingOccurrences(of: "\"", with: "'")
                quoted.replaceSubrange(start...end, with: "[\"\(safe)\"]")
            }
        }
        if quoted.contains(where: \.isWhitespace), !quoted.contains(where: { "[{(".contains($0) }) {
            let ident = quoted.replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            let safeIdent = ident.isEmpty ? "N" : ident
            let label = quoted.replacingOccurrences(of: "\"", with: "'")
            return "\(safeIdent)[\"\(label)\"]"
        }
        return quoted
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
        if let jsURL = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
           let js = try? String(contentsOf: jsURL, encoding: .utf8) {
            userContent.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        } else {
            Logger.mermaid.error("Bundled mermaid.min.js is missing")
        }

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
        private var renderAttempts = 0

        init(onFailure: @escaping (String) -> Void) {
            self.onFailure = onFailure
        }

        func loadHostPage() {
            guard let htmlURL = Bundle.main.url(forResource: "mermaid", withExtension: "html"),
                  let html = try? String(contentsOf: htmlURL, encoding: .utf8) else {
                Logger.mermaid.error("Bundled mermaid.html is missing")
                onFailure("Mermaid runtime is missing from the app bundle")
                return
            }
            webView?.loadHTMLString(html, baseURL: htmlURL.deletingLastPathComponent())
        }

        func render(_ source: String) {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != renderedSource else { return }
            pendingSource = trimmed
            renderAttempts = 0
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
            webView.evaluateJavaScript("renderDiagram(\(json))") { [weak self] _, error in
                if let error {
                    Logger.mermaid.error("evaluateJavaScript failed: \(error.localizedDescription, privacy: .public)")
                    self?.retryOrFail(source, message: error.localizedDescription)
                }
            }
        }

        private func retryOrFail(_ source: String, message: String) {
            let transient = message.localizedCaseInsensitiveContains("undefined")
                || message.localizedCaseInsensitiveContains("runtime missing")
                || message.localizedCaseInsensitiveContains("not a function")
            renderedSource = nil
            if transient, renderAttempts < 4, !source.isEmpty {
                renderAttempts += 1
                pendingSource = source
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.flushPending()
                }
                return
            }
            onFailure(message)
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
            retryOrFail(renderedSource ?? pendingSource ?? "", message: error)
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
            let isAbout = url.scheme == "about"
            if (isLocalFile || isAbout) && navigationAction.targetFrame != nil {
                decisionHandler(.allow)
            } else {
                Logger.mermaid.error("Blocked Mermaid navigation to \(url.absoluteString, privacy: .public)")
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, !self.pageReady else { return }
                self.pageReady = true
                self.flushPending()
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
