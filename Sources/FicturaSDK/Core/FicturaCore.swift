import Foundation

/// The event pipeline: identity, attributes, the persistent queue and delivery.
/// Every piece of state lives on one serial queue (`work`).
final class FicturaCore {
    static let defaultBatch = 25
    static let defaultFlushInterval: TimeInterval = 4
    static let defaultMaxQueue = 1000
    static let maxAttributes = 100
    static let maxAttributeString = 1024
    /// Keys the SDK sets itself; they survive the 255-key cap first.
    static let sdkKeys = ["$session_id", "$seq", "$screen_name", "$sample_rate", "$network_type"]

    let options: FicturaOptions
    let api: API
    let store: KeyValueStore
    let device: DeviceIdentity
    let session: SessionTracker
    let transport: Transport
    let work = DispatchQueue(label: "co.fictura.core")
    let now: () -> Date
    private let random: () -> Double

    private var queue: [QueuedEvent] = []
    private var inflight: Set<String> = []
    private var dropped: [String: Int] = [:]
    private var seq = 0
    private var accountId: String?
    private var revenuecatId: String?
    private var superProperties: JSONObject = [:]
    private var userContext: JSONObject = [:]
    private var attributes = AttributeState()
    private var screen: String?
    private var masterUserId: String?
    private var disabledEvents: Set<String> = []
    private var sampleRates: [String: Double] = [:]
    private var optedOut = false
    private var attempt = 0
    private var retryTimer: DispatchSourceTimer?
    private var batchOverride: Int?
    private var flushTimer: DispatchSourceTimer?
    private var writeScheduled = false
    private var sending = false
    private var waiters: [() -> Void] = []
    private var pendingAttribution: JSONObject?
    private var attributionToken: String?
    private let everyEvent: JSONObject

    /// The batch that settles first-launch attribution carries the conversion data back.
    var onConversion: ((JSONObject) -> Void)?
    /// Called on `work` after every accepted event (auto-capture uses it to know the app did something).
    var onEventQueued: ((String) -> Void)?

    init(options: FicturaOptions, api: API, store: KeyValueStore, device: DeviceIdentity, transport: Transport,
         now: @escaping () -> Date = Date.init, random: @escaping () -> Double = { Double.random(in: 0..<1) },
         everyEvent: JSONObject = DeviceContext.everyEventProperties()) {
        self.options = options
        self.api = api
        self.store = store
        self.device = device
        self.transport = transport
        self.now = now
        self.random = random
        self.everyEvent = everyEvent
        session = SessionTracker(store: store, idle: options.sessionIdleTimeout, now: now())
        restore()
    }

    // MARK: Persistence

    private struct Identity: Codable { var accountId: String?; var revenuecatId: String?; var masterUserId: String? }

    private func restore() {
        queue = store.decode([QueuedEvent].self, "queue_v1") ?? []
        dropped = store.decode([String: Int].self, "dropped_v1") ?? [:]
        seq = Int(store.string("seq_v1") ?? "") ?? 0
        if let id = store.decode(Identity.self, "identity_v1") {
            accountId = id.accountId
            revenuecatId = id.revenuecatId
            masterUserId = id.masterUserId
        }
        superProperties = store.decode(JSONObject.self, "super_v1") ?? [:]
        attributes = store.decode(AttributeState.self, "attributes_v1") ?? AttributeState()
        optedOut = store.string("optout_v1") == "1"
        pendingAttribution = store.decode(JSONObject.self, "attribution_v1")
        if optedOut { queue = [] }
    }

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        work.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.writeNow() }
    }

    /// Writes the queue and counters now (also before the app is suspended).
    func writeNow() {
        dispatchPrecondition(condition: .onQueue(work))
        writeScheduled = false
        store.encode(queue, for: "queue_v1")
        store.encode(dropped, for: "dropped_v1")
        store.setString(String(seq), for: "seq_v1")
        session.persist()
    }

    private func saveIdentity() {
        store.encode(Identity(accountId: accountId, revenuecatId: revenuecatId, masterUserId: masterUserId), for: "identity_v1")
    }

    // MARK: Identity

    var ids: EventIds { EventIds(deviceId: device.deviceId, accountId: accountId, revenuecatId: revenuecatId) }

    func currentIds() -> EventIds { work.sync { ids } }

    func identify(accountId: String?) {
        work.async {
            let clean = accountId.flatMap { Self.legalId($0) }
            guard clean != self.accountId else { return }
            self.accountId = clean
            self.saveIdentity()
        }
    }

    func setRevenueCatId(_ id: String?) {
        work.async {
            let clean = id.flatMap { Self.legalId($0) }
            guard clean != self.revenuecatId else { return }
            self.revenuecatId = clean
            self.saveIdentity()
        }
    }

    /// Placeholder ids (`guest`, `null`, `0`, …) would merge every user who shares them.
    static func legalId(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.count < 2 || v.count > 255 { return nil }
        let illegal: Set<String> = ["guest", "null", "undefined", "none", "nil", "anonymous", "unknown", "0", "-1", "user", "test", "[object object]", "nan"]
        return illegal.contains(v.lowercased()) ? nil : v
    }

    func logout(newDevice: Bool) {
        work.async {
            self.accountId = nil
            self.revenuecatId = nil
            self.masterUserId = nil
            self.saveIdentity()
            self.superProperties = [:]
            self.store.encode(self.superProperties, for: "super_v1")
            self.userContext = [:]
            self.attributes = AttributeState(version: self.attributes.version + 1)
            self.store.encode(self.attributes, for: "attributes_v1")
            if newDevice { self.device.rotate() }
            self.session.reset(now: self.now())
        }
    }

    var masterUser: String? { work.sync { masterUserId } }

    // MARK: Properties and attributes

    func register(_ props: JSONObject) {
        work.async {
            for (k, v) in props { self.superProperties[k] = v }
            self.store.encode(self.superProperties, for: "super_v1")
        }
    }

    func unregister(_ key: String) {
        work.async {
            self.superProperties.removeValue(forKey: key)
            self.store.encode(self.superProperties, for: "super_v1")
        }
    }

    func setUserContext(_ props: JSONObject) { work.async { self.userContext = props } }

    private static func attrKeyOk(_ k: String) -> Bool {
        !k.hasPrefix("$") && k.range(of: "^[A-Za-z0-9_]{1,40}$", options: .regularExpression) != nil
    }

    private static func attrValueOk(_ v: JSONValue) -> Bool {
        switch v {
        case .bool, .int: return true
        case .double(let d): return d.isFinite
        case .string(let s): return s.utf16.count <= maxAttributeString
        default: return false
        }
    }

    private func roomFor(_ k: String) -> Bool {
        if attributes.set[k] != nil || attributes.setOnce[k] != nil { return true }
        return attributes.set.count + attributes.setOnce.count < Self.maxAttributes
    }

    private func attributesChanged() {
        attributes.dirty = true
        attributes.version += 1
        store.encode(attributes, for: "attributes_v1")
    }

    func setAttributes(_ attrs: JSONObject) {
        work.async {
            var changed = false
            for (k, v) in attrs where Self.attrKeyOk(k) && Self.attrValueOk(v) && self.roomFor(k) {
                if let i = self.attributes.pendingUnset.firstIndex(of: k) { self.attributes.pendingUnset.remove(at: i); changed = true }
                if self.attributes.setOnce.removeValue(forKey: k) != nil {
                    self.attributes.pendingOnce.removeAll { $0 == k }
                    changed = true
                }
                if self.attributes.set[k] != v { self.attributes.set[k] = v; changed = true }
            }
            if changed { self.attributesChanged() }
        }
    }

    func setOnce(_ attrs: JSONObject) {
        work.async {
            var changed = false
            for (k, v) in attrs where Self.attrKeyOk(k) && Self.attrValueOk(v) {
                if self.attributes.set[k] != nil || self.attributes.setOnce[k] != nil || !self.roomFor(k) { continue }
                if let i = self.attributes.pendingUnset.firstIndex(of: k) {
                    self.attributes.pendingUnset.remove(at: i)
                    self.attributes.set[k] = v
                } else {
                    self.attributes.setOnce[k] = v
                    self.attributes.pendingOnce.append(k)
                }
                changed = true
            }
            if changed { self.attributesChanged() }
        }
    }

    func unsetAttribute(_ key: String) {
        work.async {
            guard Self.attrKeyOk(key) else { return }
            self.attributes.set.removeValue(forKey: key)
            self.attributes.setOnce.removeValue(forKey: key)
            self.attributes.pendingOnce.removeAll { $0 == key }
            if !self.attributes.pendingUnset.contains(key) { self.attributes.pendingUnset.append(key) }
            self.attributesChanged()
        }
    }

    func allAttributes() -> JSONObject {
        work.sync { attributes.setOnce.merging(attributes.set) { _, new in new } }
    }

    // MARK: Config from the dashboard

    func applyEventSettings(disabled: Set<String>, sampleRates: [String: Double]) {
        work.async {
            self.disabledEvents = disabled
            self.sampleRates = sampleRates
        }
    }

    func setOptOut(_ out: Bool) {
        work.async {
            self.optedOut = out
            self.store.setString(out ? "1" : nil, for: "optout_v1")
            if out {
                self.queue.removeAll()
                self.scheduleWrite()
            }
        }
    }

    var isOptedOut: Bool { work.sync { optedOut } }

    // MARK: Screens

    func setScreen(_ name: String?) { work.async { self.screen = name } }
    var currentScreen: String? { work.sync { screen } }

    // MARK: Attribution

    /// First-touch campaign params ride along on batches until the backend acks one.
    func setPendingAttribution(_ params: JSONObject, token: String?) {
        work.async {
            guard self.pendingAttribution == nil, !params.isEmpty else { return }
            self.pendingAttribution = params
            self.attributionToken = token
            self.store.encode(params, for: "attribution_v1")
        }
    }

    // MARK: Events

    /// Records an event. Thread-safe; returns at once.
    func track(_ name: String, status: EventStatus = .info, properties: JSONObject = [:], at: Date? = nil) {
        let at = at ?? now()
        work.async { self.enqueue(name, status: status, properties: properties, at: at) }
    }

    private func drop(_ reason: String, _ n: Int = 1) {
        guard n > 0 else { return }
        dropped[reason, default: 0] += n
        scheduleWrite()
    }

    private func enqueue(_ name: String, status: EventStatus, properties: JSONObject, at: Date) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !optedOut else { return }
        if disabledEvents.contains(name) { return }
        let rate = sampleRates[name]
        let deviceId = device.deviceId
        if let rate, !Sampling.keep(deviceId: deviceId, event: name, rate: rate) { return }

        var merged = everyEvent
        let network = NetworkWatcher.shared.type
        merged["$network_type"] = .string(network)
        for (k, v) in superProperties { merged[k] = v }
        for (k, v) in userContext { merged[k] = v }
        for (k, v) in properties { merged[k] = v }
        if properties["$screen_name"] == nil {
            if let screen { merged["$screen_name"] = .string(screen) } else { merged.removeValue(forKey: "$screen_name") }
        }
        merged["$session_id"] = .string(session.idForEvent(at: at))
        if let rate, rate < 1 { merged["$sample_rate"] = .double(rate) }
        merged["$seq"] = .int(0)

        if let sanitize = options.sanitizeProperties { merged = JSONObject(any: sanitize(name, merged.mapValues { $0.anyValue })) }

        let keepFirst = Self.sdkKeys + Array(everyEvent.keys) + Array(properties.keys)
        var capped = Delivery.capProperties(merged, keepFirst: keepFirst)
        var event = QueuedEvent(event_name: name, status: status, properties: capped, uuid: IDs.uuidv4(),
                                timestamp: ISO8601.string(at), size: 0, ids: ids)
        if let beforeSend = options.beforeSend {
            guard let kept = beforeSend(FicturaEvent(name: event.event_name, properties: capped.mapValues { $0.anyValue })) else { return }
            event.event_name = kept.name
            capped = Delivery.capProperties(JSONObject(any: kept.properties).merging(["$seq": .int(0)]) { a, _ in a }, keepFirst: keepFirst)
        }
        seq += 1
        capped["$seq"] = .int(seq)
        event.properties = capped
        guard let size = Delivery.byteCount(event.wire) else { drop("unserializable"); return }
        guard size <= Delivery.maxEventBytes else { drop("oversized"); return }
        event.size = size
        queue.append(event)
        trimQueue()
        scheduleWrite()
        onEventQueued?(name)
        if queue.count - inflight.count >= maxBatch { flushOnWork(nil) }
        ensureTimer()
    }

    private var maxBatch: Int { max(1, options.maxBatchSize ?? Self.defaultBatch) }
    private var maxQueue: Int { max(1, options.maxQueueSize ?? Self.defaultMaxQueue) }
    private var batchLimit: Int { batchOverride.map { min($0, maxBatch) } ?? maxBatch }

    private func trimQueue() {
        var over = queue.count - maxQueue
        guard over > 0 else { return }
        let n = over
        queue.removeAll { e in
            if over > 0 && !inflight.contains(e.uuid) { over -= 1; return true }
            return false
        }
        drop("queue_full", n - over)
    }

    private func ensureTimer() {
        guard flushTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: work)
        let interval = options.flushInterval ?? Self.defaultFlushInterval
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.flushOnWork(nil) }
        t.resume()
        flushTimer = t
    }

    var pendingCount: Int { work.sync { queue.count } }

    // MARK: Delivery

    /// Sends everything queued; `completion` runs when the queue is empty or a retry is scheduled.
    func flush(completion: (() -> Void)? = nil) {
        work.async { self.flushOnWork(completion) }
    }

    private func flushOnWork(_ completion: (() -> Void)?) {
        if let completion { waiters.append(completion) }
        if sending { return }
        if retryTimer != nil { finishWaiters(); return }
        sending = true
        sendNext()
    }

    private func finishWaiters() {
        let w = waiters
        waiters = []
        w.forEach { $0() }
    }

    private enum Step { case again, done, stop }

    private func sendNext() {
        pruneExpired()
        guard let first = queue.first(where: { !inflight.contains($0.uuid) }) else { return settle(.done) }
        let pinned = first.ids
        let current = pinned == ids
        let attribution = current ? pendingAttribution : nil
        let attrs = current ? attributePayload() : nil
        let reported = dropped
        let total = reported.values.reduce(0, +)
        var batch = EventBatch(
            revenuecat_id: pinned.revenuecatId, attribution: attribution,
            attributes: attrs?.set, attributes_set_once: attrs?.setOnce, attributes_unset: attrs?.unset,
            platform: "ios", app_version: DeviceContext.appVersion(), country: DeviceContext.country(),
            client_dropped: total > 0 ? total : nil, client_dropped_reasons: total > 0 ? reported : nil,
            sent_at: ISO8601.string(now()), events: [])
        var budget = Delivery.maxBodyBytes - (Delivery.byteCount(batch) ?? 0)
        var picked: [QueuedEvent] = []
        for e in queue where !inflight.contains(e.uuid) {
            if picked.count >= batchLimit || e.ids != pinned { break }
            if !picked.isEmpty && e.size + 1 > budget { break }
            budget -= e.size + 1
            picked.append(e)
        }
        guard !picked.isEmpty else { return settle(.done) }
        batch.events = picked.map { $0.wire }
        let uuids = Set(picked.map { $0.uuid })
        inflight = uuids
        guard let body = JSON.data(batch),
              var request = api.request("api/v1/events/log", method: "POST", body: body,
                                        deviceId: pinned.deviceId, accountId: pinned.accountId) else {
            inflight = []
            return settle(.done)
        }
        if let token = attributionToken, attribution != nil { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        transport.send(request) { [weak self] result in
            guard let self else { return }
            self.work.async { self.handle(result, uuids: uuids, reported: reported, attribution: attribution, attrs: attrs, current: current) }
        }
    }

    private func handle(_ result: HTTPResult, uuids: Set<String>, reported: [String: Int], attribution: JSONObject?,
                        attrs: AttributePayload?, current: Bool) {
        inflight = []
        guard let status = result.status else {
            // Kept with the same uuids, so a batch the server stored before the connection dropped is deduped there.
            scheduleRetry(Delivery.backoff(attempt: attempt + 1, random: random()))
            return settle(.stop)
        }
        if !(200..<300).contains(status) {
            if status == 429 || status >= 500 {
                if let after = Delivery.retryAfter(result.header("retry-after"), now: now()) {
                    scheduleRetry(min(max(after, 1), Delivery.retryCap))
                } else {
                    scheduleRetry(Delivery.backoff(attempt: attempt + 1, random: random()))
                }
                return settle(.stop)
            }
            if status == 413 {
                if uuids.count > 1 { batchOverride = max(1, uuids.count / 2) } else { remove(uuids); drop("oversized") }
                return settle(.again)
            }
            // Any other 4xx is a verdict on the batch itself; re-sending it would loop forever.
            remove(uuids)
            drop("rejected_4xx", uuids.count)
            return settle(.again)
        }
        remove(uuids)
        for (k, n) in reported { dropped[k] = max(0, (dropped[k] ?? 0) - n); if dropped[k] == 0 { dropped.removeValue(forKey: k) } }
        attempt = 0
        if let o = batchOverride { batchOverride = o * 2 >= maxBatch ? nil : o * 2 }
        let data = JSON.parse(result.body)
        if attribution != nil {
            pendingAttribution = nil
            attributionToken = nil
            store.set(nil, for: "attribution_v1")
        }
        if current, let conversion = data?["conversion"]?.objectValue { onConversion?(conversion) }
        if let attrs { attributesAcked(attrs) }
        if current, let id = data?["master_user_id"]?.stringValue, !id.isEmpty, id != masterUserId {
            masterUserId = id
            saveIdentity()
        }
        settle(.again)
    }

    private func settle(_ step: Step) {
        switch step {
        case .again: sendNext()
        case .done, .stop:
            sending = false
            finishWaiters()
        }
    }

    private func remove(_ uuids: Set<String>) {
        queue.removeAll { uuids.contains($0.uuid) }
        scheduleWrite()
    }

    private func pruneExpired() {
        let cutoff = now().addingTimeInterval(-Delivery.maxEventAge)
        let before = queue.count
        queue.removeAll { e in !inflight.contains(e.uuid) && (ISO8601.date(e.timestamp).map { $0 < cutoff } ?? false) }
        drop("expired", before - queue.count)
    }

    private func scheduleRetry(_ delay: TimeInterval) {
        attempt += 1
        retryTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: work)
        t.schedule(deadline: .now() + delay)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.retryTimer?.cancel()
            self.retryTimer = nil
            self.flushOnWork(nil)
        }
        t.resume()
        retryTimer = t
    }

    struct AttributePayload {
        var version: Int
        var set: JSONObject?
        var setOnce: JSONObject?
        var unset: [String]?
    }

    private func attributePayload() -> AttributePayload? {
        guard attributes.dirty, !optedOut else { return nil }
        let once = attributes.pendingOnce.reduce(into: JSONObject()) { out, k in if let v = attributes.setOnce[k] { out[k] = v } }
        let p = AttributePayload(version: attributes.version,
                                 set: attributes.set.isEmpty ? nil : attributes.set,
                                 setOnce: once.isEmpty ? nil : once,
                                 unset: attributes.pendingUnset.isEmpty ? nil : attributes.pendingUnset)
        return (p.set == nil && p.setOnce == nil && p.unset == nil) ? nil : p
    }

    private func attributesAcked(_ sent: AttributePayload) {
        if sent.version == attributes.version {
            attributes.dirty = false
            attributes.pendingOnce = []
            attributes.pendingUnset = []
        } else {
            for (k, v) in sent.setOnce ?? [:] where attributes.setOnce[k] == v { attributes.pendingOnce.removeAll { $0 == k } }
        }
        store.encode(attributes, for: "attributes_v1")
    }

    /// For tests: wait until everything queued so far has been processed.
    func sync() { work.sync {} }
}
