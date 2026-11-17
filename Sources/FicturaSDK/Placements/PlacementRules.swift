import Foundation

/// Campaign rules, evaluated on the device exactly as the React Native SDK
/// does (src/placements/rules.ts). A missing field never matches, except for
/// `not_set`.
struct RuleContext {
    var user: JSONObject
    var seed: Int
    var isLoggedIn: Bool
    var params: JSONObject
    var eventName: String
    var device: JSONObject
    var serverCountry: String?
    var serverBillingState: String?
    var serverAttribution: JSONObject?
    /// Epoch milliseconds.
    var now: Double
    var occurrences: (String) -> [Double]
    var installedAt: Double?
}

enum PlacementRules {
    static let maxDepth = 3
    static let maxConditions = 25
    private static let minute = 60_000.0
    private static let hour = 60 * minute
    private static let day = 24 * hour
    private static let versionFields: Set<String> = ["device.app_version", "device.sdk_version"]

    /// A resolved value; nil means missing.
    static func resolve(_ field: String, _ ctx: RuleContext) -> JSONValue? {
        func own(_ obj: JSONObject?, _ key: String) -> JSONValue? {
            guard let v = obj?[key], v != .null else { return nil }
            return v
        }
        if field.isEmpty { return nil }
        if field == "event_name" { return ctx.eventName.isEmpty ? nil : .string(ctx.eventName) }
        if field == "user.seed" { return .int(ctx.seed) }
        if field == "user.is_logged_in" { return .bool(ctx.isLoggedIn) }
        if field.hasPrefix("user.") { return own(ctx.user, String(field.dropFirst(5))) }
        if field.hasPrefix("params.") { return own(ctx.params, String(field.dropFirst(7))) }
        if field.hasPrefix("device.") { return own(ctx.device, String(field.dropFirst(7))) }
        if field == "server.country" { return ctx.serverCountry.map { .string($0) } }
        if field == "server.billing_state" { return ctx.serverBillingState.map { .string($0) } }
        if field.hasPrefix("server.attribution.") { return own(ctx.serverAttribution, String(field.dropFirst(19))) }
        if field.hasPrefix("computed.") { return computed(String(field.dropFirst(9)), ctx) }
        return nil
    }

    private static func computed(_ path: String, _ ctx: RuleContext) -> JSONValue? {
        guard let dot = path.firstIndex(of: "."), dot != path.startIndex else { return nil }
        let kind = String(path[..<dot])
        let placement = String(path[path.index(after: dot)...])
        if placement.isEmpty { return nil }
        let times = ctx.occurrences(placement)
        let last = times.last
        func since(_ unit: Double) -> JSONValue? { last.map { .int(Int(((ctx.now - $0) / unit).rounded(.down))) } }
        func within(_ ms: Double) -> JSONValue { .int(times.filter { ctx.now - $0 <= ms }.count) }
        switch kind {
        case "minutes_since": return since(minute)
        case "hours_since": return since(hour)
        case "days_since": return since(day)
        case "placements_in_hour": return within(hour)
        case "placements_in_day": return within(day)
        case "placements_in_week": return within(7 * day)
        case "placements_in_month": return within(30 * day)
        case "placements_since_install":
            let from = ctx.installedAt ?? 0
            return .int(times.filter { $0 >= from }.count)
        default: return nil
        }
    }

    static func asNumber(_ v: JSONValue) -> Double? {
        switch v {
        case .int(let i): return Double(i)
        case .double(let d): return d.isFinite ? d : nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
            return Double(t)
        default: return nil
        }
    }

    static func asBool(_ v: JSONValue) -> Bool? {
        switch v {
        case .bool(let b): return b
        case .string("true"): return true
        case .string("false"): return false
        default: return nil
        }
    }

    /// JavaScript's String(v) for scalars.
    static func jsString(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        case .null: return "null"
        case .array(let a): return a.map(jsString).joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    private static func sameKind(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.string, .string), (.bool, .bool): return true
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double): return true
        default: return false
        }
    }

    static func looseEqual(_ actual: JSONValue, _ expected: JSONValue) -> Bool {
        if sameKind(actual, expected) {
            if let a = asNumberStrict(actual), let e = asNumberStrict(expected) { return a == e }
            return actual == expected
        }
        if let a = asNumber(actual), let e = asNumber(expected) { return a == e }
        if let a = asBool(actual), let e = asBool(expected) { return a == e }
        return jsString(actual) == jsString(expected)
    }

    private static func asNumberStrict(_ v: JSONValue) -> Double? {
        switch v {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    static func compareVersions(_ a: JSONValue, _ b: JSONValue) -> Int? {
        func parse(_ v: JSONValue) -> [Int]? {
            var s: String
            switch v {
            case .string(let x): s = x
            case .int, .double: s = jsString(v)
            default: return nil
            }
            s = s.trimmingCharacters(in: .whitespaces)
            if s.lowercased().hasPrefix("v") { s.removeFirst() }
            guard let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init), !core.isEmpty else { return nil }
            var out: [Int] = []
            for p in core.split(separator: ".", omittingEmptySubsequences: false) {
                guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
                out.append(n)
            }
            return out
        }
        guard let x = parse(a), let y = parse(b) else { return nil }
        for i in 0..<max(x.count, y.count) {
            let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
            if d != 0 { return d > 0 ? 1 : -1 }
        }
        return 0
    }

    private static func order(_ field: String, _ actual: JSONValue, _ expected: JSONValue) -> Int? {
        if versionFields.contains(field) { return compareVersions(actual, expected) }
        guard let a = asNumber(actual), let e = asNumber(expected) else { return nil }
        return a == e ? 0 : (a > e ? 1 : -1)
    }

    static func evaluateCondition(_ cond: JSONObject, _ ctx: RuleContext) -> Bool {
        guard let field = cond["field"]?.stringValue, let op = cond["operator"]?.stringValue else { return false }
        let actual = resolve(field, ctx)
        let value = cond["value"]
        switch op {
        case "is_set": return actual != nil
        case "not_set": return actual == nil
        case "is_true": return actual.flatMap(asBool) == true
        case "is_false": return actual.flatMap(asBool) == false
        default: break
        }
        guard let actual else { return false }
        let scalar: JSONValue? = {
            guard let value, value.arrayValue == nil else { return nil }
            return value
        }()
        switch op {
        case "eq": return scalar.map { looseEqual(actual, $0) } ?? false
        case "neq": return scalar.map { !looseEqual(actual, $0) } ?? false
        case "gt", "gte", "lt", "lte":
            guard let scalar, let c = order(field, actual, scalar) else { return false }
            switch op {
            case "gt": return c > 0
            case "gte": return c >= 0
            case "lt": return c < 0
            default: return c <= 0
            }
        case "contains", "not_contains":
            guard let scalar, case .string(let s) = actual else { return false }
            let hit = s.contains(jsString(scalar))
            return op == "contains" ? hit : !hit
        case "in", "not_in":
            guard let list = value?.arrayValue else { return false }
            let hit = list.contains { looseEqual(actual, $0) }
            return op == "in" ? hit : !hit
        default: return false
        }
    }

    private static func isRule(_ v: JSONValue) -> Bool { v["conditions"]?.arrayValue != nil }

    private static func measure(_ rule: JSONObject, depth: Int = 1) -> (depth: Int, conditions: Int) {
        var maxDepth = depth
        var count = 0
        for c in rule["conditions"]?.arrayValue ?? [] {
            if isRule(c), let sub = c.objectValue {
                let m = measure(sub, depth: depth + 1)
                maxDepth = max(maxDepth, m.depth)
                count += m.conditions
            } else {
                count += 1
            }
        }
        return (maxDepth, count)
    }

    private static func evalGroup(_ rule: JSONObject, _ ctx: RuleContext) -> Bool {
        let conditions = rule["conditions"]?.arrayValue ?? []
        if conditions.isEmpty { return true }
        let op = rule["op"]?.stringValue
        guard op == "and" || op == "or" else { return false }
        let results = conditions.map { c -> Bool in
            guard let obj = c.objectValue else { return false }
            return isRule(c) ? evalGroup(obj, ctx) : evaluateCondition(obj, ctx)
        }
        return op == "and" ? results.allSatisfy { $0 } : results.contains(true)
    }

    /// A missing rule matches everyone; a malformed or oversized one matches no one.
    static func evaluate(_ rule: JSONValue?, _ ctx: RuleContext) -> Bool {
        guard let rule, rule != .null else { return true }
        guard isRule(rule), let obj = rule.objectValue else { return false }
        let m = measure(obj)
        if m.depth > maxDepth || m.conditions > maxConditions { return false }
        return evalGroup(obj, ctx)
    }
}

/// Placement and audience occurrence history, for frequency limits and
/// `computed.*` rule fields (src/placements/occurrences.ts).
enum Occurrences {
    static let max = 500
    static let ttl: Double = 400 * 24 * 60 * 60 * 1000
    static func triggerKey(_ placement: String) -> String { "p:\(placement)" }
    static func audienceKey(_ id: String) -> String { "a:\(id)" }
    static let paywallViewKey = "pw"

    static func record(_ list: [Double]?, now: Double) -> [Double] {
        var kept = (list ?? []).filter { now - $0 <= ttl }
        kept.append(now)
        kept.sort()
        return kept.count > max ? Array(kept.suffix(max)) : kept
    }

    static func prune(_ map: [String: [Double]], now: Double) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        for (k, list) in map {
            let kept = list.filter { now - $0 <= ttl }.sorted()
            if !kept.isEmpty { out[k] = kept.count > max ? Array(kept.suffix(max)) : kept }
        }
        return out
    }

    static func countWithin(_ list: [Double]?, now: Double, minutes: Double?) -> Int {
        guard let list, !list.isEmpty else { return 0 }
        guard let minutes else { return list.count }
        let from = now - minutes * 60_000
        return list.filter { $0 > from }.count
    }

    static func limitAllows(_ limit: JSONValue?, _ list: [Double]?, now: Double) -> Bool {
        guard let limit, limit != .null else { return true }
        guard let maxCount = limit["occurrences"]?.doubleValue, maxCount >= 0 else { return false }
        let interval = limit["interval_minutes"]
        var minutes: Double?
        if let interval, interval != .null {
            guard let m = interval.doubleValue, m > 0 else { return false }
            minutes = m
        }
        return Double(countWithin(list, now: now, minutes: minutes)) < maxCount
    }
}
