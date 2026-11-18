import Foundation

/// An event as `beforeSend` sees it.
public struct FicturaEvent {
    public var name: String
    public var properties: [String: Any]

    public init(name: String, properties: [String: Any]) {
        self.name = name
        self.properties = properties
    }
}

/// The SDK that wraps this one, such as `fictura_flutter`: its name and version.
/// Set only by that SDK, so the backend can tell its apps apart. App code leaves it nil.
public struct FicturaWrapper: Equatable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    /// `name/version`, sent as `x-fictura-wrapper`. Characters the backend's version check
    /// refuses are dropped, so a bad value never costs the whole header.
    var header: String? {
        let n = String(name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(20))
        let v = String(version.filter { $0.isLetter || $0.isNumber || ".+-".contains($0) }.prefix(40))
        return n.isEmpty || v.isEmpty ? nil : "\(n)/\(v)"
    }
}

/// Settings for `Fictura.configure`. Every field has a default that matches
/// the React Native SDK.
public struct FicturaOptions {
    /// Fictura's API. Change it only to test against a local backend.
    public var apiBase: URL = URL(string: "https://api.fictura.co")!
    /// Events per batch (default 25).
    public var maxBatchSize: Int?
    /// Seconds between automatic sends (default 4).
    public var flushInterval: TimeInterval?
    /// Events kept while offline before the oldest are dropped (default 1000).
    public var maxQueueSize: Int?
    /// A session ends after this long without an event (default 30 minutes).
    public var sessionIdleTimeout: TimeInterval?
    /// Record screens of UIKit view controllers automatically (default on).
    /// SwiftUI screens need `.ficturaScreen("Name")`.
    public var captureScreens = true
    /// Record taps on buttons and other controls (default on).
    public var captureTaps = true
    /// Record app_open, app_backgrounded, first_open and app_updated (default on).
    public var captureLifecycle = true
    /// Report uncaught exceptions, MetricKit crashes and hangs (default on).
    public var captureErrors = true
    /// Fraction of traces sampled for performance, 0 to 1 (default: the dashboard's setting).
    public var tracesSampleRate: Double?
    /// The release, for Issues and Releases (default: version+build, `1.2.0+45`).
    public var release: String?
    /// `production`, `staging`, … (default `production`, or `development` in DEBUG builds).
    public var environment: String?
    /// Change or drop any event before it is queued. Return nil to drop it.
    public var beforeSend: ((FicturaEvent) -> FicturaEvent?)?
    /// Rewrite every event's properties, for example to remove personal data.
    public var sanitizeProperties: ((String, [String: Any]) -> [String: Any])?
    /// Print what the SDK does to the console.
    public var debug = false
    /// Set by an SDK that wraps this one (`fictura_flutter`). Leave it nil in app code.
    public var wrapper: FicturaWrapper?

    public init() {}
}
