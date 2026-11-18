import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// Errors for Fictura's Issues page (POST /api/v1/errors): handled errors,
/// uncaught Objective-C exceptions, and MetricKit crash and hang reports in
/// the shape the backend already symbolicates with uploaded dSYMs.
final class ErrorReporter {
    static let maxBatch = 20
    static let maxPending = 100
    static let maxBreadcrumbs = 30

    private let core: FicturaCore
    private let release: String
    private let environment: String
    /// `x-fictura-wrapper` (`flutter/0.1.0`), repeated in `contexts.app.wrapper`.
    private let wrapper: String?
    private let lock = NSLock()
    private var pending: [JSONObject]
    private var breadcrumbs: [JSONObject] = []
    private var sending = false
    #if canImport(MetricKit) && os(iOS)
    private var metricKit: AnyObject?
    #endif

    init(core: FicturaCore, release: String?, environment: String?, wrapper: String? = nil) {
        self.core = core
        self.wrapper = wrapper
        let version = DeviceContext.appVersion() ?? "0"
        let build = DeviceContext.appBuild()
        self.release = release ?? (build.map { "\(version)+\($0)" } ?? version)
        #if DEBUG
        self.environment = environment ?? "development"
        #else
        self.environment = environment ?? "production"
        #endif
        pending = core.store.decode([JSONObject].self, "errors_v1") ?? []
    }

    private func persist() { core.store.encode(pending, for: "errors_v1") }

    /// The last few events, sent with an error so the Issues page shows what led up to it.
    func addBreadcrumb(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        breadcrumbs.append(["category": .string("event"), "message": .string(name), "ts": .string(ISO8601.string(core.now()))])
        if breadcrumbs.count > Self.maxBreadcrumbs { breadcrumbs.removeFirst(breadcrumbs.count - Self.maxBreadcrumbs) }
    }

    func baseEvent(excType: String, message: String?, stack: String?, level: String, mechanism: String, handled: Bool,
                   at: Date? = nil, eventId: String? = nil) -> JSONObject {
        let ids = core.currentIds()
        var e: JSONObject = [
            "event_id": .string(eventId ?? IDs.uuidv4()),
            "exc_type": .string(String(excType.prefix(120))),
            "level": .string(level),
            "mechanism": .string(mechanism),
            "handled": .bool(handled),
            "platform": .string("ios"),
            "release": .string(release),
            "environment": .string(environment),
            "ts": .string(ISO8601.string(at ?? core.now())),
        ]
        if let message { e["message"] = .string(String(message.prefix(500))) }
        if let stack, !stack.isEmpty { e["stack"] = .string(String(stack.prefix(64_000))) }
        if let user = ids.accountId { e["user_id"] = .string(String(user.prefix(120))) }
        if let session = core.session.currentId(now: core.now()) { e["session_id"] = .string(session) }
        if let screen = core.currentScreen { e["route"] = .string(String(screen.prefix(200))) }
        let ev = DeviceContext.everyEventProperties()
        var app: JSONObject = ["version": ev["$app_version"] ?? .null, "build": ev["$app_build"] ?? .null, "sdk": .string(SDKInfo.header),
                               "in_app_modules": .array(Self.inAppModules.map { .string($0) })]
        if let wrapper { app["wrapper"] = .string(wrapper) }
        e["contexts"] = .object([
            "os": .object(["name": .string("iOS"), "version": ev["$os_version"] ?? .null]),
            "device": .object(["model": ev["$device_model"] ?? .null, "simulator": ev["$is_emulator"] ?? .null]),
            "app": .object(app),
        ])
        lock.lock()
        if !breadcrumbs.isEmpty { e["breadcrumbs"] = .array(breadcrumbs.map { .object($0) }) }
        lock.unlock()
        return e
    }

    func enqueue(_ e: JSONObject, sendNow: Bool = true) {
        guard !core.isOptedOut else { return }
        lock.lock()
        pending.append(e)
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        persist()
        lock.unlock()
        if sendNow { send() }
    }

    /// A handled error from app code: `Fictura.capture(error)`.
    func capture(_ error: Error, level: String = "error", properties: [String: Any] = [:]) {
        let ns = error as NSError
        let type = String(describing: Swift.type(of: error))
        let excType = (type == "NSError" || type == "__SwiftNativeNSError") ? "\(ns.domain).\(ns.code)" : type
        var e = baseEvent(excType: excType, message: error.localizedDescription, stack: Self.callStack(dropFirst: 2),
                          level: level, mechanism: "manual", handled: true)
        if !properties.isEmpty { e["tags"] = .object(JSONObject(any: properties)) }
        enqueue(e)
    }

    func captureMessage(_ message: String, level: String) {
        enqueue(baseEvent(excType: "Message", message: message, stack: nil, level: level, mechanism: "manual", handled: true))
    }

    /// An error raised in a wrapping SDK's own language (a Dart exception from
    /// `fictura_flutter`): its type, message and stack text, which this SDK can't
    /// see. `contexts.runtime.name` tells the backend how to read the stack.
    func captureForeign(type: String, message: String?, stack: String?, level: String, handled: Bool,
                        mechanism: String, runtime: String, properties: [String: Any] = [:]) {
        let cleanType = type.trimmingCharacters(in: .whitespacesAndNewlines)
        var e = baseEvent(excType: cleanType.isEmpty ? "Error" : cleanType, message: message, stack: stack,
                          level: level, mechanism: String(mechanism.prefix(40)), handled: handled)
        if case .object(var contexts)? = e["contexts"] {
            contexts["runtime"] = .object(["name": .string(String(runtime.prefix(40)))])
            e["contexts"] = .object(contexts)
        }
        if !properties.isEmpty { e["tags"] = .object(JSONObject(any: properties)) }
        enqueue(e)
    }

    /// The current thread's frames, demangled, deepest first, without the SDK's own
    /// (with Swift Package Manager the SDK is linked into the app's binary, so they are cut by symbol).
    static func callStack(dropFirst: Int = 0) -> String {
        let lines = Thread.callStackSymbols.dropFirst(dropFirst).map(Demangle.line)
        return lines.drop { $0.contains(" FicturaSDK.") || $0.contains(" Fictura.") }.joined(separator: "\n")
    }

    /// The binaries that are the app's own code: its executable and the frameworks it embeds.
    /// The backend groups native errors on frames from these only.
    static let inAppModules: [String] = {
        var out: [String] = []
        if let exe = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String { out.append(exe) }  // its .debug.dylib in Xcode debug builds is matched by the backend
        if let path = Bundle.main.privateFrameworksPath,
           let items = try? FileManager.default.contentsOfDirectory(atPath: path) {
            out += items.filter { $0.hasSuffix(".framework") }.map { String($0.dropLast(10)) }.sorted()
        }
        return Array(out.prefix(50))
    }()

    // MARK: Uncaught exceptions

    private static weak var shared: ErrorReporter?
    private static var previousHandler: (@convention(c) (NSException) -> Void)?

    func installUncaughtHandler() {
        Self.shared = self
        Self.previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            if let r = ErrorReporter.shared {
                let stack = exception.callStackSymbols.map(Demangle.line).joined(separator: "\n")
                let e = r.baseEvent(excType: exception.name.rawValue, message: exception.reason, stack: stack,
                                    level: "fatal", mechanism: "uncaught", handled: false)
                // The process is about to die: stored now, sent on the next launch.
                r.enqueue(e, sendNow: false)
            }
            ErrorReporter.previousHandler?(exception)
        }
    }

    // MARK: Delivery

    func send() {
        lock.lock()
        guard !sending, !pending.isEmpty else { lock.unlock(); return }
        sending = true
        let batch = Array(pending.prefix(Self.maxBatch))
        lock.unlock()
        let ids = core.currentIds()
        let body = JSON.data(JSONValue.object(["events": .array(batch.map { .object($0) }), "sent_at": .string(ISO8601.string(core.now()))]))
        guard let r = core.api.request("api/v1/errors", method: "POST", body: body, deviceId: ids.deviceId, accountId: ids.accountId) else {
            lock.lock(); sending = false; lock.unlock()
            return
        }
        core.transport.send(r) { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.sending = false
            let sentIds = Set(batch.compactMap { $0["event_id"]?.stringValue })
            // Stored, or refused for good (a 4xx other than 429): either way not sent again.
            let done = result.ok || (result.status.map { (400..<500).contains($0) && $0 != 429 } ?? false)
            if done { self.pending.removeAll { sentIds.contains($0["event_id"]?.stringValue ?? "") } }
            self.persist()
            let more = done && !self.pending.isEmpty
            self.lock.unlock()
            if more { self.send() }
        }
    }

    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    // MARK: MetricKit

    func startMetricKit() {
        #if canImport(MetricKit) && os(iOS)
        let sub = MetricKitSubscriber { [weak self] payloads in
            guard let self else { return }
            for p in payloads { for e in MetricKitMapper.events(from: p, appBinary: MetricKitMapper.appBinary, reporter: self) { self.enqueue(e, sendNow: false) } }
            self.send()
        }
        MXMetricManager.shared.add(sub)
        metricKit = sub
        #endif
    }
}

#if canImport(MetricKit) && os(iOS)
private final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    let onDiagnostics: ([Data]) -> Void
    init(_ onDiagnostics: @escaping ([Data]) -> Void) { self.onDiagnostics = onDiagnostics }
    func didReceive(_ payloads: [MXMetricPayload]) {}
    func didReceive(_ payloads: [MXDiagnosticPayload]) { onDiagnostics(payloads.map { $0.jsonRepresentation() }) }
}
#endif

/// MetricKit diagnostic JSON → error events, as the React Native SDK maps them
/// (src/nativeCrashes.ts mapMetricKitPayload), so both group the same way.
enum MetricKitMapper {
    static let machExceptions: [Int: String] = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
                                                5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL",
                                                9: "EXC_RPC_ALERT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY"]
    static let signals: [Int: String] = [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT",
                                         8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE", 15: "SIGTERM"]
    static let framesMax = 64

    static var appBinary: String? { Bundle.main.infoDictionary?["CFBundleExecutable"] as? String }

    /// The attributed thread's frames, innermost first.
    static func frames(_ tree: JSONObject?, appBinary: String?) -> [JSONObject] {
        let stacks = tree?["callStacks"]?.arrayValue?.compactMap { $0.objectValue } ?? []
        let stack = stacks.first { $0["threadAttributed"]?.boolValue == true } ?? stacks.first
        var out: [JSONObject] = []
        var f = stack?["callStackRootFrames"]?.arrayValue?.first?.objectValue
        while let frame = f, out.count < framesMax {
            let binary = frame["binaryName"]?.stringValue
            let address = frame["address"]?.doubleValue.map { "0x" + String(UInt64($0), radix: 16) }
            out.append([
                "binary": binary.map { .string($0) } ?? .null,
                "uuid": frame["binaryUUID"]?.stringValue.map { .string($0.lowercased()) } ?? .null,
                "offset": frame["offsetIntoBinaryTextSegment"].flatMap { $0.intValue }.map { .int($0) } ?? .null,
                "address": address.map { .string($0) } ?? .null,
                "in_app": .bool(appBinary != nil && binary == appBinary),
            ])
            f = frame["subFrames"]?.arrayValue?.first?.objectValue
        }
        return out
    }

    /// `0   App   0x0000000100a1b2c3 App + 123456`.
    static func appleStack(_ frames: [JSONObject]) -> String {
        frames.enumerated().map { i, f in
            let name = f["binary"]?.stringValue ?? "???"
            let raw = (f["address"]?.stringValue ?? "0x0").dropFirst(2)
            let addr = "0x" + String(repeating: "0", count: max(0, 16 - raw.count)) + raw
            let index = String(i).padding(toLength: 4, withPad: " ", startingAt: 0)
            return "\(index)\(name.padding(toLength: max(32, name.count), withPad: " ", startingAt: 0))\(addr) \(name) + \(f["offset"]?.intValue ?? 0)"
        }.joined(separator: "\n")
    }

    static func events(from data: Data, appBinary: String?, reporter: ErrorReporter) -> [JSONObject] {
        guard let payload = JSON.parse(data)?.objectValue else { return [] }
        let seed = Hash.sha256Hex(String(decoding: data, as: UTF8.self)).prefix(16)
        var out: [JSONObject] = []
        func meta(_ d: JSONObject) -> JSONObject { d["diagnosticMetaData"]?.objectValue ?? d["metaData"]?.objectValue ?? [:] }
        for (i, raw) in (payload["crashDiagnostics"]?.arrayValue ?? []).enumerated() {
            guard let d = raw.objectValue else { continue }
            let m = meta(d)
            let exc = m["exceptionType"]?.intValue
            let sig = m["signal"]?.intValue
            let excName = exc.map { machExceptions[$0] ?? "EXC_\($0)" }
            let sigName = sig.map { signals[$0] ?? "SIG\($0)" }
            let termination = m["terminationReason"]?.stringValue
            let objc = (m["exceptionReason"] ?? d["exceptionReason"])?.objectValue
            let objcName = objc?["exceptionName"]?.stringValue
            let objcMessage = objc?["composedMessage"]?.stringValue
            let watchdog = termination?.lowercased().contains("8badf00d") == true
            let type = watchdog ? "WatchdogTermination" : (objcName ?? excName ?? sigName ?? "NativeCrash")
            let head = (excName != nil && sigName != nil) ? "\(excName!) (\(sigName!))" : (excName ?? sigName)
            let message = objcMessage ?? [head, termination].compactMap { $0 }.joined(separator: ": ")
            let fr = frames(d["callStackTree"]?.objectValue, appBinary: appBinary)
            var e = reporter.baseEvent(excType: type, message: message.isEmpty ? nil : message, stack: fr.isEmpty ? nil : appleStack(fr),
                                       level: "fatal", mechanism: "ios_metrickit", handled: false, eventId: stableUuid("mxc:\(seed):\(i)"))
            e.removeValue(forKey: "breadcrumbs")
            e.removeValue(forKey: "session_id")
            e.removeValue(forKey: "route")
            var mk: JSONObject = [:]
            mk["app_version"] = m["appVersion"] ?? .null
            mk["app_build"] = m["appBuildVersion"] ?? .null
            mk["os_version"] = m["osVersion"] ?? .null
            mk["device_type"] = m["deviceType"] ?? .null
            mk["exception_type"] = exc.map { JSONValue.int($0) } ?? .null
            mk["exception_name"] = excName.map { JSONValue.string($0) } ?? .null
            mk["signal"] = sig.map { JSONValue.int($0) } ?? .null
            mk["signal_name"] = sigName.map { JSONValue.string($0) } ?? .null
            mk["termination_reason"] = termination.map { JSONValue.string($0) } ?? .null
            var native: JSONObject = ["kind": .string("ios_metrickit"), "diagnostic": .string("crash"), "metrickit": .object(mk)]
            native["app_binary"] = appBinary.map { JSONValue.string($0) } ?? .null
            native["frames"] = .array(fr.map { JSONValue.object($0) })
            e["native"] = .object(native)
            out.append(e)
        }
        for (i, raw) in (payload["hangDiagnostics"]?.arrayValue ?? []).enumerated() {
            guard let d = raw.objectValue else { continue }
            let m = meta(d)
            let durationMs = parseDurationMs(m["hangDuration"])
            let fr = frames(d["callStackTree"]?.objectValue, appBinary: appBinary)
            let secs = durationMs.map { ($0 / 100).rounded() / 10 }
            var e = reporter.baseEvent(excType: "AppHang",
                                       message: secs.map { "App hang: the main thread was blocked for \($0) s" } ?? "App hang",
                                       stack: fr.isEmpty ? nil : appleStack(fr), level: "error", mechanism: "ios_metrickit",
                                       handled: true, eventId: stableUuid("mxh:\(seed):\(i)"))
            e.removeValue(forKey: "breadcrumbs")
            e.removeValue(forKey: "route")
            e["native"] = .object([
                "kind": .string("ios_metrickit"), "diagnostic": .string("hang"),
                "metrickit": .object(["hang_duration_ms": durationMs.map { .double($0) } ?? .null]),
                "app_binary": appBinary.map { .string($0) } ?? .null,
                "frames": .array(fr.map { .object($0) }),
            ])
            out.append(e)
        }
        return out
    }

    static func parseDurationMs(_ v: JSONValue?) -> Double? {
        guard let v else { return nil }
        if let n = v.doubleValue { return n * 1000 }
        guard let s = v.stringValue,
              let m = try? NSRegularExpression(pattern: #"([\d.,]+)\s*(ms|msec|s|sec|secs|seconds?|min|mins|minutes?)?"#, options: .caseInsensitive)
                .firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let numRange = Range(m.range(at: 1), in: s), let n = Double(s[numRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let unit = Range(m.range(at: 2), in: s).map { s[$0].lowercased() } ?? "sec"
        if unit.hasPrefix("ms") || unit == "msec" { return n }
        if unit.hasPrefix("min") { return n * 60_000 }
        return n * 1000
    }

    /// A deterministic UUID for a diagnostic, so a payload delivered twice is stored once.
    static func stableUuid(_ seed: String) -> String {
        var b = Hash.sha256(seed).prefix(16).map { $0 }
        b[6] = (b[6] & 0x0f) | 0x40
        b[8] = (b[8] & 0x3f) | 0x80
        return IDs.format(b)
    }
}

/// Demangles Swift symbols in `Thread.callStackSymbols` lines, so the backend
/// can group Swift errors by function (errorFingerprint.ts reads `Module:symbol`).
enum Demangle {
    private typealias Fn = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private static let fn: Fn? = {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func symbol(_ mangled: String) -> String {
        guard mangled.hasPrefix("$s") || mangled.hasPrefix("_$s") || mangled.hasPrefix("$S"), let fn else { return mangled }
        return mangled.withCString { ptr in
            guard let out = fn(ptr, strlen(ptr), nil, nil, 0) else { return mangled }
            defer { free(out) }
            return String(cString: out)
        }
    }

    /// `3   App   0x0000000100a2c3f4 $s3App3FooC3baryyF + 120` → the symbol demangled.
    static func line(_ line: String) -> String {
        guard let r = line.range(of: #"0x[0-9a-fA-F]+ "#, options: .regularExpression) else { return line }
        let rest = line[r.upperBound...]
        guard let plus = rest.range(of: " + ", options: .backwards) else { return line }
        let sym = String(rest[..<plus.lowerBound])
        let demangled = symbol(sym)
        return demangled == sym ? line : String(line[..<r.upperBound]) + demangled + String(rest[plus.lowerBound...])
    }
}
