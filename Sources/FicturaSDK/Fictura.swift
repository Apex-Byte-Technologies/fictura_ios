import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Fictura for native iOS apps.
///
/// ```swift
/// import FicturaSDK
///
/// Fictura.configure(apiKey: "gk_...")
/// Fictura.track("photo_saved", properties: ["style": "modern"])
/// Fictura.register(placement: "export_hd") { exportHD() }
/// ```
public enum Fictura {
    private static let lock = NSLock()
    private static var instance: Instance?
    /// A purchase controller set before `configure`, handed to the instance when it starts.
    private static var earlyPurchaseController: FicturaPurchaseController?

    final class Instance {
        let core: FicturaCore
        let config: RemoteConfig
        let placements: Placements
        let errors: ErrorReporter
        let lifecycle: Lifecycle
        var purchaseController: FicturaPurchaseController?
        var customAction: ((String, [String: Any]) async -> [String: Any]?)?
        var onConversion: (([String: Any]) -> Void)?
        var screen: (name: String, at: Date)?
        #if canImport(UIKit) && canImport(WebKit)
        var presenter: UIKitPaywallPresenter?
        #endif

        init(core: FicturaCore, options: FicturaOptions) {
            self.core = core
            config = RemoteConfig(core: core)
            placements = Placements(core: core, config: config)
            errors = ErrorReporter(core: core, release: options.release, environment: options.environment,
                                   wrapper: options.wrapper?.header)
            var lc: Lifecycle!
            let placements = self.placements
            let config = self.config
            let errors = self.errors
            lc = Lifecycle(core: core, onForeground: {
                config.refresh()
                placements.onAppForeground()
                errors.send()
            }, onBackground: {
                placements.onAppBackground()
            })
            lifecycle = lc
        }
    }

    static var current: Instance? { lock.lock(); defer { lock.unlock() }; return instance }

    // MARK: Setup

    /// Starts Fictura. Call once, as early as possible (in `application(_:didFinishLaunchingWithOptions:)`
    /// or your SwiftUI `App.init`). `apiKey` is the app's publishable key (`gk_…`) from Fictura's Setup page.
    public static func configure(apiKey: String, options: FicturaOptions = FicturaOptions()) {
        configure(apiKey: apiKey, options: options, store: nil, keychain: nil, transport: nil)
    }

    static func configure(apiKey: String, options: FicturaOptions, store: KeyValueStore?, keychain: SecureStore?,
                          transport: Transport?, now: @escaping () -> Date = Date.init) {
        lock.lock()
        if instance != nil {
            lock.unlock()
            log("configure() was called twice; the first call wins.")
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = String(Hash.sha256Hex(key).prefix(12))
        let store = store ?? FileStore(scope: scope)
        let api = API(base: options.apiBase, apiKey: key, wrapper: options.wrapper?.header)
        let everyEvent = DeviceContext.everyEventProperties().merging(DeviceContext.wrapperProperties(options.wrapper)) { _, w in w }
        let core = FicturaCore(options: options, api: api, store: store, device: DeviceIdentity(keychain: keychain ?? KeychainStore()),
                               transport: transport ?? URLSessionTransport(), now: now, everyEvent: everyEvent)
        let inst = Instance(core: core, options: options)
        inst.purchaseController = earlyPurchaseController
        earlyPurchaseController = nil
        instance = inst
        lock.unlock()

        debug = options.debug
        core.onEventQueued = { [weak errors = inst.errors] name in errors?.addBreadcrumb(name) }
        core.onConversion = { data in
            let any = data.mapValues { $0.anyValue }
            DispatchQueue.main.async { Fictura.current?.onConversion?(any) }
        }
        inst.placements.purchaseController = { Fictura.current?.purchaseController ?? Fictura.defaultController }
        inst.config.extraQuery = { [:] }
        inst.config.applyCachedSettings()
        inst.config.refresh(force: true)
        if options.captureErrors {
            inst.errors.installUncaughtHandler()
            inst.errors.startMetricKit()
            inst.errors.send()
        }
        inst.lifecycle.launch(track: options.captureLifecycle)
        inst.placements.onAppLaunch(isFirstOpen: inst.lifecycle.isFirstOpen)
        #if canImport(UIKit) && canImport(WebKit)
        DispatchQueue.main.async {
            let presenter = UIKitPaywallPresenter(api: api, transport: core.transport) { request in
                Fictura.makeBridge(inst, request)
            }
            inst.presenter = presenter
            inst.placements.presenter = presenter
            if options.captureScreens {
                ScreenCapture.onScreen = { name, _ in Fictura.screen(name) }
                ScreenCapture.install()
            }
            if options.captureTaps {
                TapCapture.onTap = { props in
                    var p = props
                    let label = props["element_text"]?.stringValue ?? props["element_id"]?.stringValue
                    p["element"] = .string(label ?? "unlabeled")
                    p["component"] = props["element_type"] ?? .null
                    p["via"] = .string("press")
                    let screen = core.currentScreen
                    p["screen"] = .string(screen ?? "Home")
                    core.track("element_tapped", properties: p)
                }
                TapCapture.install()
            }
        }
        #endif
        log("configured \(SDKInfo.header)\(options.wrapper?.header.map { " (wrapped by \($0))" } ?? ""), device \(core.device.deviceId)")
    }

    #if canImport(StoreKit)
    private static let defaultController: FicturaPurchaseController? = {
        if #available(iOS 15, macOS 12, *) { return StoreKitPurchaseController() }
        return nil
    }()
    #else
    private static let defaultController: FicturaPurchaseController? = nil
    #endif

    static func makeBridge(_ inst: Instance, _ request: PresentRequest) -> PaywallBridge {
        let core = inst.core
        let config = inst.config
        var page: JSONObject = request.paywallConfig
        page["device"] = .object(inst.placements.deviceFields(now: core.now().timeIntervalSince1970 * 1000))
        page["user"] = .object(["id": (core.currentIds().accountId ?? core.masterUser).map { .string($0) } ?? .null,
                                "attributes": .object(core.allAttributes())])
        if let legal = legal { page["legal"] = .object(legal) }
        let ctx = PaywallEventContext(placement: request.info.placement, paywallId: request.info.paywallId,
                                      paywallVersion: request.paywallVersion, campaignId: request.info.campaignId,
                                      audienceId: request.info.audienceId, experimentId: request.info.experimentId,
                                      variantId: request.info.variantId, presentedBy: "placement")
        return PaywallBridge(
            core: core, controller: inst.purchaseController ?? defaultController, context: ctx, html: request.html,
            params: request.params, slotMap: config.products, pageValues: page,
            webCheckout: { config.webCheckout?["url"]?.stringValue != nil },
            openWebCheckout: { packageId in Fictura.openWebCheckout(packageId: packageId, context: ctx) },
            presentPlacement: { name in Fictura.register(placement: name) },
            customAction: inst.customAction)
    }

    // MARK: Events

    /// Records an event.
    public static func track(_ event: String, properties: [String: Any] = [:]) {
        current?.core.track(event, properties: JSONObject(any: properties))
    }

    /// Records a screen view (`screen_viewed`, and `screen_closed` for the one before).
    /// UIKit screens are recorded automatically; in SwiftUI use `.ficturaScreen("Name")`.
    public static func screen(_ name: String, properties: [String: Any] = [:]) {
        guard let inst = current else { return }
        let to = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, to != inst.screen?.name else { return }
        let now = inst.core.now()
        let from = inst.screen
        if let from {
            inst.core.track("screen_closed", properties: [
                "screen": .string(from.name), "to": .string(to),
                "duration_ms": .int(max(0, Int(now.timeIntervalSince(from.at) * 1000))), "$screen_name": .string(from.name),
            ])
        }
        inst.screen = (to, now)
        inst.core.setScreen(to)
        var props = JSONObject(any: properties)
        props["screen"] = .string(to)
        props["from"] = from.map { .string($0.name) } ?? .null
        props["$screen_name"] = .string(to)
        inst.core.track("screen_viewed", properties: props)
    }

    /// Properties added to every event from now on (kept between launches).
    public static func register(superProperties: [String: Any]) { current?.core.register(JSONObject(any: superProperties)) }
    public static func unregister(superProperty key: String) { current?.core.unregister(key) }

    /// Sends queued events now.
    public static func flush(completion: (() -> Void)? = nil) {
        guard let core = current?.core else { completion?(); return }
        core.flush { DispatchQueue.main.async { completion?() } }
    }

    // MARK: Users

    /// Links this device to your user id. Experiments follow the user to other devices.
    public static func identify(_ userId: String, attributes: [String: Any]? = nil) {
        guard let inst = current, let clean = FicturaCore.legalId(userId) else { return }
        inst.core.identify(accountId: clean)
        inst.placements.identify(clean)
        if let attributes { inst.core.setAttributes(JSONObject(any: attributes)) }
        inst.config.refresh(force: true)
    }

    /// Logs the user out. `newDevice: true` also gives this device a fresh id.
    public static func reset(newDevice: Bool = false) {
        guard let inst = current else { return }
        inst.core.logout(newDevice: newDevice)
        inst.placements.reset()
        inst.config.refresh(force: true)
    }

    /// The RevenueCat app user id, so RevenueCat's webhook revenue joins this user.
    /// Call it after `Purchases.configure` and after every RevenueCat `logIn`.
    public static func setRevenueCatUserId(_ id: String?) {
        current?.core.setRevenueCatId(id)
        current?.config.refresh(force: true)
    }

    /// User attributes for audiences and targeting (letters, digits and `_`; at most 100).
    public static func setAttributes(_ attributes: [String: Any]) { current?.core.setAttributes(JSONObject(any: attributes)) }
    public static func setOnce(_ attributes: [String: Any]) { current?.core.setOnce(JSONObject(any: attributes)) }
    public static func unsetAttribute(_ key: String) { current?.core.unsetAttribute(key) }

    /// Stops all capture, and drops what is queued. Remembered between launches.
    public static func optOut() { current?.core.setOptOut(true) }
    public static func optIn() { current?.core.setOptOut(false) }

    public static var deviceId: String? { current?.core.device.deviceId }
    public static var sessionId: String? { current.flatMap { $0.core.session.currentId(now: $0.core.now()) } }

    // MARK: Paywalls and placements

    /// How paywalls buy. Defaults to StoreKit 2. Set your own (for example a
    /// RevenueCat-backed one) before the first paywall shows, before or after `configure`.
    public static var purchaseController: FicturaPurchaseController? {
        get {
            lock.lock(); defer { lock.unlock() }
            return instance?.purchaseController ?? earlyPurchaseController
        }
        set {
            lock.lock(); defer { lock.unlock() }
            if let instance { instance.purchaseController = newValue } else { earlyPurchaseController = newValue }
        }
    }

    /// Your terms and privacy URLs, which paywall designs link to.
    public static var legal: JSONObject?
    public static func setLegalURLs(terms: URL?, privacy: URL?) {
        legal = ["termsUrl": terms.map { .string($0.absoluteString) } ?? .null,
                 "privacyUrl": privacy.map { .string($0.absoluteString) } ?? .null]
    }

    /// Answers a design's `customAction(name, payload)`. Return `["ok": true, "values": [...]]` or nil.
    public static func setCustomActionHandler(_ handler: @escaping (String, [String: Any]) async -> [String: Any]?) {
        current?.customAction = handler
    }

    /// Shows the paywall the dashboard set for this placement, if any, then runs
    /// `feature` unless a gated paywall was dismissed without a purchase.
    public static func register(placement: String, params: [String: Any]? = nil, handler: PlacementHandler? = nil,
                                feature: (() -> Void)? = nil) {
        guard let inst = current else { feature?(); return }
        inst.placements.register(placement, params: params, handler: handler, feature: feature)
    }

    /// What `register` would do now, without showing anything.
    public static func presentationResult(for placement: String, params: [String: Any]? = nil) async -> PresentationResult {
        guard let inst = current else { return .placementNotFound }
        return await withCheckedContinuation { cont in
            inst.placements.presentationResult(placement, params: params) { cont.resume(returning: $0) }
        }
    }

    /// Closes the paywall on screen, if one is.
    public static func dismissPaywall() { current?.placements.dismissPresented() }

    static func openWebCheckout(packageId: String?, context: PaywallEventContext) -> Bool {
        guard let inst = current, let s = inst.config.webCheckout?["url"]?.stringValue, let url = URL(string: s) else { return false }
        var props = context.properties
        props["package_id"] = packageId.map { .string($0) } ?? .null
        #if canImport(UIKit)
        DispatchQueue.main.async { UIApplication.shared.open(url) }
        inst.core.track("web_checkout_opened", properties: props)
        return true
        #else
        return false
        #endif
    }

    // MARK: Links and attribution

    /// Pass every URL that opens the app (deep links and universal links). Fictura
    /// reads its tracking-link and campaign parameters from it.
    @discardableResult
    public static func handle(url: URL) -> Bool {
        guard let inst = current else { return false }
        let params = Attribution.params(from: url)
        if let params {
            inst.core.setPendingAttribution(params, token: nil)
            if let click = params["growth_click_id"]?.stringValue { Attribution.claim(core: inst.core, clickId: click) }
        }
        return params != nil
    }

    /// Data the backend matched for this install (deferred deep links, campaign), once.
    public static func onConversion(_ callback: @escaping ([String: Any]) -> Void) { current?.onConversion = callback }

    // MARK: Errors

    /// Reports a handled error to Issues.
    public static func capture(_ error: Error, properties: [String: Any] = [:]) {
        current?.errors.capture(error, properties: properties)
    }

    /// Reports a message to Issues (`level`: info, warning, error, fatal).
    public static func captureMessage(_ message: String, level: String = "error") {
        current?.errors.captureMessage(message, level: level)
    }

    // MARK: Wrapping SDKs

    /// For SDKs that wrap this one, such as `fictura_flutter`. App code doesn't need these.
    public enum Wrapper {
        /// Reports an error raised in the wrapper's own language (a Dart exception), with
        /// its own type, message and stack text. `runtime` names that language (`dart`),
        /// so the backend reads the stack's frames. `level`: info, warning, error, fatal.
        public static func captureError(type: String, message: String?, stack: String?, handled: Bool = true,
                                        level: String = "error", mechanism: String = "manual", runtime: String,
                                        properties: [String: Any] = [:]) {
            current?.errors.captureForeign(type: type, message: message, stack: stack, level: level, handled: handled,
                                           mechanism: mechanism, runtime: runtime, properties: properties)
        }
    }

    // MARK: Debugging

    static var debug = false
    static func log(_ message: String) { if debug { print("[fictura] \(message)") } }

    /// For tests: forget the configured instance.
    static func resetForTesting() {
        lock.lock()
        instance = nil
        earlyPurchaseController = nil
        lock.unlock()
    }
}

/// Tracking-link and campaign parameters on an opening URL (src/attribution.ts).
enum Attribution {
    static func params(from url: URL) -> JSONObject? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func get(_ k: String) -> String? { items.first { $0.name == k }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        var out: JSONObject = [:]
        let map: [(String, String?)] = [
            ("link_slug", get("growth_slug")), ("utm_source", get("utm_source")), ("utm_medium", get("utm_medium")),
            ("utm_campaign", get("utm_campaign")), ("utm_content", get("utm_content")), ("utm_term", get("utm_term")),
            ("click_id", get("fbclid") ?? get("ttclid") ?? get("gclid")), ("growth_click_id", get("growth_click")),
        ]
        // The server checks these strictly and refuses the whole event batch over one bad
        // value, so a growth_click that is not a UUID is dropped and the rest are clamped.
        for (k, v) in map {
            guard let v else { continue }
            if k == "growth_click_id" && !isUUID(v) { continue }
            out[k] = .string(String(v.prefix(k == "click_id" ? 500 : 200)))
        }
        return out.isEmpty ? nil : out
    }

    static func isUUID(_ s: String) -> Bool {
        s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }

    static func claim(core: FicturaCore, clickId: String) {
        let ids = core.currentIds()
        var body: JSONObject = ["growth_click_id": .string(clickId)]
        body["revenuecat_id"] = ids.revenuecatId.map { .string($0) } ?? .null
        if let r = core.api.request("api/v1/attribution/claim", method: "POST", body: JSON.data(body),
                                    deviceId: ids.deviceId, accountId: ids.accountId) {
            core.transport.send(r) { _ in }
        }
    }
}
