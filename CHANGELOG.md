# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/).

## [0.1.0] - Unreleased

First release: Fictura for native iOS apps.

### Added
- `Fictura.configure`, events, screens, sessions, identity, attributes, super properties, opt-out, with the React Native SDK's event names and batch format (`x-fictura-sdk: ios/0.1.0`, `$lib: fictura-ios`).
- Automatic `first_open`, `app_open`, `app_backgrounded`, `app_updated`, UIKit screens, `element_tapped` for UIControls, and `.ficturaScreen` for SwiftUI.
- Remote config with kill switches and sampling; placements, campaigns, audiences, holdouts and A/B assignment confirmed with the server.
- Served HTML paywalls in a WKWebView with the `window.__FICTURA__` bridge and the shared plan binder; paywall and purchase events; web checkout.
- Purchases through StoreKit 2 by default, or any `FicturaPurchaseController` (RevenueCat example in the README).
- Tracking-link and campaign parameters from opening URLs.
- Handled errors, uncaught exceptions, MetricKit crashes and hangs, sent to Issues.
- Privacy manifest. The device id reuses the React Native SDK's Keychain item.
