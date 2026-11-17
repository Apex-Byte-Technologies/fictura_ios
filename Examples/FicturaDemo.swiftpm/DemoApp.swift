import SwiftUI
import FicturaSDK

/// A demo of Fictura in a native SwiftUI app. Launch arguments (for local testing):
///   -ficturaKey gk_...   the app's publishable key
///   -ficturaApiBase URL  a local backend, e.g. http://localhost:4000
///   -fakePurchases YES   buy with a fake store instead of StoreKit
@main
struct DemoApp: App {
    init() {
        let defaults = UserDefaults.standard
        var options = FicturaOptions()
        if let base = defaults.string(forKey: "ficturaApiBase"), let url = URL(string: base) { options.apiBase = url }
        options.debug = true
        options.flushInterval = 2
        Fictura.configure(apiKey: defaults.string(forKey: "ficturaKey") ?? "gk_demo", options: options)
        if defaults.bool(forKey: "fakePurchases") { Fictura.purchaseController = FakeStore.shared }
        Fictura.setLegalURLs(terms: URL(string: "https://fictura.co/terms"), privacy: URL(string: "https://fictura.co/privacy"))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { Fictura.handle(url: $0) }
        }
    }
}

/// Buys instantly, so a paywall can be tested in the Simulator without App Store products.
final class FakeStore: FicturaPurchaseController {
    static let shared = FakeStore()
    var subscribed = false

    func packages(for productIds: [String]) async -> [FicturaPackage] {
        productIds.map {
            FicturaPackage(id: $0, productId: $0, priceString: "$4.99", priceMicros: 4_990_000, currency: "USD",
                           period: "monthly", trialDays: 7, periodMonths: 1, title: "Pro Monthly", trialEligible: true)
        }
    }

    func purchase(_ package: FicturaPackage, context: FicturaPurchaseContext) async -> FicturaPurchaseResult {
        subscribed = true
        return .purchased(transactionId: "fake-\(Int(Date().timeIntervalSince1970))", periodType: "trial", environment: "SANDBOX")
    }

    func restore() async throws -> Bool { subscribed }
    func isSubscribed() async -> Bool { subscribed }
}

struct ContentView: View {
    @State private var log: [String] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Events") {
                    Button("Track photo_saved") {
                        Fictura.track("photo_saved", properties: ["style": "modern", "count": 3])
                        note("tracked photo_saved")
                    }
                    .accessibilityIdentifier("track")
                    Button("Identify live_tester_1") {
                        Fictura.identify("live_tester_1", attributes: ["plan": "free", "ios_demo": true])
                        note("identified live_tester_1")
                    }
                    .accessibilityIdentifier("identify")
                    Button("Flush now") { Fictura.flush { note("flushed") } }
                        .accessibilityIdentifier("flush")
                }
                Section("Paywalls") {
                    Button("Show upgrade (live paywall)") { show("upgrade") }
                        .accessibilityIdentifier("upgrade")
                    Button("Show pro_feature (campaign A/B)") { show("pro_feature") }
                        .accessibilityIdentifier("pro_feature")
                }
                Section("Errors") {
                    Button("Capture handled error") {
                        Fictura.capture(DemoError.cartEmpty(items: 0))
                        note("captured DemoError")
                    }
                    .accessibilityIdentifier("capture")
                }
                Section("Log") {
                    ForEach(Array(log.enumerated()), id: \.offset) { Text($0.element).font(.caption.monospaced()) }
                }
                NavigationLink("Settings screen") { SettingsView() }
            }
            .navigationTitle("Fictura demo")
            .ficturaScreen("Home")
        }
    }

    private func note(_ s: String) { log.insert(s, at: 0) }

    private func show(_ placement: String) {
        Fictura.register(placement: placement, params: ["name": "Tester"], handler: PlacementHandler(
            onPresent: { info in note("presented \(info.paywallId.prefix(8)) variant \(info.variantId?.prefix(8) ?? "-")") },
            onDismiss: { _, result in note("dismissed: \(result)") },
            onSkip: { note("skipped: \($0.rawValue)") },
            onError: { note("error: \($0)") }
        )) {
            note("feature ran for \(placement)")
        }
    }
}

enum DemoError: Error { case cartEmpty(items: Int) }

struct SettingsView: View {
    var body: some View {
        Text("Settings").ficturaScreen("Settings")
    }
}
