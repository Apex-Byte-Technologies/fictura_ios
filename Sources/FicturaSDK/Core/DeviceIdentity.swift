import Foundation

/// The device id: `ios-<uuid>`, kept in the Keychain so it survives reinstalls.
///
/// An app rewritten from React Native keeps its users: the React Native SDK
/// stored the same id through expo-secure-store under the key
/// `growth_device_id` (service `app:no-auth`, or `app` on older Expo), and that
/// item is read first.
final class DeviceIdentity {
    static let account = "growth_device_id"
    static let resetAccount = "growth_device_id_reset"
    static let service = "co.fictura.device"
    /// Where expo-secure-store kept it.
    static let legacyServices = ["app:no-auth", "app"]

    private let keychain: SecureStore
    private let lock = NSLock()
    private var cached: String?

    init(keychain: SecureStore) {
        self.keychain = keychain
    }

    var deviceId: String {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let id = resolve()
        cached = id
        return id
    }

    private func resolve() -> String {
        // Fictura.reset(newDevice: true) wrote a fresh id that wins over everything.
        for service in [Self.service] + Self.legacyServices {
            if let v = keychain.read(service: service, account: Self.resetAccount), Self.isValid(v) { return v }
        }
        if let v = keychain.read(service: Self.service, account: Self.account), Self.isValid(v) { return v }
        for service in Self.legacyServices {
            if let v = keychain.read(service: service, account: Self.account), Self.isValid(v) {
                _ = keychain.write(v, service: Self.service, account: Self.account)
                return v
            }
        }
        let fresh = "ios-\(IDs.uuidv4())"
        if !keychain.write(fresh, service: Self.service, account: Self.account) {
            // No Keychain (a broken entitlement): an id for this run only. The
            // backend merges it into the real user once any known id appears.
            return "tmp-\(IDs.uuidv4())"
        }
        return fresh
    }

    /// A new id that replaces the current one from now on (a shared test device,
    /// or a user who asked to be forgotten).
    @discardableResult
    func rotate() -> String {
        lock.lock(); defer { lock.unlock() }
        let fresh = "ios-\(IDs.uuidv4())"
        _ = keychain.write(fresh, service: Self.service, account: Self.resetAccount)
        cached = fresh
        return fresh
    }

    static func isValid(_ id: String) -> Bool { !id.isEmpty && id.count <= 128 }

    static let firstOpenAccount = "growth_first_open_done"

    /// Whether this device ever opened the app before, across reinstalls.
    func firstOpenDone() -> Bool {
        ([Self.service] + Self.legacyServices).contains { keychain.read(service: $0, account: Self.firstOpenAccount) != nil }
    }

    func markFirstOpenDone() { _ = keychain.write("1", service: Self.service, account: Self.firstOpenAccount) }
}
