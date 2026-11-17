import Foundation
import CryptoKit

enum IDs {
    /// A random v4 UUID in lower case, as the React Native SDK writes them.
    static func uuidv4() -> String { UUID().uuidString.lowercased() }

    /// A v7 UUID: 48 bits of Unix milliseconds, then random bits. Sorts by time.
    static func uuidv7(_ date: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - i))) & 0xff) }
        var random = [UInt8](repeating: 0, count: 10)
        if SecRandomCopyBytes(kSecRandomDefault, random.count, &random) != errSecSuccess {
            for i in 0..<random.count { random[i] = UInt8.random(in: 0...255) }
        }
        for i in 0..<10 { bytes[6 + i] = random[i] }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return format(bytes)
    }

    static func format(_ b: [UInt8]) -> String {
        let hex = b.map { String(format: "%02x", $0) }.joined()
        let s = Array(hex)
        return "\(String(s[0..<8]))-\(String(s[8..<12]))-\(String(s[12..<16]))-\(String(s[16..<20]))-\(String(s[20..<32]))"
    }
}

enum Hash {
    static func sha256(_ string: String) -> [UInt8] { Array(SHA256.hash(data: Data(string.utf8))) }

    static func sha256Hex(_ string: String) -> String { sha256(string).map { String(format: "%02x", $0) }.joined() }

    /// The first 4 bytes of sha256(input) as a big-endian unsigned integer.
    static func first32(_ string: String) -> UInt32 {
        let d = sha256(string)
        return (UInt32(d[0]) << 24) | (UInt32(d[1]) << 16) | (UInt32(d[2]) << 8) | UInt32(d[3])
    }
}

/// Dashboard sampling: is this device in or out for this event, for good.
/// Same as the React Native SDK (src/sampling.ts): bucket = first 4 bytes of
/// sha256("<device_id>:<event>") / 2^32, kept when bucket < rate.
enum Sampling {
    static func bucket(deviceId: String, event: String) -> Double {
        Double(Hash.first32("\(deviceId):\(event)")) / 4_294_967_296.0
    }

    static func keep(deviceId: String?, event: String, rate: Double) -> Bool {
        if !(rate < 1) { return true }
        if !(rate > 0) { return false }
        guard let deviceId, !deviceId.isEmpty else { return true }
        return bucket(deviceId: deviceId, event: event) < rate
    }
}
