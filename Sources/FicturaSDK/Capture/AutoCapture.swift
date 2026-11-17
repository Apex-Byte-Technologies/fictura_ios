import Foundation
#if canImport(UIKit)
import UIKit
import ObjectiveC
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Lifecycle events with the React Native SDK's names: first_open, app_open,
/// app_backgrounded, app_updated.
final class Lifecycle {
    private let core: FicturaCore
    private let onForeground: () -> Void
    private let onBackground: () -> Void
    private var observers: [NSObjectProtocol] = []
    private(set) var isFirstOpen = false
    /// iOS can post willEnterForeground at a cold launch; only a return from the background is an app_open.
    private var backgrounded = false

    init(core: FicturaCore, onForeground: @escaping () -> Void, onBackground: @escaping () -> Void) {
        self.core = core
        self.onForeground = onForeground
        self.onBackground = onBackground
    }

    /// Records first_open / app_updated / app_open for this launch.
    func launch(track: Bool) {
        let store = core.store
        let version = DeviceContext.appVersion()
        let build = DeviceContext.appBuild()
        // Kept in the Keychain like the React Native SDK's flag (growth_first_open_done),
        // so deleting and reinstalling the app is not a second first_open.
        isFirstOpen = !core.device.firstOpenDone()
        if isFirstOpen {
            core.device.markFirstOpenDone()
            if track { core.track("first_open") }
        } else if let lastV = store.string("app_version_v1"), let lastB = store.string("app_build_v1"),
                  lastV != (version ?? "") || lastB != (build ?? "") {
            if track {
                core.track("app_updated", properties: ["previous_version": .string(lastV), "previous_build": .string(lastB),
                                                     "version": version.map { .string($0) } ?? .null, "build": build.map { .string($0) } ?? .null])
            }
        }
        store.setString(version ?? "", for: "app_version_v1")
        store.setString(build ?? "", for: "app_build_v1")
        if track { core.track("app_open", properties: ["from_background": .bool(false)]) }
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.backgrounded else { return }
            self.backgrounded = false
            if track { self.core.track("app_open", properties: ["from_background": .bool(true)]) }
            self.onForeground()
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.backgrounded = true
            if track { self.core.track("app_backgrounded") }
            self.onBackground()
            // Give the queue a few seconds to reach the server before the app is suspended.
            var task: UIBackgroundTaskIdentifier = .invalid
            task = UIApplication.shared.beginBackgroundTask(withName: "fictura.flush") {
                UIApplication.shared.endBackgroundTask(task)
            }
            self.core.flush {
                self.core.work.async { self.core.writeNow() }
                DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
            }
        })
        #endif
    }
}

#if canImport(UIKit)
/// UIKit screens: one `screen_viewed` per view controller that appears, named by
/// its class (or `ficturaScreenName`). Containers and system controllers are skipped.
enum ScreenCapture {
    static var onScreen: ((String, UIViewController) -> Void)?
    private static var installed = false
    private static let skipped: [String] = ["UINavigationController", "UITabBarController", "UIPageViewController",
                                            "UISplitViewController", "UIInputWindowController", "UIAlertController",
                                            "UICompatibilityInputViewController", "UIEditingOverlayViewController",
                                            "UISystemInputAssistantViewController", "UIPredictionViewController",
                                            "PaywallViewController", "SFSafariViewController", "UIHostingController",
                                            "_UI", "UIKeyboard", "PUPhoto", "UIRemote"]

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UIViewController.self
        guard let original = class_getInstanceMethod(cls, #selector(UIViewController.viewDidAppear(_:))),
              let swizzled = class_getInstanceMethod(cls, #selector(UIViewController.fictura_viewDidAppear(_:))) else { return }
        method_exchangeImplementations(original, swizzled)
    }

    static func name(for vc: UIViewController) -> String? {
        if let named = vc as? FicturaScreenNaming { return named.ficturaScreenName }
        // Only the app's own controllers: Apple's (keyboard, alerts, system windows) live in other bundles.
        let bundle = Bundle(for: type(of: vc))
        if bundle != Bundle.main && (bundle.bundleIdentifier?.hasPrefix("com.apple.") ?? true) { return nil }
        let raw = String(describing: type(of: vc))
        if skipped.contains(where: { raw.hasPrefix($0) }) { return nil }
        if raw.contains("HostingController") { return nil }
        // A container's content reports itself.
        if vc is UINavigationController || vc is UITabBarController { return nil }
        let bare = raw.replacingOccurrences(of: "ViewController", with: "").replacingOccurrences(of: "Controller", with: "")
        return bare.isEmpty ? raw : bare
    }
}

/// Give a UIViewController its own screen name.
public protocol FicturaScreenNaming {
    var ficturaScreenName: String { get }
}

extension UIViewController {
    @objc func fictura_viewDidAppear(_ animated: Bool) {
        fictura_viewDidAppear(animated) // the original, after the swap
        if parent == nil || parent is UINavigationController || parent is UITabBarController, let name = ScreenCapture.name(for: self) {
            ScreenCapture.onScreen?(name, self)
        }
    }
}

/// Taps on UIControls (buttons, switches, segmented controls), via sendAction.
enum TapCapture {
    static var onTap: ((JSONObject) -> Void)?
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UIApplication.self
        guard let original = class_getInstanceMethod(cls, #selector(UIApplication.sendAction(_:to:from:for:))),
              let swizzled = class_getInstanceMethod(cls, #selector(UIApplication.fictura_sendAction(_:to:from:for:))) else { return }
        method_exchangeImplementations(original, swizzled)
    }

    static func describe(_ sender: Any?) -> JSONObject? {
        guard let view = sender as? UIControl else { return nil }
        if view.window == nil { return nil }
        var props: JSONObject = ["element_type": .string(String(describing: type(of: view)))]
        if let id = view.accessibilityIdentifier, !id.isEmpty { props["element_id"] = .string(id) }
        var label: String?
        if let b = view as? UIButton { label = b.currentTitle ?? b.titleLabel?.text ?? b.configuration?.title }
        if label == nil { label = view.accessibilityLabel }
        if let label, !label.isEmpty { props["element_text"] = .string(Delivery.truncate(label, max: 100)) }
        if let s = view as? UISwitch { props["element_value"] = .bool(s.isOn) }
        if let s = view as? UISegmentedControl, s.selectedSegmentIndex >= 0 {
            props["element_value"] = .string(s.titleForSegment(at: s.selectedSegmentIndex) ?? String(s.selectedSegmentIndex))
        }
        return props
    }
}

extension UIApplication {
    @objc func fictura_sendAction(_ action: Selector, to target: Any?, from sender: Any?, for event: UIEvent?) -> Bool {
        let handled = fictura_sendAction(action, to: target, from: sender, for: event)
        if let props = TapCapture.describe(sender) {
            var p = props
            p["action"] = .string(NSStringFromSelector(action))
            TapCapture.onTap?(p)
        }
        return handled
    }
}
#endif

#if canImport(SwiftUI)
@available(iOS 15, macOS 12, *)
struct FicturaScreenModifier: ViewModifier {
    let name: String
    let properties: [String: Any]
    func body(content: Content) -> some View {
        content.onAppear { Fictura.screen(name, properties: properties) }
    }
}

@available(iOS 15, macOS 12, *)
public extension View {
    /// Records this SwiftUI view as a screen when it appears.
    func ficturaScreen(_ name: String, properties: [String: Any] = [:]) -> some View {
        modifier(FicturaScreenModifier(name: name, properties: properties))
    }
}
#endif
