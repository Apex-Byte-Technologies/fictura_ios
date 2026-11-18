import XCTest
@testable import FicturaSDK

final class CoreTests: XCTestCase {
    func testBatchEnvelopeHeadersAndEvent() throws {
        let t = FakeTransport()
        let core = makeCore(transport: t)
        core.identify(accountId: "user_77")
        core.setRevenueCatId("$RCAnonymousID:abc")
        core.track("photo_saved", properties: ["style": .string("modern")])
        flushAndWait(core)
        let r = try XCTUnwrap(t.requests(to: "/api/v1/events/log").first)
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "gk_test")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-fictura-sdk"), "ios/\(SDKInfo.version)")
        XCTAssertTrue(r.value(forHTTPHeaderField: "X-Device-ID")!.hasPrefix("ios-"))
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-Account-ID"), "user_77")
        let b = body(r)
        XCTAssertEqual(b["platform"], .string("ios"))
        XCTAssertEqual(b["revenuecat_id"], .string("$RCAnonymousID:abc"))
        XCTAssertNotNil(b["sent_at"]?.stringValue)
        let e = try XCTUnwrap(b["events"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(e["event_name"], .string("photo_saved"))
        XCTAssertEqual(e["status"], .string("info"))
        XCTAssertEqual(Set(e.keys), ["event_name", "status", "properties", "uuid", "timestamp"])
        let p = try XCTUnwrap(e["properties"]?.objectValue)
        XCTAssertEqual(p["style"], .string("modern"))
        XCTAssertEqual(p["$lib"], .string("fictura-ios"))
        XCTAssertEqual(p["$seq"], .int(1))
        XCTAssertNotNil(p["$session_id"]?.stringValue)
        XCTAssertEqual(core.pendingCount, 0)
    }

    func testRetriesOn500AndKeepsEvents() {
        let t = FakeTransport()
        t.responses = [FakeTransport.json(503, "{}", headers: ["Retry-After": "1"])]
        let core = makeCore(transport: t)
        core.track("a")
        flushAndWait(core)
        XCTAssertEqual(core.pendingCount, 1, "kept for the retry")
        let e = expectation(description: "retried")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.6) { e.fulfill() }
        wait(for: [e], timeout: 3)
        core.sync()
        XCTAssertEqual(t.requests(to: "/api/v1/events/log").count, 2)
        XCTAssertEqual(core.pendingCount, 0)
    }

    func testDropsBatchOn400AndReportsIt() throws {
        let t = FakeTransport()
        t.responses = [FakeTransport.json(400, "{}")]
        let core = makeCore(transport: t)
        core.track("bad")
        flushAndWait(core)
        XCTAssertEqual(core.pendingCount, 0)
        core.track("next")
        flushAndWait(core)
        let b = body(try XCTUnwrap(t.requests(to: "/api/v1/events/log").last))
        XCTAssertEqual(b["client_dropped"], .int(1))
        XCTAssertEqual(b["client_dropped_reasons"]?["rejected_4xx"], .int(1))
    }

    func testIdentityIsPinnedPerEvent() throws {
        let t = FakeTransport()
        let core = makeCore(transport: t)
        core.track("before")
        core.identify(accountId: "u1")
        core.track("after")
        flushAndWait(core)
        let reqs = t.requests(to: "/api/v1/events/log")
        XCTAssertEqual(reqs.count, 2)
        XCTAssertNil(reqs[0].value(forHTTPHeaderField: "X-Account-ID"))
        XCTAssertEqual(reqs[1].value(forHTTPHeaderField: "X-Account-ID"), "u1")
    }

    func testAttributesRideTheBatchUntilAcked() throws {
        let t = FakeTransport()
        let core = makeCore(transport: t)
        core.setAttributes(["plan": .string("pro"), "$bad": .int(1), "nested": .object([:])])
        core.setOnce(["first_source": .string("tiktok")])
        core.unsetAttribute("old")
        core.track("x")
        flushAndWait(core)
        let b = body(try XCTUnwrap(t.requests(to: "/api/v1/events/log").first))
        XCTAssertEqual(b["attributes"], .object(["plan": .string("pro")]))
        XCTAssertEqual(b["attributes_set_once"], .object(["first_source": .string("tiktok")]))
        XCTAssertEqual(b["attributes_unset"], .array([.string("old")]))
        core.track("y")
        flushAndWait(core)
        XCTAssertNil(body(t.requests(to: "/api/v1/events/log").last!)["attributes"])
    }

    func testKillSwitchSamplingAndOptOut() {
        let t = FakeTransport()
        let core = makeCore(transport: t)
        core.applyEventSettings(disabled: ["off"], sampleRates: ["never": 0])
        core.track("off")
        core.track("never")
        core.track("kept")
        core.sync()
        XCTAssertEqual(core.pendingCount, 1)
        core.setOptOut(true)
        core.track("blocked")
        core.sync()
        XCTAssertEqual(core.pendingCount, 0)
        XCTAssertTrue(core.isOptedOut)
    }

    func testQueueSurvivesRestart() {
        let store = MemoryStore()
        let keychain = MemorySecureStore()
        let t = FakeTransport()
        t.answer = { _ in .failure(URLError(.notConnectedToInternet)) }
        let core = makeCore(transport: t, store: store, keychain: keychain)
        core.track("offline")
        core.sync()
        core.work.sync { core.writeNow() }
        let again = makeCore(transport: FakeTransport(), store: store, keychain: keychain)
        XCTAssertEqual(again.pendingCount, 1)
        XCTAssertEqual(again.device.deviceId, core.device.deviceId)
    }

    func testLegacyReactNativeDeviceIdIsKept() {
        let keychain = MemorySecureStore()
        _ = keychain.write("ios-11111111-2222-4333-8444-555555555555", service: "app:no-auth", account: "growth_device_id")
        XCTAssertEqual(DeviceIdentity(keychain: keychain).deviceId, "ios-11111111-2222-4333-8444-555555555555")
    }

    func testIllegalIdsAreRefused() {
        XCTAssertNil(FicturaCore.legalId("guest"))
        XCTAssertNil(FicturaCore.legalId("0"))
        XCTAssertEqual(FicturaCore.legalId(" user_9 "), "user_9")
    }

    func testSessionRollsAfterIdle() {
        let clock = Clock()
        let s = SessionTracker(store: MemoryStore(), idle: nil, now: clock.now)
        let a = s.idForEvent(at: clock.now)
        clock.advance(29 * 60)
        XCTAssertEqual(s.idForEvent(at: clock.now), a)
        clock.advance(31 * 60)
        XCTAssertNotEqual(s.idForEvent(at: clock.now), a)
    }
}

final class ConfigTests: XCTestCase {
    func testConfigQueryAndKillSwitches() throws {
        let t = FakeTransport()
        t.answer = { r in
            r.url?.path == "/api/v1/sdk/config"
                ? FakeTransport.json(200, #"{"tools":{"paywalls":true,"ab_testing":false},"disabled_events":["noisy"],"sampling":{"half":0.5},"products":{"primary":"pro_monthly"},"paywalls":{}}"#, headers: ["ETag": "\"v1\""])
                : FakeTransport.json(200, "{}")
        }
        let core = makeCore(transport: t)
        let config = RemoteConfig(core: core)
        let e = expectation(description: "config")
        config.refresh(force: true) { ok in XCTAssertTrue(ok); e.fulfill() }
        wait(for: [e], timeout: 3)
        let q = try XCTUnwrap(URLComponents(url: t.requests(to: "/api/v1/sdk/config")[0].url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(q.first { $0.name == "sv" }?.value, "5")
        XCTAssertEqual(q.first { $0.name == "cv" }?.value, "2")
        XCTAssertEqual(q.first { $0.name == "platform" }?.value, "ios")
        XCTAssertFalse(config.isToolEnabled("ab_testing"))
        XCTAssertTrue(config.isToolEnabled("unknown_tool"))
        XCTAssertEqual(config.products["primary"], "pro_monthly")
        core.track("noisy")
        core.sync()
        XCTAssertEqual(core.pendingCount, 0)
        let cached = RemoteConfig(core: core)
        XCTAssertEqual(cached.source, "cache")
    }
}
