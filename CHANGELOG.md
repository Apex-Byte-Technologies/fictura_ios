# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/).

## [0.2.0] - Unreleased

For SDKs that wrap this one, starting with `fictura_flutter`. Apps that call the SDK directly see no change.

### Added
- `FicturaOptions.wrapper` (`FicturaWrapper(name:version:)`): a wrapping SDK names itself. Every request then also carries `x-fictura-wrapper: flutter/0.1.0`, every event `$wrapper` and `$wrapper_version`, and every error `contexts.app.wrapper`. `x-fictura-sdk` stays `ios/…`, so the backend keeps reading Apple stacks and serving HTML paywalls.
- `Fictura.Wrapper.captureError(type:message:stack:handled:level:mechanism:runtime:properties:)`: reports an error raised in the wrapper's own language (a Dart exception) with its own stack text, marked with `contexts.runtime.name`.

## [0.1.0] - 2026-11-17

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
