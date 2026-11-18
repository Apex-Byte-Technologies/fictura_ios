import Foundation

/// A JSON value. Event properties, attributes and config are kept in this form
/// so they can be stored on disk and sent exactly as they were given.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Converts a Swift value (String, numbers, Bool, Date, URL, arrays, dictionaries,
    /// NSNull, JSONValue) into JSON. Anything else becomes its description, so a
    /// property is never silently lost. Non-finite numbers become null.
    public init(_ any: Any?) {
        guard let any else { self = .null; return }
        switch any {
        case let v as JSONValue: self = v
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Int8: self = .int(Int(v))
        case let v as Int16: self = .int(Int(v))
        case let v as Int32: self = .int(Int(v))
        case let v as Int64: self = .int(Int(truncatingIfNeeded: v))
        case let v as UInt: self = .int(Int(truncatingIfNeeded: v))
        case let v as UInt8: self = .int(Int(v))
        case let v as UInt16: self = .int(Int(v))
        case let v as UInt32: self = .int(Int(v))
        case let v as UInt64: self = .int(Int(truncatingIfNeeded: v))
        case let v as Double: self = v.isFinite ? .double(v) : .null
        case let v as Float: self = v.isFinite ? .double(Double(v)) : .null
        case let v as Decimal: self = .double(NSDecimalNumber(decimal: v).doubleValue)
        case let v as Date: self = .string(ISO8601.string(v))
        case let v as URL: self = .string(v.absoluteString)
        case let v as UUID: self = .string(v.uuidString.lowercased())
        case is NSNull: self = .null
        case let v as [Any?]: self = .array(v.map { JSONValue($0) })
        case let v as [Any]: self = .array(v.map { JSONValue($0) })
        case let v as [String: Any?]: self = .object(v.mapValues { JSONValue($0) })
        case let v as [String: Any]: self = .object(v.mapValues { JSONValue($0) })
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue) }
            else if CFNumberIsFloatType(v) { self = v.doubleValue.isFinite ? .double(v.doubleValue) : .null }
            else { self = .int(v.intValue) }
        default: self = .string(String(describing: any))
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    /// The plain Swift value, for handing to app code.
    public var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .array(let v): return v.map { $0.anyValue }
        case .object(let v): return v.mapValues { $0.anyValue }
        case .null: return NSNull()
        }
    }

    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return v.isFinite ? Int(v) : nil
        default: return nil
        }
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

/// A property dictionary, as stored and sent.
public typealias JSONObject = [String: JSONValue]

extension Dictionary where Key == String, Value == JSONValue {
    /// Converts `[String: Any]` from app code.
    init(any: [String: Any]) {
        self = any.mapValues { JSONValue($0) }
    }
}

enum JSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static let decoder = JSONDecoder()

    static func data<T: Encodable>(_ value: T) -> Data? { try? encoder.encode(value) }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Parses any JSON body into a JSONValue.
    static func parse(_ data: Data?) -> JSONValue? { decode(JSONValue.self, from: data) }
}

enum ISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    /// `2026-11-17T10:00:00.123Z`, the same form JavaScript's toISOString writes.
    static func string(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }

    static func date(_ string: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        if let d = formatter.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}
