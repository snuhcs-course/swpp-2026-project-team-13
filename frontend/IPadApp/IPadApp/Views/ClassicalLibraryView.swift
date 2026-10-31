import SwiftUI
import WebKit
import AVFoundation

// A self-contained listening collection. It never writes to the exam catalog or attempts.
struct ClassicalLibraryView: View {
    var body: some View {
        ClassicalLibraryWebView()
            .accessibilityLabel("클래식 청음실, 작곡가별 선율 목록")
    }
}

private struct ClassicalLibraryWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        context.coordinator.attach(view)
        if let url = Bundle.main.url(forResource: "classical-library", withExtension: "html") {
            view.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            view.loadHTMLString("<html lang='ko'><meta name='viewport' content='width=device-width'><p>클래식 목록을 불러오지 못했어요. 최신 앱에 포함된 자료를 확인해 주세요.</p></html>", baseURL: nil)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        view.evaluateJavaScript("window.stopClassicalAudio?.()") { _, _ in
            view.loadHTMLString("", baseURL: nil)
        }
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var webView: WKWebView?
        private var observers: [NSObjectProtocol] = []

        func attach(_ view: WKWebView) {
            webView = view
            let names: [Notification.Name] = [UIApplication.willResignActiveNotification,
                AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification,
                AVAudioSession.routeChangeNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak view] _ in
                    Task { @MainActor in view?.evaluateJavaScript("window.stopClassicalAudio?.()", completionHandler: nil) }
                }
            }
        }

        func detach() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            webView = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.setNativeClassical?.()", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                if let url = action.request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
