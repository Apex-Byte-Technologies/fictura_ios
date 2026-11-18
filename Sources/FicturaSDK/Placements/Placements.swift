import Foundation

/// What `Fictura.register(placement:)` did, for the app's handler.
public enum PlacementSkipReason: String {
    case holdout, no_audience_match, placement_not_found, placement_paused, user_is_subscribed
}

public struct PaywallInfo {
    public var paywallId: String
    public var placement: String
    public var campaignId: String?
    public var audienceId: String?
    public var experimentId: String?
    public var variantId: String?
    /// gated: the feature runs only after a purchase or restore.
    public var featureGating: String
    public var presentationStyle: String
    public var closeReason: String?
}

/// Callbacks for one `register` call. All optional; called on the main thread.
public struct PlacementHandler {
    public var onPresent: ((PaywallInfo) -> Void)?
    public var onDismiss: ((PaywallInfo, PaywallResult) -> Void)?
    public var onSkip: ((PlacementSkipReason) -> Void)?
    public var onError: ((Error) -> Void)?

    public init(onPresent: ((PaywallInfo) -> Void)? = nil, onDismiss: ((PaywallInfo, PaywallResult) -> Void)? = nil,
                onSkip: ((PlacementSkipReason) -> Void)? = nil, onError: ((Error) -> Void)? = nil) {
        self.onPresent = onPresent
        self.onDismiss = onDismiss
        self.onSkip = onSkip
        self.onError = onError
    }
}

public struct FicturaError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public var description: String { code }
}

/// What a placement would do right now, without showing anything.
public enum PresentationResult: Equatable {
    case paywall(paywallId: String?, experimentId: String?, variantId: String?)
    case holdout(experimentId: String?, variantId: String?)
    case noAudienceMatch, placementNotFound, placementPaused, paywallNotAvailable
}

/// A paywall the presenter is asked to show.
struct PresentRequest {
    var id: Int
    var info: PaywallInfo
    var html: String
    var paywallVersion: Int?
    var paywallConfig: JSONObject
    var params: JSONObject
    var delay: TimeInterval
    var onShown: () -> Void
    var onClose: (PaywallResult, CloseReason) -> Void
    var onPurchaseCancelled: (String) -> Void
    var onPurchaseFailed: (String, String) -> Void
}

/// Shows paywalls on screen (the UIKit presenter on iOS; a fake in tests).
protocol PaywallPresenting: AnyObject {
    func show(_ request: PresentRequest)
    func hide(_ id: Int)
}

/// The placement runtime (src/placements/runtime.ts): register a placement,
/// decide with the engine, record occurrences and assignments, confirm them
/// with the server, and present.
final class Placements {
    static let nameRule = "^[a-z0-9_]{1,64}$"
    static let noChainFrom: Set<String> = ["paywall_decline", "transaction_abandon", "transaction_fail"]
    static let nextPaywallGap: TimeInterval = 0.4
    static let sessionTimeout: TimeInterval = 60 * 60
    static let maxParamKeys = 50
    static let maxParamString = 200
    static let confirmMax = 25

    struct State: Codable {
        var seed: Int
        var userId: String?
        var installedAt: Double
        var occurrences: [String: [Double]] = [:]
        var assignments: [String: PlacementEngine.StoredAssignment] = [:]
        var pendingConfirms: [ConfirmItem] = []
        var lastCloseAt: Double?
    }

    struct ConfirmItem: Codable, Equatable {
        var audience_id: String
        var variant_id: String
        var placement: String
    }

    private let core: FicturaCore
    private let config: RemoteConfig
    private let work = DispatchQueue(label: "co.fictura.placements")
    private var state: State
    private var tentative: [String: String] = [:]
    private(set) var createdThisLaunch = false
    private var firstAppOpen = false
    private var confirming = false
    private var observed: [String: Set<String>] = [:]
    private var observeQueue: [String: Set<String>] = [:]
    private var nextId = 1
    private var active: (id: Int, closed: Bool)?
    weak var presenter: PaywallPresenting?
    var purchaseController: () -> FicturaPurchaseController? = { nil }
    var random: () -> Double = { Double.random(in: 0..<1) }

    init(core: FicturaCore, config: RemoteConfig) {
        self.core = core
        self.config = config
        let nowMs = core.now().timeIntervalSince1970 * 1000
        if let saved = core.store.decode(State.self, "placements_v1") {
            state = saved
            state.occurrences = Occurrences.prune(saved.occurrences, now: nowMs)
        } else {
            state = State(seed: Int.random(in: 0..<100), userId: nil, installedAt: nowMs)
            createdThisLaunch = true
        }
    }

    private func save() { core.store.encode(state, for: "placements_v1") }
    private var nowMs: Double { core.now().timeIntervalSince1970 * 1000 }

    // MARK: Identity

    /// sha256(userId) folded mod 100, as the React Native SDK (sha256.ts seedForUser).
    static func seed(forUser userId: String) -> Int {
        var r = 0
        for b in Hash.sha256(userId) { r = (r * 256 + Int(b)) % 100 }
        return r
    }

    func identify(_ userId: String) {
        work.async {
            guard self.state.userId != userId else { return }
            self.state.userId = userId
            self.state.seed = Self.seed(forUser: userId)
            self.state.assignments = [:]
            self.save()
            self.restoreServerAssignments()
        }
    }

    func reset() {
        work.async {
            self.state = State(seed: Int.random(in: 0..<100), userId: nil, installedAt: self.state.installedAt)
            self.tentative = [:]
            self.save()
        }
    }

    private func restoreServerAssignments() {
        let ids = core.currentIds()
        guard let r = core.api.request("api/v1/assignments", query: ["revenuecat_id": ids.revenuecatId],
                                       deviceId: ids.deviceId, accountId: ids.accountId) else { return }
        core.transport.send(r) { [weak self] result in
            guard let self, result.ok, let list = JSON.parse(result.body)?["assignments"]?.arrayValue else { return }
            self.work.async {
                for a in list.compactMap({ $0.objectValue }) {
                    guard let aud = a["audience_id"]?.stringValue, let v = a["variant_id"]?.stringValue else { continue }
                    self.state.assignments[aud] = .init(variant_id: v, experiment_id: a["experiment_id"]?.stringValue,
                                                        placement: a["placement"]?.stringValue, confirmed: true)
                }
                self.save()
            }
        }
    }

    // MARK: Params

    static func sanitize(_ input: [String: Any]?) -> JSONObject {
        var out: JSONObject = [:]
        for key in (input ?? [:]).keys.sorted() {
            if out.count >= maxParamKeys { break }
            guard !key.isEmpty, !key.hasPrefix("$"), let raw = input?[key] else { continue }
            switch JSONValue(raw) {
            case .string(let s): out[key] = .string(String(s.utf16.prefix(maxParamString)) ?? String(s.prefix(maxParamString)))
            case .int(let i): out[key] = .int(i)
            case .double(let d): out[key] = .double(d)
            case .bool(let b): out[key] = .bool(b)
            default: continue
            }
        }
        return out
    }

    // MARK: Evaluation

    private func engineInput(_ placement: String, _ params: JSONObject, subscribed: Bool) -> PlacementEngine.Input {
        let cfg = config.current
        let uc = cfg["user_context"]?.objectValue
        let hint = uc?["seed_hint"]?.intValue
        let seed = state.userId == nil && hint.map { $0 >= 0 && $0 < 100 } == true ? hint! : state.seed
        var assignments: [String: PlacementEngine.StoredAssignment] = [:]
        for (aud, v) in tentative { assignments[aud] = .init(variant_id: v) }
        for (k, v) in state.assignments { assignments[k] = v }
        let now = nowMs
        let ctx = RuleContext(
            user: core.allAttributes(), seed: seed, isLoggedIn: state.userId != nil || core.currentIds().accountId != nil,
            params: params, eventName: placement, device: deviceFields(now: now),
            serverCountry: uc?["country"]?.stringValue, serverBillingState: uc?["billing_state"]?.stringValue,
            serverAttribution: uc?["attribution"]?.objectValue, now: now, occurrences: { _ in [] }, installedAt: state.installedAt)
        return PlacementEngine.Input(config: cfg, placement: placement, params: params, now: now, subscribed: subscribed,
                                     context: ctx, occurrences: state.occurrences, assignments: assignments, random: random)
    }

    /// Rule fields under `device.` (src/placements/deviceFields.ts).
    func deviceFields(now: Double) -> JSONObject {
        let ev = DeviceContext.everyEventProperties()
        var out: JSONObject = ["platform": .string("ios"), "sdk_version": .string(SDKInfo.version)]
        for (k, src) in [("app_version", "$app_version"), ("app_build", "$app_build"), ("os_version", "$os_version"),
                         ("device_model", "$device_model"), ("locale", "$locale")] {
            if let v = ev[src] { out[k] = v }
        }
        let locale = Locale.current
        if let lang = locale.languageCode { out["language"] = .string(lang) }
        if let region = DeviceContext.country() { out["region"] = .string(region) }
        if let currency = locale.currencyCode { out["currency"] = .string(currency) }
        let date = Date(timeIntervalSince1970: now / 1000)
        out["timezone_offset"] = .int(TimeZone.current.secondsFromGMT(for: date) / 60)
        let cal = Calendar.current
        out["local_hour"] = .int(cal.component(.hour, from: date))
        out["local_weekday"] = .int(cal.component(.weekday, from: date) - 1)
        let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        out["uses_24h_clock"] = .bool(!fmt.contains("a"))
        if let w = ev["$screen_width"] { out["screen_width"] = w }
        if let h = ev["$screen_height"] { out["screen_height"] = h }
        if let w = ev["$screen_width"]?.doubleValue, let h = ev["$screen_height"]?.doubleValue { out["is_tablet"] = .bool(min(w, h) >= 600) }
        out["is_low_power"] = .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)
        out["minutes_since_install"] = .int(Int(((now - state.installedAt) / 60_000).rounded(.down)))
        out["days_since_install"] = .int(Int(((now - state.installedAt) / 86_400_000).rounded(.down)))
        let views = state.occurrences[Occurrences.paywallViewKey] ?? []
        out["total_paywall_views"] = .int(views.count)
        if let last = views.last { out["days_since_last_paywall_view"] = .int(Int(((now - last) / 86_400_000).rounded(.down))) }
        #if DEBUG
        out["is_sandbox"] = .bool(true)
        #else
        out["is_sandbox"] = .bool(false)
        #endif
        out["is_first_app_open"] = .bool(firstAppOpen)
        return out
    }

    /// The legacy path: a config without a placements block answers from `paywalls[placement]`.
    private func legacy(_ placement: String) -> PlacementEngine.Resolution {
        guard let entry = config.paywalls[placement]?.objectValue, let id = entry["id"]?.stringValue else {
            var r = PlacementEngine.Resolution(.placement_not_found)
            r.skipReason = "placement_not_found"
            return r
        }
        var r = PlacementEngine.Resolution(.paywall)
        r.paywallId = id
        r.paywall = entry
        return r
    }

    func evaluate(_ placement: String, _ params: JSONObject, subscribed: Bool) -> PlacementEngine.Resolution {
        if !config.isToolEnabled("paywalls") {
            var r = PlacementEngine.Resolution(.placement_paused)
            r.skipReason = "placement_paused"
            return r
        }
        guard PlacementEngine.hasPlacementsBlock(config.current) else { return legacy(placement) }
        let r = PlacementEngine.resolve(engineInput(placement, params, subscribed: subscribed))
        if let a = r.assignment, a.from == "random" { tentative[a.audienceId] = a.variantId }
        // A placement no campaign runs still shows the paywall set live for it on the
        // Paywalls page (the backend serves it as `paywalls[placement]` for the same reason).
        if r.type == .placement_not_found, config.paywalls[placement] != nil { return legacy(placement) }
        return r
    }

    private func commit(_ r: PlacementEngine.Resolution, _ placement: String, _ params: JSONObject) {
        state.occurrences[Occurrences.triggerKey(placement)] = Occurrences.record(state.occurrences[Occurrences.triggerKey(placement)], now: nowMs)
        if let a = r.assignment {
            tentative.removeValue(forKey: a.audienceId)
            let item = ConfirmItem(audience_id: a.audienceId, variant_id: a.variantId, placement: a.placement)
            if let local = state.assignments[a.audienceId], local.variant_id == a.variantId {
                if local.confirmed != true, !state.pendingConfirms.contains(item) { state.pendingConfirms.append(item) }
            } else {
                state.assignments[a.audienceId] = .init(variant_id: a.variantId, experiment_id: a.experimentId,
                                                        placement: a.placement, confirmed: a.from == "server")
                if a.from != "server" { state.pendingConfirms.append(item) }
            }
        }
        save()
        flushConfirms()
        func opt(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
        var props: JSONObject = [
            "placement": .string(placement), "result": .string(r.type.rawValue), "campaign_id": opt(r.campaignId),
            "audience_id": opt(r.audienceId), "experiment_id": opt(r.experimentId), "variant_id": opt(r.variantId),
            "paywall_id": opt(r.paywallId), "params": .object(params),
        ]
        for (id, why) in r.unmatched { props["unmatched_\(id)"] = .string(why) }
        core.track("placement_triggered", properties: props)
    }

    private func presentationRequest(_ placement: String, _ status: String, _ reason: String?) {
        core.track("paywall_presentation_request", properties: [
            "placement": .string(placement), "status": .string(status), "status_reason": reason.map { .string($0) } ?? .null,
        ])
    }

    private func recordAudience(_ id: String) {
        let key = Occurrences.audienceKey(id)
        state.occurrences[key] = Occurrences.record(state.occurrences[key], now: nowMs)
        state.occurrences[Occurrences.paywallViewKey] = Occurrences.record(state.occurrences[Occurrences.paywallViewKey], now: nowMs)
        save()
    }

    // MARK: Confirms and observation

    func flushConfirms() {
        guard !confirming, !state.pendingConfirms.isEmpty else { return }
        confirming = true
        let items = Array(state.pendingConfirms.prefix(Self.confirmMax))
        let ids = core.currentIds()
        var body: JSONObject = ["assignments": .array(items.map {
            .object(["audience_id": .string($0.audience_id), "variant_id": .string($0.variant_id), "placement": .string($0.placement)])
        })]
        if let rc = ids.revenuecatId { body["revenuecat_id"] = .string(rc) }
        guard let r = core.api.request("api/v1/assignments/confirm", method: "POST", body: JSON.data(body),
                                       deviceId: ids.deviceId, accountId: ids.accountId) else { confirming = false; return }
        core.transport.send(r) { [weak self] result in
            guard let self else { return }
            self.work.async {
                self.confirming = false
                guard result.ok else { return }
                self.state.pendingConfirms.removeAll { items.contains($0) }
                for ack in JSON.parse(result.body)?["assignments"]?.arrayValue ?? [] {
                    guard ack["status"]?.stringValue == "kept", let aud = ack["audience_id"]?.stringValue,
                          let v = ack["variant_id"]?.stringValue, var local = self.state.assignments[aud], local.variant_id != v else { continue }
                    local.variant_id = v
                    local.confirmed = true
                    self.state.assignments[aud] = local
                }
                for item in items { self.state.assignments[item.audience_id]?.confirmed = true }
                self.save()
                if !self.state.pendingConfirms.isEmpty { self.flushConfirms() }
            }
        }
    }

    private func observe(_ name: String, _ keys: [String]) {
        guard name.range(of: Self.nameRule, options: .regularExpression) != nil else { return }
        let fresh = Set(keys).subtracting(observed[name] ?? [])
        if observed[name] != nil && fresh.isEmpty { return }
        observed[name, default: []].formUnion(keys)
        observeQueue[name, default: []].formUnion(keys)
        work.asyncAfter(deadline: .now() + 2) { [weak self] in self?.flushObserve() }
    }

    func flushObserve() {
        guard !observeQueue.isEmpty else { return }
        let batch = observeQueue.prefix(50)
        observeQueue = [:]
        let ids = core.currentIds()
        var body: JSONObject = ["placements": .array(batch.map {
            .object(["name": .string($0.key), "params_keys": .array($0.value.sorted().prefix(100).map { .string($0) })])
        })]
        if let rc = ids.revenuecatId { body["revenuecat_id"] = .string(rc) }
        if let r = core.api.request("api/v1/placements/observe", method: "POST", body: JSON.data(body),
                                    deviceId: ids.deviceId, accountId: ids.accountId) {
            core.transport.send(r) { _ in }
        }
    }

    // MARK: The flow

    enum Outcome {
        case skipped(PlacementSkipReason)
        case dismissed(PaywallResult, CloseReason, String)
        case error(FicturaError)
    }

    static func shouldRunFeature(_ o: Outcome) -> Bool {
        switch o {
        case .skipped: return true
        case .error: return false
        case .dismissed(let result, let reason, let gating):
            if case .purchased = result { return true }
            if result == .restored { return true }
            if reason == .for_next_paywall { return false }
            return gating != "gated"
        }
    }

    private func subscribed(_ completion: @escaping (Bool) -> Void) {
        guard let controller = purchaseController() else {
            completion(config.entitlement?["is_active"]?.boolValue == true)
            return
        }
        Task {
            let v = await controller.isSubscribed()
            completion(v)
        }
    }

    /// `Fictura.register`: decide, present if a paywall applies, then run `feature` per gating.
    func register(_ placement: String, params rawParams: [String: Any]?, handler: PlacementHandler?, feature: (() -> Void)?,
                  implicit: Bool = false) {
        let params = Self.sanitize(rawParams)
        work.async {
            if !implicit { self.observe(placement, Array(params.keys)) }
        }
        let finish: (Outcome, PaywallInfo?) -> Void = { outcome, info in
            DispatchQueue.main.async {
                switch outcome {
                case .skipped(let reason): handler?.onSkip?(reason)
                case .dismissed(let result, let reason, let gating):
                    if let info { handler?.onDismiss?(info, result) }
                    if reason == .webview_failed && gating == "gated" { handler?.onError?(FicturaError(code: "webview_failed")) }
                case .error(let e): handler?.onError?(e)
                }
                if let feature, Self.shouldRunFeature(outcome) { feature() }
            }
        }
        config.refresh { [weak self] hasConfig in
            guard let self else { return }
            guard hasConfig else {
                if implicit { return }
                self.presentationRequest(placement, "timeout", "no_config")
                return finish(.error(FicturaError(code: "no_config")), nil)
            }
            self.subscribed { isSubscribed in
                self.work.async {
                    if implicit && (self.config.current["placements"]?[placement] == nil || self.active != nil) { return }
                    let r = self.evaluate(placement, params, subscribed: isSubscribed)
                    self.commit(r, placement, params)
                    switch r.type {
                    case .paywall:
                        if self.active != nil {
                            self.presentationRequest(placement, "no_presentation", "paywall_already_presented")
                            return finish(.error(FicturaError(code: "paywall_already_presented")), nil)
                        }
                        guard self.presenter != nil else {
                            self.presentationRequest(placement, "no_presentation", "no_presenter")
                            return finish(.error(FicturaError(code: "no_presenter")), nil)
                        }
                        self.presentationRequest(placement, "presentation", nil)
                        self.present(r, placement: placement, params: params, handler: handler, finish: finish)
                    case .paywall_not_available:
                        self.presentationRequest(placement, "no_presentation", "paywall_not_available")
                        finish(.error(FicturaError(code: "paywall_not_available")), nil)
                    case .holdout:
                        if let a = r.audienceId { self.recordAudience(a) }
                        self.presentationRequest(placement, "no_presentation", "holdout")
                        finish(.skipped(.holdout), nil)
                    default:
                        let reason = PlacementSkipReason(rawValue: r.skipReason ?? "") ?? .no_audience_match
                        self.presentationRequest(placement, "no_presentation", reason.rawValue)
                        finish(.skipped(reason), nil)
                    }
                }
            }
        }
    }

    private func present(_ r: PlacementEngine.Resolution, placement: String, params: JSONObject, handler: PlacementHandler?,
                         finish: @escaping (Outcome, PaywallInfo?) -> Void) {
        let pw = r.paywall ?? [:]
        let cfg = pw["config"]?.objectValue ?? [:]
        var info = PaywallInfo(paywallId: r.paywallId ?? "", placement: placement, campaignId: r.campaignId, audienceId: r.audienceId,
                               experimentId: r.experimentId, variantId: r.variantId,
                               featureGating: pw["feature_gating"]?.stringValue ?? "non_gated",
                               presentationStyle: pw["presentation_style"]?.stringValue ?? "fullscreen")
        let id = nextId
        nextId += 1
        active = (id, false)
        var shown = false
        let close: (PaywallResult, CloseReason) -> Void = { [weak self] result, reason in
            guard let self else { return }
            self.work.async {
                guard let a = self.active, a.id == id, !a.closed else { return }
                self.active = nil
                DispatchQueue.main.async { self.presenter?.hide(id) }
                info.closeReason = reason.rawValue
                finish(.dismissed(result, reason, info.featureGating), info)
                // A declined paywall can hand over to the paywall_decline placement.
                if result == .declined && reason == .manual && !Self.noChainFrom.contains(placement) {
                    self.work.asyncAfter(deadline: .now() + Self.nextPaywallGap) {
                        self.register("paywall_decline", params: ["paywall_id": info.paywallId, "source_placement": placement],
                                      handler: nil, feature: nil, implicit: true)
                    }
                }
            }
        }
        let request = PresentRequest(
            id: id, info: info, html: cfg["html"]?.stringValue ?? "", paywallVersion: pw["version"]?.intValue,
            paywallConfig: cfg, params: params, delay: max(0, (pw["presentation_delay_ms"]?.doubleValue ?? 0) / 1000),
            onShown: { [weak self] in
                guard let self, !shown else { return }
                shown = true
                self.work.async { if let a = r.audienceId { self.recordAudience(a) } }
                DispatchQueue.main.async { handler?.onPresent?(info) }
            },
            onClose: close,
            onPurchaseCancelled: { [weak self] pkg in
                self?.chain("transaction_abandon", info: info, packageId: pkg, error: nil)
            },
            onPurchaseFailed: { [weak self] pkg, error in
                self?.chain("transaction_fail", info: info, packageId: pkg, error: error)
            })
        DispatchQueue.main.async { self.presenter?.show(request) }
    }

    private func chain(_ name: String, info: PaywallInfo, packageId: String, error: String?) {
        guard !Self.noChainFrom.contains(info.placement), config.current["placements"]?[name] != nil else { return }
        var params: [String: Any] = ["paywall_id": info.paywallId, "source_placement": info.placement, "product_id": packageId]
        if let error { params["error"] = error }
        work.asyncAfter(deadline: .now() + Self.nextPaywallGap) {
            self.register(name, params: params, handler: nil, feature: nil, implicit: true)
        }
    }

    /// Dismisses the paywall on screen, if any.
    func dismissPresented() {
        work.async {
            guard let a = self.active else { return }
            self.active = nil
            DispatchQueue.main.async { self.presenter?.hide(a.id) }
        }
    }

    func presentationResult(_ placement: String, params: [String: Any]?, completion: @escaping (PresentationResult) -> Void) {
        config.refresh { [weak self] has in
            guard let self, has else { return completion(.placementNotFound) }
            self.subscribed { sub in
                self.work.async {
                    let r = self.evaluate(placement, Self.sanitize(params), subscribed: sub)
                    switch r.type {
                    case .paywall: completion(.paywall(paywallId: r.paywallId, experimentId: r.experimentId, variantId: r.variantId))
                    case .holdout: completion(.holdout(experimentId: r.experimentId, variantId: r.variantId))
                    case .no_audience_match: completion(.noAudienceMatch)
                    case .placement_not_found: completion(.placementNotFound)
                    case .placement_paused: completion(.placementPaused)
                    case .paywall_not_available: completion(.paywallNotAvailable)
                    }
                }
            }
        }
    }

    // MARK: App lifecycle

    func onAppLaunch(isFirstOpen: Bool) {
        work.async {
            self.firstAppOpen = isFirstOpen
            let last = self.state.lastCloseAt
            let sessionStart = last == nil || self.nowMs - last! > Self.sessionTimeout * 1000
            if isFirstOpen { self.register("app_install", params: nil, handler: nil, feature: nil, implicit: true) }
            self.register("app_launch", params: nil, handler: nil, feature: nil, implicit: true)
            if sessionStart { self.register("session_start", params: nil, handler: nil, feature: nil, implicit: true) }
        }
    }

    func onAppBackground() {
        work.async {
            self.state.lastCloseAt = self.nowMs
            self.save()
            self.flushObserve()
            self.flushConfirms()
        }
    }

    func onAppForeground() {
        work.async {
            if let last = self.state.lastCloseAt, self.nowMs - last > Self.sessionTimeout * 1000 {
                self.register("session_start", params: nil, handler: nil, feature: nil, implicit: true)
            }
        }
    }

    /// For tests.
    func sync() { work.sync {} }
    var snapshot: State { work.sync { state } }
}
