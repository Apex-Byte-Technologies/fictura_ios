import Foundation

/// Limits and retry rules shared with the React Native SDK (src/delivery.ts).
enum Delivery {
    static let maxStringLength = 1024
    static let maxPropertyKeys = 255
    static let maxEventBytes = 64 * 1024
    static let maxBodyBytes = 500_000
    static let maxDepth = 8
    static let retryBase: TimeInterval = 1
    static let retryCap: TimeInterval = 5 * 60
    /// Events older than this when sent are dropped; the server clamps there too.
    static let maxEventAge: TimeInterval = 48 * 60 * 60
    static let requestTimeout: TimeInterval = 30

    /// Full jitter: a uniform draw in [0, min(cap, base·2^(attempt-1))).
    static func backoff(attempt: Int, random: Double = Double.random(in: 0..<1)) -> TimeInterval {
        let exp = min(retryCap, retryBase * pow(2, Double(max(0, min(attempt - 1, 30)))))
        let r = random.isFinite ? min(max(random, 0), 0.999999) : 0.5
        return (r * exp * 1000).rounded(.down) / 1000
    }

    /// Retry-After as seconds from `now`: delta-seconds or an HTTP date. Nil when unreadable.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if v.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil { return Double(v) }
        if v.range(of: #"^[-+]?[\d.]+$"#, options: .regularExpression) != nil { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let at = f.date(from: v) else { return nil }
        return max(0, at.timeIntervalSince(now))
    }

    static func truncate(_ s: String, max: Int = maxStringLength) -> String {
        // Counted in UTF-16 units like JavaScript, never cutting a surrogate pair in half.
        let units = Array(s.utf16)
        guard units.count > max else { return s }
        var cut = Array(units[0..<max])
        if let last = cut.last, (0xD800...0xDBFF).contains(last) { cut.removeLast() }
        return String(decoding: cut, as: UTF16.self)
    }

    private static func cap(_ v: JSONValue, depth: Int) -> JSONValue {
        switch v {
        case .string(let s): return .string(truncate(s))
        case .array(let a): return depth >= maxDepth ? .null : .array(a.map { cap($0, depth: depth + 1) })
        case .object(let o): return depth >= maxDepth ? .null : .object(o.mapValues { cap($0, depth: depth + 1) })
        default: return v
        }
    }

    /// Strings cut to 1024, at most 255 keys (`keepFirst` keys win), nesting cut at depth 8.
    static func capProperties(_ props: JSONObject, keepFirst: [String]) -> JSONObject {
        var out: JSONObject = [:]
        var order: [String] = []
        for k in keepFirst where props[k] != nil && !order.contains(k) { order.append(k) }
        for k in props.keys.sorted() where !order.contains(k) { order.append(k) }
        for k in order.prefix(maxPropertyKeys) {
            if let v = props[k] { out[truncate(k, max: 255)] = cap(v, depth: 1) }
        }
        return out
    }

    static func byteCount<T: Encodable>(_ value: T) -> Int? { JSON.data(value)?.count }
}
