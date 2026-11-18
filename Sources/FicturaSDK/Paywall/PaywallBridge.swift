import Foundation

/// What a showing paywall needs from the screen hosting it (a WKWebView on iOS).
protocol PaywallHost: AnyObject {
    /// Runs a script in the page.
    func evaluate(_ js: String)
    /// Closes the paywall.
    func closePaywall(result: PaywallResult, reason: CloseReason)
    func open(url: URL, inApp: Bool)
    func haptic(_ kind: String)
    func requestReview()
    func alert(title: String, message: String)
    /// Asks the system for a permission; false when unsupported.
    func requestPermission(_ name: String, completion: @escaping (Bool) -> Void)
}

public enum PaywallResult: Equatable {
    case purchased(productId: String)
    case restored
    case declined
}

public enum CloseReason: String {
    case manual, system, for_next_paywall, webview_failed
}

/// The ids every paywall event carries (src/paywall/paywallEvents.ts).
struct PaywallEventContext {
    var placement: String
    var paywallId: String
    var paywallVersion: Int?
    var campaignId: String?
    var audienceId: String?
    var experimentId: String?
    var variantId: String?
    var presentedBy: String

    var properties: JSONObject {
        func opt(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
        return [
            "placement": .string(placement), "paywall_id": .string(paywallId),
            "paywall_version": paywallVersion.map { .int($0) } ?? .null,
            "campaign_id": opt(campaignId), "audience_id": opt(audienceId),
            "experiment_id": opt(experimentId), "variant_id": opt(variantId),
            "presented_by": .string(presentedBy),
        ]
    }
}

/// One showing of a paywall: its events, purchase and restore, and the bridge
/// messages from the page (`window.__FICTURA__`). Platform independent, so it is
/// unit-tested without a web view.
final class PaywallBridge {
    let id = IDs.uuidv4()
    let context: PaywallEventContext
    let html: String
    let params: JSONObject
    private let core: FicturaCore
    private let controller: FicturaPurchaseController?
    private let slotMap: [String: String]
    private let pageValues: JSONObject
    private let webCheckout: () -> Bool
    private let openWebCheckout: (String?) -> Bool
    private let presentPlacement: (String) -> Void
    private let customAction: ((String, [String: Any]) async -> [String: Any]?)?
    weak var host: PaywallHost?
    private(set) var packages: [FicturaPackage] = []
    private(set) var ready = false
    private var shownAt: Date?
    private var dismissed = false
    private var busy = false
    var onShown: (() -> Void)?
    var onPurchaseCancelled: ((String) -> Void)?
    var onPurchaseFailed: ((String, String) -> Void)?

    init(core: FicturaCore, controller: FicturaPurchaseController?, context: PaywallEventContext, html: String,
         params: JSONObject, slotMap: [String: String], pageValues: JSONObject, webCheckout: @escaping () -> Bool,
         openWebCheckout: @escaping (String?) -> Bool, presentPlacement: @escaping (String) -> Void,
         customAction: ((String, [String: Any]) async -> [String: Any]?)?) {
        self.core = core
        self.controller = controller
        self.context = context
        self.html = Self.substituteParams(html, params)
        self.params = params
        self.slotMap = slotMap
        self.pageValues = pageValues
        self.webCheckout = webCheckout
        self.openWebCheckout = openWebCheckout
        self.presentPlacement = presentPlacement
        self.customAction = customAction
    }

    // MARK: Events

    func event(_ name: String, status: EventStatus = .info, _ props: JSONObject = [:]) {
        var all = context.properties
        all["paywall_session_id"] = .string(id)
        all["screen"] = .null
        for (k, v) in props { all[k] = v }
        core.track(name, status: status, properties: all)
    }

    func logDismissed(reason: String, result: String) {
        guard !dismissed else { return }
        dismissed = true
        let ms = shownAt.map { max(0, Int(core.now().timeIntervalSince($0) * 1000)) } ?? 0
        event("paywall_dismissed", ["close_reason": .string(reason), "result": .string(result), "time_on_paywall_ms": .int(ms)])
    }

    func logLoadFailed(stage: String, error: String) {
        event("paywall_load_failed", status: .failure, ["stage": .string(stage), "error": .string(error), "fallback_used": .bool(false)])
    }

    // MARK: The page

    /// `{{params.key}}` in the design, HTML-escaped (src/placements/params.ts).
    static func substituteParams(_ html: String, _ params: JSONObject) -> String {
        guard html.contains("{{") else { return html }
        let regex = try! NSRegularExpression(pattern: #"\{\{\s*params\.([A-Za-z0-9_\-]+)\s*\}\}"#)
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let key = ns.substring(with: m.range(at: 1))
            if let v = params[key], v != .null {
                out += PlacementRules.jsString(v)
                    .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                    .replacingOccurrences(of: "'", with: "&#39;")
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static let binder: String = {
        guard let url = Bundle.module.url(forResource: "binder", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    /// A JSON literal safe to put inside a script (`</script>` can't end it).
    static func literal<T: Encodable>(_ value: T) -> String {
        guard let data = JSON.data(value), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s.replacingOccurrences(of: "</", with: "<\\/").replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static let capabilities = ["purchase_result", "open_url", "custom_action", "set_attribute", "request_permission",
                               "present_placement", "haptic", "request_review"]

    func slots() -> [String: FicturaPackage] {
        func base(_ id: String) -> String { id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id }
        var out: [String: FicturaPackage] = [:]
        for (slot, productId) in slotMap {
            if let p = packages.first(where: { $0.product_id == productId }) ?? packages.first(where: { base($0.product_id) == base(productId) }) {
                out[slot] = p
            }
        }
        return out
    }

    var trialEligible: Bool? {
        let flags = packages.compactMap { $0.trial_days != nil ? $0.trial_eligible : nil }
        return flags.isEmpty ? nil : flags.contains(true)
    }

    /// Runs before the page's own scripts, so the design reads prices on its first paint.
    func injectedScript() -> String {
        let cfg = pageValues
        let send = "if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fictura) " +
            "window.webkit.messageHandlers.fictura.postMessage(JSON.stringify(m));"
        return """
        window.ReactNativeWebView = window.ReactNativeWebView || { postMessage: function (s) {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.fictura)
            window.webkit.messageHandlers.fictura.postMessage(typeof s === 'string' ? s : JSON.stringify(s));
        } };
        window.__FICTURA__ = {
          packages: \(Self.literal(packages)),
          slots: \(Self.literal(slots())),
          assets: \(Self.literal(cfg["assets"] ?? .object([:]))),
          copy: \(Self.literal(cfg["copy"] ?? .object([:]))),
          colors: \(Self.literal(cfg["colors"] ?? .object([:]))),
          ineligible_plans: \(Self.literal(cfg["ineligible_plans"] ?? .array([]))),
          legal: \(Self.literal(cfg["legal"] ?? .object(["termsUrl": .null, "privacyUrl": .null]))),
          trial_eligible: \(Self.literal(trialEligible.map { JSONValue.bool($0) } ?? .null)),
          placement: \(Self.literal(context.placement)),
          webCheckoutAvailable: \(webCheckout() ? "true" : "false"),
          device: \(Self.literal(cfg["device"] ?? .object([:]))),
          user: \(Self.literal(cfg["user"] ?? .object([:]))),
          params: \(Self.literal(params)),
          capabilities: \(Self.literal(Self.capabilities)),
          openUrl: function (url, mode) { this._send({ type: 'open_url', url: url, mode: mode }); },
          haptic: function (kind) { this._send({ type: 'haptic', kind: kind }); },
          requestReview: function () { this._send({ type: 'review' }); },
          setAttribute: function (key, value) { this._send({ type: 'set_attribute', key: key, value: value }); },
          presentPlacement: function (name) { this._send({ type: 'present_placement', placement: name }); },
          customAction: function (name, payload) { return this._call('custom_action', [name, payload]); },
          requestPermission: function (p) { return this._call('request_permission', [p]); },
          _calls: {}, _seq: 0,
          _call: function (name, args) {
            var self = this, id = 'c' + (++self._seq);
            return new Promise(function (resolve) {
              self._calls[id] = resolve;
              self._send({ type: 'call', id: id, name: name, args: args });
            });
          },
          _reply: function (id, value) { var r = this._calls[id]; delete this._calls[id]; if (r) r(value); },
          purchase: function (id) { this._send({ type: 'purchase', package_id: id }); },
          openWebCheckout: function (id) { this._send({ type: 'web_checkout', package_id: id }); },
          restore: function () { this._send({ type: 'restore' }); },
          close: function () { this._send({ type: 'close' }); },
          track: function (event, properties) { this._send({ type: 'track', event: event, properties: properties }); },
          _send: function (m) { \(send) }
        };
        \(Self.binder)
        window.__FICTURA__._send({ type: 'ready' });
        true;
        """
    }

    /// Prices that arrive after the page loaded still reach it.
    func packagesUpdateScript() -> String {
        """
        (function () { try {
          if (!window.__FICTURA__) return;
          window.__FICTURA__.packages = \(Self.literal(packages));
          window.__FICTURA__.slots = \(Self.literal(slots()));
          window.__FICTURA__.trial_eligible = \(Self.literal(trialEligible.map { JSONValue.bool($0) } ?? .null));
          if (typeof window.FICTURA_ON_PACKAGES === 'function') window.FICTURA_ON_PACKAGES();
          window.dispatchEvent(new Event('fictura:packages'));
          if (typeof window.__FICTURA__.bind === 'function') window.__FICTURA__.bind();
        } catch (e) {} })(); true;
        """
    }

    /// Loads prices from the purchase controller; tells the page when they land.
    func loadPackages() async {
        guard let controller else { return }
        let ids = Array(Set(slotMap.values)).sorted()
        let found = await controller.packages(for: ids)
        await MainActor.run {
            self.packages = found
            if self.ready { self.host?.evaluate(self.packagesUpdateScript()) }
        }
        reportProductsSeen(found)
    }

    private func reportProductsSeen(_ found: [FicturaPackage]) {
        guard !found.isEmpty else { return }
        let products: [JSONValue] = found.prefix(50).map {
            .object(["product_id": .string($0.product_id), "period": .string($0.period), "package_id": .string($0.id)])
        }
        let body = JSON.data(JSONValue.object(["platform": .string("ios"), "products": .array(products)]))
        if let r = core.api.request("api/v1/sdk/products-seen", method: "POST", body: body) { core.transport.send(r) { _ in } }
    }

    private func toPage(_ js: String) { host?.evaluate("(function(){try{\(js)}catch(e){}})();true;") }

    private func purchaseResult(_ status: String) {
        toPage("window.dispatchEvent(new CustomEvent('fictura:purchase_result',{detail:{status:\(Self.literal(status))}}));")
    }

    /// `paywall_shown` (the experiment exposure) fires once the paywall is on screen,
    /// as for a presented paywall in the React Native SDK, not when the page finishes loading.
    func markShown() {
        guard shownAt == nil else { return }
        shownAt = core.now()
        event("paywall_shown")
        onShown?()
    }

    // MARK: Messages from the page

    /// One message from `window.__FICTURA__._send`. Unknown types are ignored.
    func handle(_ raw: String) {
        guard let msg = JSON.parse(Data(raw.utf8))?.objectValue, let type = msg["type"]?.stringValue else { return }
        switch type {
        case "ready":
            if !ready {
                ready = true
                markShown()
                if !packages.isEmpty { host?.evaluate(packagesUpdateScript()) }
            }
        case "purchase": Task { await purchase(msg["package_id"]?.stringValue, path: "native") }
        case "web_checkout": Task { await purchase(msg["package_id"]?.stringValue, path: "web") }
        case "restore": Task { await restore() }
        case "close":
            logDismissed(reason: "manual", result: "declined")
            host?.closePaywall(result: .declined, reason: .manual)
        case "track":
            if let name = msg["event"]?.stringValue {
                let (mapped, props) = Self.webEvent(name, msg["properties"]?.objectValue ?? [:])
                event(mapped, props)
            }
        case "open_url":
            if let s = msg["url"]?.stringValue, Self.linkOk(s), let url = URL(string: s) {
                host?.open(url: url, inApp: msg["mode"]?.stringValue == "in_app" && s.lowercased().hasPrefix("http"))
            }
        case "haptic": host?.haptic(msg["kind"]?.stringValue ?? "light")
        case "review": host?.requestReview()
        case "set_attribute":
            if let key = msg["key"]?.stringValue, key.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil,
               let value = msg["value"] {
                switch value {
                case .string, .int, .double, .bool: core.setAttributes([key: value])
                default: break
                }
            }
        case "present_placement":
            if let name = msg["placement"]?.stringValue, name.range(of: "^[A-Za-z0-9_.:-]{1,64}$", options: .regularExpression) != nil {
                logDismissed(reason: "manual", result: "declined")
                host?.closePaywall(result: .declined, reason: .for_next_paywall)
                presentPlacement(name)
            }
        case "call":
            let callId = msg["id"]?.stringValue ?? ""
            let args = msg["args"]?.arrayValue ?? []
            let name = msg["name"]?.stringValue
            let reply: (JSONValue) -> Void = { [weak self] value in
                DispatchQueue.main.async { self?.toPage("window.__FICTURA__._reply(\(Self.literal(callId)),\(Self.literal(value)));") }
            }
            if name == "custom_action", let action = args.first?.stringValue, let customAction {
                let payload = (args.count > 1 ? args[1].objectValue : nil) ?? [:]
                Task {
                    let out = await customAction(action, payload.mapValues { $0.anyValue })
                    reply(Self.customAnswer(out))
                }
            } else if name == "request_permission", let p = args.first?.stringValue, let host {
                host.requestPermission(p) { reply(.bool($0)) }
            } else {
                reply(.bool(false))
            }
        default: break
        }
    }

    static func customAnswer(_ out: [String: Any]?) -> JSONValue {
        guard let out else { return .bool(false) }
        var values: JSONObject = [:]
        for (k, v) in (out["values"] as? [String: Any] ?? [:]).prefix(20)
        where k.range(of: "^[a-z][a-z0-9_]{0,39}$", options: .regularExpression) != nil {
            switch JSONValue(v) {
            case .string(let s): values[k] = .string(String(s.prefix(200)))
            case .int(let i): values[k] = .int(i)
            case .double(let d): values[k] = .double(d)
            case .bool(let b): values[k] = .bool(b)
            default: break
            }
        }
        return .object(["ok": .bool((out["ok"] as? Bool) != false), "values": .object(values)])
    }

    /// A link a paywall may open: the web or an app scheme, never script.
    static func linkOk(_ url: String) -> Bool {
        url.count <= 600 && url.range(of: "^[a-z][a-z0-9+.-]{1,30}:", options: [.regularExpression, .caseInsensitive]) != nil &&
            url.range(of: "^(javascript|data|vbscript|file|blob):", options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// Page events, namespaced like the React Native SDK (paywallEvents.ts webPaywallEvent).
    static func webEvent(_ name: String, _ props: JSONObject) -> (String, JSONObject) {
        var p = props
        switch name {
        case "paywall_screen_viewed", "paywall_page_viewed", "exit_offer_shown", "exit_offer_accepted", "exit_offer_declined":
            p["source"] = .string("web"); return (name, p)
        case "paywall_plan_selected", "paywall_product_selected":
            p["source"] = .string("web"); return ("paywall_product_selected", p)
        case "paywall_trial_toggled":
            p["component_type"] = .string("switch"); p["component_name"] = .string("trial_toggle"); p["source"] = .string("web")
            return ("paywall_interacted", p)
        default:
            return ("paywall_web_\(name)", props)
        }
    }

    // MARK: Purchase and restore

    @MainActor
    private func purchase(_ packageId: String?, path: String) async {
        let id = packageId ?? packages.first?.id
        event("paywall_cta_tapped", ["package_id": id.map { .string($0) } ?? .null, "path": .string(path)])
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if path == "web" || webCheckout() {
            if openWebCheckout(id) { return }
        }
        guard let controller, let id else { purchaseResult("failed"); return }
        guard let pkg = packages.first(where: { $0.id == id }) else { purchaseResult("failed"); return }
        let offerType: JSONValue = (pkg.trial_days != nil && pkg.trial_eligible != false) ? .string("free_trial") : .null
        let base: JSONObject = ["attempt_id": .string(IDs.uuidv4()), "product_id": .string(pkg.product_id), "package_id": .string(pkg.id)]
        event("purchase_started", base.merging(["offer_type": offerType]) { a, _ in a })
        let started = core.now()
        let ctx = FicturaPurchaseContext(placement: context.placement, paywallId: context.paywallId, campaignId: context.campaignId,
                                         audienceId: context.audienceId, experimentId: context.experimentId, variantId: context.variantId)
        let result = await controller.purchase(pkg, context: ctx)
        let latency = JSONValue.int(max(0, Int(core.now().timeIntervalSince(started) * 1000)))
        switch result {
        case .purchased(let tx, let periodType, let env):
            var props = base
            if let tx { props["transaction_id"] = .string(tx) }
            if let periodType { props["period_type"] = .string(periodType) }
            if let env { props["environment"] = .string(env) }
            props["price_local"] = .double(Double(pkg.price_micros) / 1_000_000)
            props["currency"] = .string(pkg.currency)
            props["is_trial"] = .bool(offerType != .null)
            props["latency_ms"] = latency
            event("purchase_completed", status: .success, props)
            purchaseResult("purchased")
            logDismissed(reason: "purchased", result: "purchased")
            host?.closePaywall(result: .purchased(productId: pkg.product_id), reason: .manual)
        case .cancelled, .pending:
            event("purchase_cancelled", base.merging(["latency_ms": latency]) { a, _ in a })
            purchaseResult("cancelled")
            onPurchaseCancelled?(pkg.id)
        case .failed(let error):
            event("purchase_failed", status: .failure, base.merging(["outcome": .string("unknown"), "error": .string(error), "latency_ms": latency]) { a, _ in a })
            purchaseResult("failed")
            onPurchaseFailed?(pkg.id, error)
        }
    }

    @MainActor
    private func restore() async {
        guard let controller else { return }
        event("restore_started")
        do {
            let restored = try await controller.restore()
            event("restore_completed", status: restored ? .success : .info, ["restored": .bool(restored)])
            if restored {
                host?.alert(title: "Purchases Restored", message: "Your subscription is active again.")
                logDismissed(reason: "restored", result: "restored")
                host?.closePaywall(result: .restored, reason: .manual)
            } else {
                host?.alert(title: "No Purchases Found", message: "We couldn't find an active subscription to restore.")
            }
        } catch {
            event("restore_failed", status: .failure, ["error": .string(error.localizedDescription)])
            host?.alert(title: "Restore Failed", message: "Something went wrong. Please try again.")
        }
    }
}
