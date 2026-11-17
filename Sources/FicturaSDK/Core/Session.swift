import Foundation

/// Sessions, as the React Native SDK keeps them (src/session.ts): a UUIDv7 id
/// that ends after 30 minutes without an event, or 24 hours in all.
final class SessionTracker {
    static let defaultIdle: TimeInterval = 30 * 60
    static let minIdle: TimeInterval = 1
    static let maxLength: TimeInterval = 24 * 60 * 60
    private static let persistEvery: TimeInterval = 15

    struct State: Codable, Equatable {
        var id: String
        /// Epoch milliseconds, the same shape the React Native SDK stores.
        var startedAt: Double
        var lastActivityAt: Double
    }

    private let store: KeyValueStore
    private let key = "growth_session_v1"
    private let idle: TimeInterval
    private var state: State?
    private var lastPersist: Date = .distantPast
    var onChange: ((String) -> Void)?

    init(store: KeyValueStore, idle: TimeInterval?, now: Date = Date()) {
        self.store = store
        self.idle = max(Self.minIdle, idle ?? Self.defaultIdle)
        if let saved = store.decode(State.self, key), !expired(saved, now) { state = saved }
    }

    private func expired(_ s: State, _ now: Date) -> Bool {
        let ms = now.timeIntervalSince1970 * 1000
        return ms - s.lastActivityAt > idle * 1000 || ms - s.startedAt > Self.maxLength * 1000
    }

    @discardableResult
    private func start(_ now: Date) -> State {
        let ms = now.timeIntervalSince1970 * 1000
        let s = State(id: IDs.uuidv7(now), startedAt: ms, lastActivityAt: ms)
        state = s
        persist(force: true, now: now)
        onChange?(s.id)
        return s
    }

    /// The session an event at `now` belongs to; starts a new one when the last has ended.
    func idForEvent(at now: Date = Date()) -> String {
        var s = state.flatMap { expired($0, now) ? nil : $0 } ?? start(now)
        let ms = now.timeIntervalSince1970 * 1000
        if ms > s.lastActivityAt { s.lastActivityAt = ms }
        state = s
        persist(force: false, now: now)
        return s.id
    }

    /// The current session id, or nil if none is running.
    func currentId(now: Date = Date()) -> String? {
        guard let s = state, !expired(s, now) else { return nil }
        return s.id
    }

    /// True if the app comes back to an ended session (a new one starts on the next event).
    func hasEnded(now: Date = Date()) -> Bool { state.map { expired($0, now) } ?? true }

    func reset(now: Date = Date()) { start(now) }

    func persist(force: Bool = true, now: Date = Date()) {
        guard let state else { return }
        if !force && now.timeIntervalSince(lastPersist) < Self.persistEvery { return }
        lastPersist = now
        store.encode(state, for: key)
    }
}
