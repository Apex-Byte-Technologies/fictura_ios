import XCTest
@testable import FicturaSDK

final class FakeController: FicturaPurchaseController {
    var result: FicturaPurchaseResult = .purchased(transactionId: "t1", periodType: "trial", environment: "SANDBOX")
    var bought: [String] = []
    func packages(for productIds: [String]) async -> [FicturaPackage] {
        productIds.map { FicturaPackage(id: $0, productId: $0, priceString: "$9.99", priceMicros: 9_990_000, currency: "USD",
                                        period: "monthly", trialDays: 7, trialEligible: true) }
    }
    func purchase(_ package: FicturaPackage, context: FicturaPurchaseContext) async -> FicturaPurchaseResult {
        bought.append(package.id)
        return result
    }
    func restore() async throws -> Bool { true }
}

final class FakeHost: PaywallHost {
    var scripts: [String] = []
    var closed: [(PaywallResult, CloseReason)] = []
    var opened: [URL] = []
    func evaluate(_ js: String) { scripts.append(js) }
    func closePaywall(result: PaywallResult, reason: CloseReason) { closed.append((result, reason)) }
    func open(url: URL, inApp: Bool) { opened.append(url) }
    func haptic(_ kind: String) {}
    func requestReview() {}
    func alert(title: String, message: String) {}
    func requestPermission(_ name: String, completion: @escaping (Bool) -> Void) { completion(false) }
}

final class PaywallTests: XCTestCase {
    func make(_ core: FicturaCore, controller: FicturaPurchaseController? = FakeController(), webCheckout: Bool = false) -> (PaywallBridge, FakeHost) {
        let ctx = PaywallEventContext(placement: "upgrade", paywallId: "pw_a", paywallVersion: 3, campaignId: "c1", audienceId: "a1",
                                      experimentId: "e1", variantId: "v1", presentedBy: "placement")
        let bridge = PaywallBridge(core: core, controller: controller, context: ctx, html: "<p>Hi {{params.name}}</p>",
                                   params: ["name": .string("<Ann>")], slotMap: ["primary": "pro_monthly"],
                                   pageValues: ["copy": .object(["title": .string("Go Pro")])], webCheckout: { webCheckout },
                                   openWebCheckout: { _ in webCheckout }, presentPlacement: { _ in }, customAction: nil)
        let host = FakeHost()
        bridge.host = host
        return (bridge, host)
    }

    func events(_ t: FakeTransport) -> [JSONObject] {
        t.requests(to: "/api/v1/events/log").flatMap { body($0)["events"]?.arrayValue ?? [] }.compactMap { $0.objectValue }
    }

    func testParamsAreEscapedIntoTheDesign() {
        let (bridge, _) = make(makeCore())
        XCTAssertEqual(bridge.html, "<p>Hi &lt;Ann&gt;</p>")
    }

    func testInjectedScriptCarriesBridgeAndBinder() async {
        let (bridge, _) = make(makeCore())
        await bridge.loadPackages()
        let js = bridge.injectedScript()
        XCTAssertTrue(js.contains("window.__FICTURA__ = {"))
        XCTAssertTrue(js.contains("\"product_id\":\"pro_monthly\""))
        XCTAssertTrue(js.contains("\"primary\":{"))
        XCTAssertTrue(js.contains("window.webkit.messageHandlers.fictura"))
        XCTAssertTrue(js.contains("window.__FICTURA__.bind = function"), "binder included")
        XCTAssertTrue(js.contains("\"title\":\"Go Pro\""))
    }

    func testReadyPurchaseAndTrackEvents() async throws {
        let t = FakeTransport()
        let core = makeCore(transport: t)
        let controller = FakeController()
        let (bridge, host) = make(core, controller: controller)
        await bridge.loadPackages()
        bridge.handle(#"{"type":"ready"}"#)
        bridge.handle(#"{"type":"track","event":"paywall_plan_selected","properties":{"plan":"annual"}}"#)
        bridge.handle(#"{"type":"track","event":"faq_opened"}"#)
        bridge.handle(#"{"type":"purchase","package_id":"pro_monthly"}"#)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.bought, ["pro_monthly"])
        XCTAssertEqual(host.closed.first?.0, .purchased(productId: "pro_monthly"))
        XCTAssertTrue(host.scripts.contains { $0.contains("fictura:purchase_result") && $0.contains("purchased") })
        flushAndWait(core)
        let names = events(t).compactMap { $0["event_name"]?.stringValue }
        XCTAssertEqual(names, ["paywall_shown", "paywall_product_selected", "paywall_web_faq_opened", "paywall_cta_tapped",
                               "purchase_started", "purchase_completed", "paywall_dismissed"])
        let shown = events(t)[0]["properties"]!.objectValue!
        XCTAssertEqual(shown["paywall_id"], .string("pw_a"))
        XCTAssertEqual(shown["experiment_id"], .string("e1"))
        XCTAssertNotNil(shown["paywall_session_id"]?.stringValue)
        let completed = events(t)[5]["properties"]!.objectValue!
        XCTAssertEqual(completed["is_trial"], .bool(true))
        XCTAssertEqual(completed["currency"], .string("USD"))
    }

    func testCancelledPurchaseKeepsPaywallOpen() async throws {
        let core = makeCore()
        let controller = FakeController()
        controller.result = .cancelled
        let (bridge, host) = make(core, controller: controller)
        var cancelled: [String] = []
        bridge.onPurchaseCancelled = { cancelled.append($0) }
        await bridge.loadPackages()
        bridge.handle(#"{"type":"purchase","package_id":"pro_monthly"}"#)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(host.closed.isEmpty)
        XCTAssertEqual(cancelled, ["pro_monthly"])
    }

    func testWebCheckoutOpensInsteadOfStore() async throws {
        let core = makeCore()
        let controller = FakeController()
        let (bridge, _) = make(core, controller: controller, webCheckout: true)
        await bridge.loadPackages()
        bridge.handle(#"{"type":"purchase","package_id":"pro_monthly"}"#)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(controller.bought.isEmpty)
    }

    func testCloseAndUnsafeLinks() {
        let (bridge, host) = make(makeCore())
        bridge.handle(#"{"type":"open_url","url":"javascript:alert(1)"}"#)
        bridge.handle(#"{"type":"open_url","url":"https://example.com/terms"}"#)
        bridge.handle(#"{"type":"close"}"#)
        bridge.handle(#"not json"#)
        XCTAssertEqual(host.opened, [URL(string: "https://example.com/terms")!])
        XCTAssertEqual(host.closed.first?.1, .manual)
    }

    func testCustomActionAnswerIsCleaned() {
        let v = PaywallBridge.customAnswer(["ok": true, "values": ["name": "Ann", "Bad Key": 1, "n": 3]])
        XCTAssertEqual(v["values"]?["name"], .string("Ann"))
        XCTAssertNil(v["values"]?["Bad Key"])
        XCTAssertEqual(PaywallBridge.customAnswer(nil), .bool(false))
    }
}

final class ErrorTests: XCTestCase {
    func testMetricKitCrashMapsLikeReactNative() throws {
        let payload = #"""
        {"crashDiagnostics":[{"diagnosticMetaData":{"exceptionType":1,"signal":11,"appVersion":"1.0","osVersion":"iPhone OS 26.5"},
          "callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
            {"binaryName":"ShopApp","binaryUUID":"ABC","offsetIntoBinaryTextSegment":4096,"address":4295000000,
             "subFrames":[{"binaryName":"UIKitCore","binaryUUID":"DEF","offsetIntoBinaryTextSegment":12,"address":7000000000}]}]}]}}],
         "hangDiagnostics":[{"diagnosticMetaData":{"hangDuration":"2.5 sec"},"callStackTree":{"callStacks":[]}}]}
        """#
        let core = makeCore()
        let reporter = ErrorReporter(core: core, release: "1.0+1", environment: "test")
        let events = MetricKitMapper.events(from: Data(payload.utf8), appBinary: "ShopApp", reporter: reporter)
        XCTAssertEqual(events.count, 2)
        let crash = events[0]
        XCTAssertEqual(crash["exc_type"], .string("EXC_BAD_ACCESS"))
        XCTAssertEqual(crash["message"], .string("EXC_BAD_ACCESS (SIGSEGV)"))
        XCTAssertEqual(crash["mechanism"], .string("ios_metrickit"))
        XCTAssertEqual(crash["level"], .string("fatal"))
        XCTAssertTrue(crash["stack"]!.stringValue!.hasPrefix("0   ShopApp"))
        XCTAssertEqual(crash["native"]?["frames"]?.arrayValue?.first?["in_app"], .bool(true))
        XCTAssertEqual(crash["native"]?["frames"]?.arrayValue?.first?["uuid"], .string("abc"))
        XCTAssertEqual(events[1]["message"], .string("App hang: the main thread was blocked for 2.5 s"))
        // Delivered twice, stored once.
        let again = MetricKitMapper.events(from: Data(payload.utf8), appBinary: "ShopApp", reporter: reporter)
        XCTAssertEqual(again[0]["event_id"], crash["event_id"])
    }

    func testHandledErrorIsSent() throws {
        let t = FakeTransport()
        let core = makeCore(transport: t)
        let reporter = ErrorReporter(core: core, release: "1.0+1", environment: "test")
        reporter.capture(NSError(domain: "Shop", code: 7, userInfo: [NSLocalizedDescriptionKey: "cart is empty"]))
        let e = expectation(description: "sent")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { e.fulfill() }
        wait(for: [e], timeout: 2)
        let r = try XCTUnwrap(t.requests(to: "/api/v1/errors").first)
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-fictura-sdk"), "ios/\(SDKInfo.version)")
        let ev = try XCTUnwrap(body(r)["events"]?.arrayValue?.first)
        XCTAssertEqual(ev["exc_type"], .string("Shop.7"))
        XCTAssertEqual(ev["platform"], .string("ios"))
        XCTAssertEqual(ev["handled"], .bool(true))
        XCTAssertNotNil(ev["stack"]?.stringValue)
        XCTAssertEqual(reporter.pendingCount, 0)
    }

    func testDemangleLine() {
        let line = "1   ShopApp   0x0000000100a2c3f4 $s7ShopApp4CartC8checkoutyyF + 88"
        let out = Demangle.line(line)
        XCTAssertTrue(out.contains("ShopApp.Cart.checkout() -> ()"), out)
        XCTAssertTrue(out.hasSuffix("+ 88"))
    }

    func testAttributionParams() {
        let click = "6f1c2a9e-1b2c-4d3e-8f90-123456789abc"
        let p = Attribution.params(from: URL(string: "shop://open?growth_click=\(click)&utm_source=tiktok&gclid=g")!)
        XCTAssertEqual(p?["growth_click_id"], .string(click))
        // The server refuses a whole batch over a malformed click id, so it is dropped here.
        XCTAssertNil(Attribution.params(from: URL(string: "shop://open?growth_click=c_1&utm_source=x")!)?["growth_click_id"])
        XCTAssertEqual(p?["utm_source"], .string("tiktok"))
        XCTAssertEqual(p?["click_id"], .string("g"))
        XCTAssertNil(Attribution.params(from: URL(string: "shop://open")!))
    }
}
