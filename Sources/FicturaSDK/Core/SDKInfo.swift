import Foundation

/// What this SDK calls itself on the wire.
enum SDKInfo {
    /// Bump with every release, together with the CHANGELOG.
    static let version = "0.2.0"
    /// `$lib` on every event.
    static let lib = "fictura-ios"
    /// `x-fictura-sdk`: name/version, so the backend can tell it from the React
    /// Native SDK (which sends a bare version).
    static var header: String { "ios/\(version)" }
    /// `telemetry.sdk.name` on spans; the backend counts it as an app-side SDK.
    static let telemetryName = "fictura-ios"
    /// The newest paywall schema this SDK draws: served HTML only.
    static let paywallSchema = 5
    /// The config contract this SDK reads (the placements block).
    static let configContract = 2
}
