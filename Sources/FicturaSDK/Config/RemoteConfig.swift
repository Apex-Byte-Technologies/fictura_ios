import Foundation

/// GET /api/v1/sdk/config: tools, kill switches, sampling, paywalls,
/// placements and experiments. Cached on disk so a cold start offline still
/// has the last config; refreshed every 5 minutes and when the app returns.
final class RemoteConfig {
    static let refreshInterval: TimeInterval = 5 * 60
    static let retryInterval: TimeInterval = 10

    private let core: FicturaCore
    private let lock = NSLock()
    private var payload: JSONObject = [:]
    private var etag: String?
    private var fetchedAt: Date?
    private var lastAttempt: Date?
    private var inFlight = false
    private var waiters: [(Bool) -> Void] = []
    private(set) var source = "none" // network | cache | none
    /// Extra query items (`rc_active`, preview).
    var extraQuery: () -> [String: String?] = { [:] }
    var onUpdate: ((JSONObject) -> Void)?

    init(core: FicturaCore) {
        self.core = core
        if let cached = core.store.decode(JSONObject.self, "config_v1") {
            payload = cached
            source = "cache"
            etag = core.store.string("config_etag_v1")
        }
    }

    var current: JSONObject { lock.lock(); defer { lock.unlock() }; return payload }
    var hasConfig: Bool { lock.lock(); defer { lock.unlock() }; return source != "none" }

    // MARK: Reading

    /// A tool is on unless the dashboard switched it off (`tools[key] == false`).
    func isToolEnabled(_ key: String) -> Bool { current["tools"]?[key]?.boolValue != false }

    var disabledEvents: Set<String> { Set((current["disabled_events"]?.arrayValue ?? []).compactMap { $0.stringValue }) }

    var sampling: [String: Double] {
        (current["sampling"]?.objectValue ?? [:]).compactMapValues { $0.doubleValue }
    }

    /// Slot name → store product id, for this platform.
    var products: [String: String] { (current["products"]?.objectValue ?? [:]).compactMapValues { $0.stringValue } }

    var paywalls: JSONObject { current["paywalls"]?.objectValue ?? [:] }
    var webCheckout: JSONObject? { current["web_checkout"]?.objectValue }
    var entitlement: JSONObject? { current["entitlement"]?.objectValue }
    var tracing: JSONObject? { current["tracing"]?.objectValue }
    var autocapture: JSONObject? { current["autocapture"]?.objectValue }

    // MARK: Fetching

    /// Refreshes when stale (or always with `force`); `completion(true)` once a config is available.
    func refresh(force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        lock.lock()
        let now = core.now()
        let fresh = fetchedAt.map { now.timeIntervalSince($0) < Self.refreshInterval } ?? false
        let tooSoon = lastAttempt.map { now.timeIntervalSince($0) < Self.retryInterval } ?? false
        if !force && (fresh || (tooSoon && !inFlight)) {
            let has = source != "none"
            lock.unlock()
            completion?(has)
            return
        }
        if let completion { waiters.append(completion) }
        if inFlight { lock.unlock(); return }
        inFlight = true
        lastAttempt = now
        let tag = etag
        lock.unlock()

        let ids = core.currentIds()
        var query: [String: String?] = [
            "sv": String(SDKInfo.paywallSchema),
            "cv": String(SDKInfo.configContract),
            "device_id": ids.deviceId,
            "revenuecat_id": ids.revenuecatId,
            "account_id": ids.accountId,
            "platform": "ios",
            "app_version": DeviceContext.appVersion(),
            "country": DeviceContext.country(),
            "locale": DeviceContext.locale(),
        ]
        for (k, v) in extraQuery() { query[k] = v }
        guard var request = core.api.request("api/v1/sdk/config", query: query, deviceId: ids.deviceId, accountId: ids.accountId) else {
            finish(ok: false)
            return
        }
        request.timeoutInterval = 10
        if let tag { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        core.transport.send(request) { [weak self] result in
            guard let self else { return }
            if result.status == 304 {
                self.lock.lock(); self.fetchedAt = self.core.now(); self.lock.unlock()
                return self.finish(ok: true)
            }
            guard result.ok, let obj = JSON.parse(result.body)?.objectValue else { return self.finish(ok: false) }
            self.apply(obj, etag: result.header("etag"))
            self.finish(ok: true)
        }
    }

    /// Sets the config (from the network, or from tests).
    func apply(_ obj: JSONObject, etag: String? = nil) {
        lock.lock()
        payload = obj
        source = "network"
        fetchedAt = core.now()
        self.etag = etag
        lock.unlock()
        core.store.encode(obj, for: "config_v1")
        core.store.setString(etag, for: "config_etag_v1")
        core.applyEventSettings(disabled: disabledEvents, sampleRates: sampling)
        onUpdate?(obj)
    }

    private func finish(ok: Bool) {
        lock.lock()
        inFlight = false
        let w = waiters
        waiters = []
        let has = source != "none"
        lock.unlock()
        if !ok && has { core.applyEventSettings(disabled: disabledEvents, sampleRates: sampling) }
        w.forEach { $0(has) }
    }

    /// Applies the cached config's kill switches before the first fetch answers.
    func applyCachedSettings() {
        if hasConfig { core.applyEventSettings(disabled: disabledEvents, sampleRates: sampling) }
    }
}
