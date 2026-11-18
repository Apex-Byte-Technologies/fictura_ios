#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import SafariServices
import StoreKit
import UserNotifications

/// Shows a served HTML paywall in a WKWebView. The page talks to the SDK
/// through `window.__FICTURA__` exactly as it does in the React Native SDK.
final class PaywallViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, PaywallHost {
    let bridge: PaywallBridge
    private let request: PresentRequest
    private let api: API
    private let transport: Transport
    private var webView: WKWebView!
    private var spinner: UIActivityIndicatorView?
    private var closed = false

    init(bridge: PaywallBridge, request: PresentRequest, api: API, transport: Transport) {
        self.bridge = bridge
        self.request = request
        self.api = api
        self.transport = transport
        super.init(nibName: nil, bundle: nil)
        bridge.host = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        spinner.startAnimating()
        self.spinner = spinner
        bridge.markShown()
        Task { [weak self] in
            guard let self else { return }
            await self.bridge.loadPackages()
            let html = await self.resolveHTML()
            await MainActor.run { self.load(html) }
        }
    }

    /// The design's html: inline in the config, or fetched lazily when it was too large to inline.
    private func resolveHTML() async -> String? {
        if !bridge.html.isEmpty { return bridge.html }
        guard let r = api.request("api/v1/sdk/paywall/\(request.info.paywallId)/html",
                                  query: ["sv": String(SDKInfo.paywallSchema), "locale": DeviceContext.locale()]) else { return nil }
        return await withCheckedContinuation { cont in
            transport.send(r) { result in
                let html = result.ok ? JSON.parse(result.body)?["html"]?.stringValue : nil
                cont.resume(returning: html.map { PaywallBridge.substituteParams($0, self.request.params) })
            }
        }
    }

    private func load(_ html: String?) {
        guard let html, !html.isEmpty else {
            bridge.logLoadFailed(stage: "config", error: "no_html")
            closePaywall(result: .declined, reason: .webview_failed)
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: bridge.injectedScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(WeakMessageHandler(self), name: "fictura")
        config.userContentController = controller
        let web = WKWebView(frame: view.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        if #available(iOS 16.4, *) { web.isInspectable = true }
        view.addSubview(web)
        webView = web
        web.loadHTMLString(html, baseURL: api.base)
    }

    // MARK: PaywallHost

    func evaluate(_ js: String) {
        DispatchQueue.main.async { self.webView?.evaluateJavaScript(js, completionHandler: nil) }
    }

    func closePaywall(result: PaywallResult, reason: CloseReason) {
        DispatchQueue.main.async {
            guard !self.closed else { return }
            self.closed = true
            self.request.onClose(result, reason)
        }
    }

    func open(url: URL, inApp: Bool) {
        DispatchQueue.main.async {
            if inApp { self.present(SFSafariViewController(url: url), animated: true) } else { UIApplication.shared.open(url) }
        }
    }

    func haptic(_ kind: String) {
        DispatchQueue.main.async {
            switch kind {
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
            case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "selection": UISelectionFeedbackGenerator().selectionChanged()
            default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    func requestReview() {
        DispatchQueue.main.async {
            if let scene = self.view.window?.windowScene { SKStoreReviewController.requestReview(in: scene) }
        }
    }

    func alert(title: String, message: String) {
        DispatchQueue.main.async {
            let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(a, animated: true)
        }
    }

    func requestPermission(_ name: String, completion: @escaping (Bool) -> Void) {
        switch name {
        case "notifications":
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    // MARK: WebKit

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        if body.contains("\"ready\"") {
            spinner?.removeFromSuperview()
            spinner = nil
        }
        bridge.handle(body)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The design itself, and in-page anchors, load here; any other link leaves the paywall's web view.
        let url = navigationAction.request.url
        if navigationAction.navigationType == .other || url?.absoluteString == "about:blank" ||
            url?.host == api.base.host && url?.path == api.base.path {
            return decisionHandler(.allow)
        }
        if let url, navigationAction.targetFrame?.isMainFrame != false, PaywallBridge.linkOk(url.absoluteString) {
            open(url: url, inApp: false)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        bridge.logLoadFailed(stage: "webview", error: error.localizedDescription)
        closePaywall(result: .declined, reason: .webview_failed)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        bridge.event("paywall_webview_crashed", status: .failure)
        closePaywall(result: .declined, reason: .webview_failed)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Swiped away as a sheet: that is a decline.
        if !closed && (isBeingDismissed || presentingViewController == nil) {
            bridge.logDismissed(reason: "manual", result: "declined")
            closePaywall(result: .declined, reason: .manual)
        }
    }
}

/// WKUserContentController holds its handler strongly; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// Presents placement paywalls over whatever the app shows.
final class UIKitPaywallPresenter: PaywallPresenting {
    private let makeBridge: (PresentRequest) -> PaywallBridge
    private let api: API
    private let transport: Transport
    private var shown: [Int: PaywallViewController] = [:]

    init(api: API, transport: Transport, makeBridge: @escaping (PresentRequest) -> PaywallBridge) {
        self.api = api
        self.transport = transport
        self.makeBridge = makeBridge
    }

    func show(_ request: PresentRequest) {
        let bridge = makeBridge(request)
        bridge.onShown = request.onShown
        bridge.onPurchaseCancelled = request.onPurchaseCancelled
        bridge.onPurchaseFailed = request.onPurchaseFailed
        let vc = PaywallViewController(bridge: bridge, request: request, api: api, transport: transport)
        let style = request.info.presentationStyle
        switch style {
        case "modal": vc.modalPresentationStyle = .pageSheet
        case "drawer":
            vc.modalPresentationStyle = .pageSheet
            vc.sheetPresentationController?.detents = [.medium(), .large()]
        default: vc.modalPresentationStyle = .fullScreen
        }
        shown[request.id] = vc
        DispatchQueue.main.asyncAfter(deadline: .now() + request.delay) {
            guard let top = Self.topViewController() else {
                request.onClose(.declined, .system)
                return
            }
            top.present(vc, animated: style != "no_animation")
        }
    }

    func hide(_ id: Int) {
        guard let vc = shown.removeValue(forKey: id) else { return }
        vc.presentingViewController?.dismiss(animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
#endif
