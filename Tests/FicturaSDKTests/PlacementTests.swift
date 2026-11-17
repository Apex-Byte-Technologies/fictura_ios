import XCTest
@testable import FicturaSDK

final class RuleTests: XCTestCase {
    func ctx(user: JSONObject = [:], device: JSONObject = [:], params: JSONObject = [:], occ: [Double] = []) -> RuleContext {
        RuleContext(user: user, seed: 42, isLoggedIn: false, params: params, eventName: "upgrade", device: device,
                    serverCountry: "US", serverBillingState: "none", serverAttribution: ["utm_source": .string("tiktok")],
                    now: 10 * 86_400_000, occurrences: { _ in occ }, installedAt: 0)
    }

    func rule(_ json: String) -> JSONValue { JSON.parse(Data(json.utf8))! }

    func testOperatorsAndLooseEquality() {
        let c = ctx(user: ["plan": .string("pro"), "age": .string("30")], device: ["app_version": .string("1.10.0")])
        XCTAssertTrue(PlacementRules.evaluate(rule(#"{"op":"and","conditions":[{"field":"user.plan","operator":"eq","value":"pro"}]}"#), c))
        XCTAssertTrue(PlacementRules.evaluate(rule(#"{"op":"and","conditions":[{"field":"user.age","operator":"gte","value":30}]}"#), c))
        XCTAssertTrue(PlacementRules.evaluate(rule(#"{"op":"and","conditions":[{"field":"device.app_version","operator":"gt","value":"1.9.0"}]}"#), c))
        XCTAssertTrue(PlacementRules.evaluate(rule(#"{"op":"or","conditions":[{"field":"user.missing","operator":"eq","value":1},{"field":"server.country","operator":"in","value":["US","CA"]}]}"#), c))
        XCTAssertTrue(PlacementRules.evaluate(rule(#"{"op":"and","conditions":[{"field":"user.missing","operator":"not_set"}]}"#), c))
        XCTAssertFalse(PlacementRules.evaluate(rule(#"{"op":"and","conditions":[{"field":"user.missing","operator":"neq","value":"x"}]}"#), c))
        XCTAssertTrue(PlacementRules.evaluate(rule(#"{"op":"and","conditions":[{"field":"server.attribution.utm_source","operator":"contains","value":"tik"}]}"#), c))
        XCTAssertTrue(PlacementRules.evaluate(rule(#"{"op":"and","conditions":[{"field":"user.seed","operator":"lt","value":50}]}"#), c))
        XCTAssertTrue(PlacementRules.evaluate(nil, c))
        XCTAssertTrue(PlacementRules.evaluate(.null, c))
        XCTAssertFalse(PlacementRules.evaluate(rule(#"{"op":"xor","conditions":[{"field":"user.plan","operator":"eq","value":"pro"}]}"#), c))
    }

    func testComputedFieldsAndLimits() {
        let day = 86_400_000.0
        let c = ctx(occ: [8 * day, 9.5 * day])
        XCTAssertTrue(PlacementRules.evaluate(rule(#"{"op":"and","conditions":[{"field":"computed.days_since.upgrade","operator":"eq","value":0}]}"#), c))
        XCTAssertTrue(PlacementRules.evaluate(rule(#"{"op":"and","conditions":[{"field":"computed.placements_in_week.upgrade","operator":"eq","value":2}]}"#), c))
        XCTAssertTrue(Occurrences.limitAllows(rule(#"{"occurrences":3,"interval_minutes":null}"#), [1, 2], now: 10))
        XCTAssertFalse(Occurrences.limitAllows(rule(#"{"occurrences":2,"interval_minutes":null}"#), [1, 2], now: 10))
        XCTAssertFalse(Occurrences.limitAllows(rule(#"{"occurrences":1,"interval_minutes":0}"#), [], now: 10))
    }

    func testOversizedRulesMatchNoOne() {
        let conds = (0..<26).map { _ in #"{"field":"user.seed","operator":"is_set"}"# }.joined(separator: ",")
        XCTAssertFalse(PlacementRules.evaluate(rule(#"{"op":"and","conditions":[\#(conds)]}"#), ctx()))
    }
}

final class EngineTests: XCTestCase {
    let config: JSONObject = JSON.parse(Data(#"""
    {"placements":{
       "upgrade":{"enabled":true,"campaign_id":"c1","audiences":[
         {"id":"a_pro","rule":{"op":"and","conditions":[{"field":"user.plan","operator":"eq","value":"pro"}]},"entitlement_filter":"all","frequency_limit":null,"experiment_id":null,"variants":[{"id":"v_none","type":"holdout","paywall_id":null,"percentage":100}]},
         {"id":"a_all","rule":null,"entitlement_filter":"unsubscribed","frequency_limit":{"occurrences":2,"interval_minutes":null},"experiment_id":"exp1","variants":[
            {"id":"v_a","type":"treatment","paywall_id":"pw_a","percentage":50},
            {"id":"v_b","type":"treatment","paywall_id":"pw_b","percentage":50}]}]},
       "paused":{"enabled":false,"campaign_id":"c2","audiences":[]}},
     "campaign_paywalls":{"pw_a":{"id":"pw_a","version":3,"config":{"schema_version":5,"template":"webview","html":"<p>A</p>"}},
                          "pw_b":{"id":"pw_b","version":1,"config":{"schema_version":5,"template":"webview","html":"<p>B</p>"}}},
     "assignments_v2":[]}
    """#.utf8))!.objectValue!

    func input(_ placement: String, user: JSONObject = [:], subscribed: Bool = false, random: Double = 0.2,
               occurrences: [String: [Double]] = [:], assignments: [String: PlacementEngine.StoredAssignment] = [:],
               config: JSONObject? = nil) -> PlacementEngine.Input {
        let ctx = RuleContext(user: user, seed: 1, isLoggedIn: false, params: [:], eventName: placement, device: [:], serverCountry: nil,
                              serverBillingState: nil, serverAttribution: nil, now: 1_000, occurrences: { _ in [] }, installedAt: 0)
        return .init(config: config ?? self.config, placement: placement, params: [:], now: 1_000, subscribed: subscribed, context: ctx,
                     occurrences: occurrences, assignments: assignments, random: { random })
    }

    func testRandomVariantAndPaywall() {
        let r = PlacementEngine.resolve(input("upgrade"))
        XCTAssertEqual(r.type, .paywall)
        XCTAssertEqual(r.paywallId, "pw_a")
        XCTAssertEqual(r.assignment?.from, "random")
        XCTAssertEqual(r.experimentId, "exp1")
        XCTAssertEqual(PlacementEngine.resolve(input("upgrade", random: 0.7)).paywallId, "pw_b")
    }

    func testStoredAssignmentWins() {
        let r = PlacementEngine.resolve(input("upgrade", random: 0.1, assignments: ["a_all": .init(variant_id: "v_b")]))
        XCTAssertEqual(r.paywallId, "pw_b")
        XCTAssertEqual(r.assignment?.from, "stored")
    }

    func testServerAssignmentWins() {
        var cfg = config
        cfg["assignments_v2"] = .array([.object(["audience_id": .string("a_all"), "variant_id": .string("v_b")])])
        XCTAssertEqual(PlacementEngine.resolve(input("upgrade", random: 0.1, config: cfg)).assignment?.from, "server")
    }

    func testHoldoutSubscribedPausedMissingAndLimit() {
        XCTAssertEqual(PlacementEngine.resolve(input("upgrade", user: ["plan": .string("pro")])).type, .holdout)
        let sub = PlacementEngine.resolve(input("upgrade", subscribed: true))
        XCTAssertEqual(sub.type, .no_audience_match)
        XCTAssertEqual(sub.skipReason, "user_is_subscribed")
        XCTAssertEqual(PlacementEngine.resolve(input("paused")).type, .placement_paused)
        XCTAssertEqual(PlacementEngine.resolve(input("nope")).type, .placement_not_found)
        let limited = PlacementEngine.resolve(input("upgrade", occurrences: [Occurrences.audienceKey("a_all"): [1, 2]]))
        XCTAssertEqual(limited.unmatched["a_all"], "limit")
    }

    func testOverrideBeatsEverything() {
        var cfg = config
        cfg["override"] = .object(["paywall_id": .string("pw_b"), "expires_at": .string("2099-01-01T00:00:00.000Z")])
        let r = PlacementEngine.resolve(input("nope", config: cfg))
        XCTAssertEqual(r.type, .paywall)
        XCTAssertEqual(r.source, "override")
    }

    func testChooseVariantWeights() {
        let vs: [JSONObject] = [["id": .string("a"), "percentage": .int(0)], ["id": .string("b"), "percentage": .int(100)]]
        XCTAssertEqual(PlacementEngine.chooseVariant(vs, random: { 0 })?["id"], .string("b"))
        let zero: [JSONObject] = [["id": .string("a"), "percentage": .int(0)], ["id": .string("b"), "percentage": .int(0)]]
        XCTAssertEqual(PlacementEngine.chooseVariant(zero, random: { 0.6 })?["id"], .string("b"))
    }

    func testFeatureGating() {
        XCTAssertTrue(Placements.shouldRunFeature(.skipped(.holdout)))
        XCTAssertFalse(Placements.shouldRunFeature(.error(FicturaError(code: "x"))))
        XCTAssertTrue(Placements.shouldRunFeature(.dismissed(.declined, .manual, "non_gated")))
        XCTAssertFalse(Placements.shouldRunFeature(.dismissed(.declined, .manual, "gated")))
        XCTAssertTrue(Placements.shouldRunFeature(.dismissed(.purchased(productId: "p"), .manual, "gated")))
        XCTAssertFalse(Placements.shouldRunFeature(.dismissed(.declined, .for_next_paywall, "non_gated")))
    }

    func testParamsSanitized() {
        let p = Placements.sanitize(["a": "x", "$b": 1, "c": [1], "d": true, "e": String(repeating: "z", count: 300)])
        XCTAssertEqual(p["a"], .string("x"))
        XCTAssertNil(p["$b"])
        XCTAssertNil(p["c"])
        XCTAssertEqual(p["d"], .bool(true))
        XCTAssertEqual(p["e"]?.stringValue?.count, 200)
    }
}
