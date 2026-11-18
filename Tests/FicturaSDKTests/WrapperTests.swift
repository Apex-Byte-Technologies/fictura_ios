import XCTest
@testable import FicturaSDK

/// What an SDK that wraps this one (fictura_flutter) relies on.
final class WrapperTests: XCTestCase {
    func testWrapperHeaderIsCleaned() {
        XCTAssertEqual(FicturaWrapper(name: "flutter", version: "0.1.0").header, "flutter/0.1.0")
        XCTAssertEqual(FicturaWrapper(name: "Flutter ", version: "0.1.0 beta").header, "flutter/0.1.0beta")
        XCTAssertNil(FicturaWrapper(name: "", version: "0.1.0").header)
        XCTAssertNil(FicturaWrapper(name: "flutter", version: "  ").header)
    }

    func testWrapperPropertiesSplitTheHeader() {
        XCTAssertEqual(DeviceContext.wrapperProperties(FicturaWrapper(name: "flutter", version: "1.2.3+4")),
                       ["$wrapper": .string("flutter"), "$wrapper_version": .string("1.2.3+4")])
        XCTAssertEqual(DeviceContext.wrapperProperties(nil), [:])
    }

    func testWrappedBatchCarriesBothHeadersAndWrapperProperties() throws {
        let t = FakeTransport()
        var o = FicturaOptions(); o.apiBase = URL(string: "https://api.test")!; o.flushInterval = 3600
        let wrapper = FicturaWrapper(name: "flutter", version: "0.1.0")
        let every: JSONObject = ["$lib": .string(SDKInfo.lib), "$lib_version": .string(SDKInfo.version)]
            .merging(DeviceContext.wrapperProperties(wrapper)) { _, w in w }
        let core = FicturaCore(options: o, api: API(base: o.apiBase, apiKey: "gk_test", wrapper: wrapper.header), store: MemoryStore(),
                               device: DeviceIdentity(keychain: MemorySecureStore()), transport: t, now: { Clock().now },
                               random: { 0.5 }, everyEvent: every)
        core.track("photo_saved")
        flushAndWait(core)
        let r = try XCTUnwrap(t.requests(to: "/api/v1/events/log").first)
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-fictura-sdk"), "ios/\(SDKInfo.version)", "the native SDK keeps its own name")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-fictura-wrapper"), "flutter/0.1.0")
        let p = try XCTUnwrap(body(r)["events"]?.arrayValue?.first?["properties"]?.objectValue)
        XCTAssertEqual(p["$lib"], .string("fictura-ios"))
        XCTAssertEqual(p["$wrapper"], .string("flutter"))
        XCTAssertEqual(p["$wrapper_version"], .string("0.1.0"))
    }

    func testUnwrappedRequestsHaveNoWrapperHeader() throws {
        let t = FakeTransport()
        let core = makeCore(transport: t)
        core.track("photo_saved")
        flushAndWait(core)
        let r = try XCTUnwrap(t.requests(to: "/api/v1/events/log").first)
        XCTAssertNil(r.value(forHTTPHeaderField: "x-fictura-wrapper"))
    }

    func testForeignErrorKeepsItsOwnStackAndRuntime() throws {
        let t = FakeTransport()
        let core = makeCore(transport: t)
        let reporter = ErrorReporter(core: core, release: "1.0+1", environment: "test", wrapper: "flutter/0.1.0")
        let stack = "#0      CartPage.checkout (package:shop/cart.dart:42:7)\n#1      _rootRun (dart:async/zone.dart:1399:47)"
        reporter.captureForeign(type: "StateError", message: "Bad state: cart is empty", stack: stack, level: "error",
                                handled: false, mechanism: "flutter_error", runtime: "dart", properties: ["library": "widgets library"])
        let e = expectation(description: "sent")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { e.fulfill() }
        wait(for: [e], timeout: 2)
        let r = try XCTUnwrap(t.requests(to: "/api/v1/errors").first)
        let ev = try XCTUnwrap(body(r)["events"]?.arrayValue?.first)
        XCTAssertEqual(ev["exc_type"], .string("StateError"))
        XCTAssertEqual(ev["message"], .string("Bad state: cart is empty"))
        XCTAssertEqual(ev["stack"], .string(stack), "the Dart stack is sent as given, not the native call stack")
        XCTAssertEqual(ev["platform"], .string("ios"))
        XCTAssertEqual(ev["mechanism"], .string("flutter_error"))
        XCTAssertEqual(ev["handled"], .bool(false))
        XCTAssertEqual(ev["contexts"]?["runtime"]?["name"], .string("dart"))
        XCTAssertEqual(ev["contexts"]?["app"]?["wrapper"], .string("flutter/0.1.0"))
        XCTAssertEqual(ev["tags"]?["library"], .string("widgets library"))
    }

    func testForeignErrorWithoutTypeIsStillSent() throws {
        let t = FakeTransport()
        let core = makeCore(transport: t)
        let reporter = ErrorReporter(core: core, release: "1.0+1", environment: "test")
        reporter.captureForeign(type: "  ", message: nil, stack: nil, level: "warning", handled: true, mechanism: "manual", runtime: "dart")
        let e = expectation(description: "sent")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { e.fulfill() }
        wait(for: [e], timeout: 2)
        let ev = try XCTUnwrap(body(try XCTUnwrap(t.requests(to: "/api/v1/errors").first))["events"]?.arrayValue?.first)
        XCTAssertEqual(ev["exc_type"], .string("Error"))
        XCTAssertNil(ev["stack"])
        XCTAssertNil(ev["contexts"]?["app"]?["wrapper"])
    }
}
