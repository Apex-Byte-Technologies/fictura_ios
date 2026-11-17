import Foundation
import Security

/// Where the SDK keeps small values between launches. Files in Application
/// Support, one per key, so a large queue never slows UserDefaults down.
protocol KeyValueStore: AnyObject {
    func data(_ key: String) -> Data?
    func set(_ data: Data?, for key: String)
}

extension KeyValueStore {
    func string(_ key: String) -> String? { data(key).flatMap { String(data: $0, encoding: .utf8) } }
    func setString(_ value: String?, for key: String) { set(value.map { Data($0.utf8) }, for: key) }
    func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? { JSON.decode(type, from: data(key)) }
    func encode<T: Encodable>(_ value: T?, for key: String) { set(value.flatMap { JSON.data($0) }, for: key) }
}

final class FileStore: KeyValueStore {
    private let dir: URL
    private let lock = NSLock()

    /// `scope` keeps two API keys in one app apart (a staging and a production key).
    init(scope: String) {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("co.fictura", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
    }

    private func url(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return dir.appendingPathComponent(safe)
    }

    func data(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: url(key))
    }

    func set(_ data: Data?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        let u = url(key)
        if let data { try? data.write(to: u, options: [.atomic]) } else { try? FileManager.default.removeItem(at: u) }
    }
}

final class MemoryStore: KeyValueStore {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    init() {}
    func data(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ data: Data?, for key: String) { lock.lock(); defer { lock.unlock() }; values[key] = data }
}

/// Keychain items survive the app being deleted and reinstalled, which is what
/// keeps one device one user (the React Native SDK does the same).
protocol SecureStore: AnyObject {
    func read(service: String, account: String) -> String?
    func write(_ value: String, service: String, account: String) -> Bool
}

final class KeychainStore: SecureStore {
    init() {}

    func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

final class MemorySecureStore: SecureStore {
    private var values: [String: String] = [:]
    init() {}
    func read(service: String, account: String) -> String? { values["\(service)|\(account)"] }
    func write(_ value: String, service: String, account: String) -> Bool { values["\(service)|\(account)"] = value; return true }
}
