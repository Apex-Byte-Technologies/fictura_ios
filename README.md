# Fictura for iOS

The Fictura SDK for native iOS apps written in Swift (UIKit or SwiftUI). It sends the same events and uses the same paywalls, placements and experiments as the React Native SDK, so one Fictura dashboard serves both.

- iOS 15 or later, Xcode 26 or later, Swift 5.9 or later
- Swift Package Manager only (CocoaPods trunk becomes read-only on 2 December 2026)
- No dependencies

## Install

In Xcode: **File → Add Package Dependencies…**, enter

```
https://github.com/Apex-Byte-Technologies/fictura_ios
```

and add the **FicturaSDK** library to your app target. In a `Package.swift`:

```swift
.package(url: "https://github.com/Apex-Byte-Technologies/fictura_ios", from: "0.1.0")
// target dependency:
.product(name: "FicturaSDK", package: "fictura_ios")
```

## Start

Call `configure` once, as early as possible. The key is the app's publishable key (`gk_…`) from Fictura's Setup page.

```swift
import FicturaSDK

@main
struct MyApp: App {
    init() {
        Fictura.configure(apiKey: "gk_...")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { Fictura.handle(url: $0) }   // tracking links and campaign parameters
        }
    }
}
```

UIKit: call it in `application(_:didFinishLaunchingWithOptions:)`, and pass opening URLs from `scene(_:openURLContexts:)` and `scene(_:continue:)` to `Fictura.handle(url:)`.

## What it records by itself

- `first_open`, `app_open`, `app_backgrounded`, `app_updated`, with sessions (30 minutes idle)
- `screen_viewed` / `screen_closed` for UIKit view controllers. SwiftUI views need one modifier: `.ficturaScreen("Paywall")`
- `element_tapped` for buttons, switches and other `UIControl`s (name them with `accessibilityIdentifier`)
- Crashes and hangs from MetricKit, uncaught Objective-C exceptions, and errors you report

Turn any of these off in `FicturaOptions` (`captureScreens`, `captureTaps`, `captureLifecycle`, `captureErrors`).

## Events, users and attributes

```swift
Fictura.track("photo_saved", properties: ["style": "modern"])
Fictura.screen("Settings")

Fictura.identify("user_123", attributes: ["plan": "free"])   // after sign-in
Fictura.reset()                                               // after sign-out

Fictura.setAttributes(["plan": "pro"])
Fictura.setOnce(["first_source": "tiktok"])
Fictura.register(superProperties: ["ab_cohort": "b"])         // on every event from now on
Fictura.optOut()                                              // stops all capture
```

## Paywalls and placements

Paywalls are the HTML designs you build in Fictura's editor. Call `register` where a paywall may show. Fictura decides from the dashboard (campaigns, audiences, A/B tests) whether to show one, then runs your feature:

```swift
Fictura.register(placement: "export_hd", params: ["source": "editor"]) {
    exportHD()   // runs unless a gated paywall was closed without a purchase
}
```

Callbacks, if you need them:

```swift
Fictura.register(placement: "export_hd", handler: PlacementHandler(
    onPresent: { info in print("showing", info.paywallId) },
    onDismiss: { info, result in print(result) },
    onSkip: { reason in print(reason) },
    onError: { error in print(error) }
))
```

Only designs saved as served HTML (paywall schema 5) can show on iOS. Older React Native-only templates are skipped.

### Purchases

Paywalls buy with **StoreKit 2** by default. Map the design's plan slots to App Store product ids on Fictura's Products page.

If your app uses **RevenueCat**, let RevenueCat make the purchase so its webhook reports revenue to Fictura:

```swift
import RevenueCat
import FicturaSDK

final class RevenueCatPurchases: FicturaPurchaseController {
    func packages(for productIds: [String]) async -> [FicturaPackage] {
        guard let offering = try? await Purchases.shared.offerings().current else { return [] }
        return offering.availablePackages.map { p in
            let product = p.storeProduct
            let hasTrial = product.introductoryDiscount?.paymentMode == .freeTrial
            return FicturaPackage(id: p.identifier, productId: product.productIdentifier, priceString: product.localizedPriceString,
                                  priceMicros: NSDecimalNumber(decimal: product.price * 1_000_000).intValue,
                                  currency: product.currencyCode ?? "USD", period: Self.period(p.packageType),
                                  trialDays: hasTrial ? 7 : nil)   // use the offer's real length in your app
        }
    }

    func purchase(_ package: FicturaPackage, context: FicturaPurchaseContext) async -> FicturaPurchaseResult {
        guard let p = try? await Purchases.shared.offerings().current?.package(identifier: package.id) else { return .failed("not_found") }
        do {
            let result = try await Purchases.shared.purchase(package: p)
            return result.userCancelled ? .cancelled : .purchased(transactionId: result.transaction?.transactionIdentifier, periodType: nil, environment: nil)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func restore() async throws -> Bool { !(try await Purchases.shared.restorePurchases().entitlements.active.isEmpty) }
    func isSubscribed() async -> Bool { (try? await Purchases.shared.customerInfo().entitlements.active.isEmpty == false) ?? false }

    static func period(_ t: PackageType) -> String {
        switch t { case .weekly: return "weekly"; case .monthly: return "monthly"; case .annual: return "annual"; case .lifetime: return "lifetime"; default: return "other" }
    }
}

// After Purchases.configure(...) and after every Purchases.shared.logIn(...):
Fictura.purchaseController = RevenueCatPurchases()
Fictura.setRevenueCatUserId(Purchases.shared.appUserID)
```

Then paste the app's RevenueCat webhook URL (Fictura → Tools → RevenueCat) into RevenueCat. Without RevenueCat, purchases still work, but revenue does not reach Fictura yet (see "Not yet available" below).

### Your links and actions

```swift
Fictura.setLegalURLs(terms: URL(string: "https://example.com/terms"), privacy: URL(string: "https://example.com/privacy"))
Fictura.setCustomActionHandler { name, payload in
    // a design's customAction(name, payload); return ["ok": true, "values": [...]] or nil
    nil
}
```

## Errors

```swift
Fictura.capture(error)
Fictura.captureMessage("Checkout took too long", level: "warning")
```

Crashes and hangs arrive from MetricKit on the next launch. Upload your dSYMs so Fictura can show function names (Setup → Errors).

## Testing against a local backend

```swift
var options = FicturaOptions()
options.apiBase = URL(string: "http://localhost:4000")!
options.debug = true
Fictura.configure(apiKey: "gk_...", options: options)
```

`Examples/FicturaDemo.swiftpm` is a SwiftUI app that exercises everything: events, identify, a placement with an A/B campaign, a purchase and a handled error. Open it in Xcode, or build it with `xcodebuild -scheme FicturaDemo` inside that folder, then launch it with `-ficturaKey gk_... -ficturaApiBase http://localhost:4000 -fakePurchases YES`.

## Same as the React Native SDK

Event names, properties and batching; device ids (an app rewritten from React Native keeps its users: the Keychain id is reused); sessions; identity and attributes; dashboard kill switches and sampling; placements, campaigns, audiences, holdouts and A/B assignment; served HTML paywalls and their `window.__FICTURA__` bridge; paywall and purchase events; web checkout; tracking links; handled errors and MetricKit crashes.

## Not yet available on iOS

- **Push notifications sent by Fictura.** Fictura sends through Expo today. Use OneSignal (Fictura → Tools → OneSignal) with its iOS SDK; pass your user id to `OneSignal.login()`.
- **Revenue without RevenueCat.** App Store Server Notifications are not read yet.
- **Cancel survey** (a React Native screen today).
- **Apple Search Ads attribution** (AdServices) and deferred deep links (`/v1/resolve`).
- **Performance traces** (app start, screen loads, network spans). Crashes and hangs are reported.
- **Onboarding flows** (deprecated in Fictura).
- Older React Native-only paywall templates (schemas 1 to 4).

## Flutter

Flutter apps use [`fictura_flutter`](https://github.com/Apex-Byte-Technologies/fictura_flutter), which wraps this SDK. It names itself with `FicturaOptions.wrapper` and sends Dart errors through `Fictura.Wrapper.captureError`. Apps never call those two themselves.

## Development

```bash
swift test                                                           # unit tests on the Mac
xcodebuild -scheme Fictura -destination 'generic/platform=iOS Simulator' build
```

The tests include values computed by the React Native SDK's own code (`Tests/FicturaSDKTests/Vectors`), so sampling, user seeds and version rules stay identical.
