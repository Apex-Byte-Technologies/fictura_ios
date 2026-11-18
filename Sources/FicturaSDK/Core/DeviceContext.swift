import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Network)
import Network
#endif

/// Properties on every event, with the same keys the React Native SDK sends
/// (src/deviceContext.ts), so one dashboard reads both.
enum DeviceContext {
    static func everyEventProperties(bundle: Bundle = .main) -> JSONObject {
        var out: JSONObject = ["$lib": .string(SDKInfo.lib), "$lib_version": .string(SDKInfo.version)]
        func put(_ key: String, _ value: String?) { if let value, !value.isEmpty { out[key] = .string(value) } }
        #if os(iOS)
        out["$os"] = .string("iOS")
        put("$os_version", UIDevice.current.systemVersion)
        out["$device_type"] = .string(UIDevice.current.userInterfaceIdiom == .pad ? "Tablet" : "Mobile")
        let bounds = UIScreen.main.bounds
        out["$screen_width"] = .int(Int(bounds.width))
        out["$screen_height"] = .int(Int(bounds.height))
        #else
        out["$os"] = .string("macOS")
        put("$os_version", ProcessInfo.processInfo.operatingSystemVersionString)
        #endif
        put("$device_model", modelIdentifier())
        out["$device_manufacturer"] = .string("Apple")
        put("$app_version", bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
        put("$app_build", bundle.infoDictionary?["CFBundleVersion"] as? String)
        put("$app_namespace", bundle.bundleIdentifier)
        put("$locale", Locale.preferredLanguages.first ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
        put("$timezone", TimeZone.current.identifier)
        #if targetEnvironment(simulator)
        out["$is_emulator"] = .bool(true)
        #else
        out["$is_emulator"] = .bool(false)
        #endif
        return out
    }

    /// `iPhone17,3`; the simulator reports the device it simulates.
    static func modelIdentifier() -> String? {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        let id = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return id.isEmpty ? nil : id
    }

    static func appVersion(bundle: Bundle = .main) -> String? { bundle.infoDictionary?["CFBundleShortVersionString"] as? String }
    static func appBuild(bundle: Bundle = .main) -> String? { bundle.infoDictionary?["CFBundleVersion"] as? String }

    /// Two-letter region from the device locale, upper case (`US`).
    static func country() -> String? {
        if #available(iOS 16, macOS 13, *) { return Locale.current.region?.identifier.uppercased() }
        return (Locale.current as NSLocale).object(forKey: .countryCode) as? String
    }

    static func locale() -> String? { Locale.preferredLanguages.first }
}

/// `$network_type`: wifi, cellular, none or unknown.
final class NetworkWatcher {
    static let shared = NetworkWatcher()
    private(set) var type: String = "unknown"
    #if canImport(Network)
    private let monitor = NWPathMonitor()
    #endif

    private init() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status != .satisfied { self?.type = "none" }
            else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) { self?.type = "wifi" }
            else if path.usesInterfaceType(.cellular) { self?.type = "cellular" }
            else { self?.type = "unknown" }
        }
        monitor.start(queue: DispatchQueue(label: "co.fictura.network"))
        #endif
    }
}
