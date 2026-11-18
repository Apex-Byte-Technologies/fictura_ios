import Foundation

/// Which audience, variant and paywall a placement shows: a direct port of the
/// React Native SDK's decision engine (src/placements/engine.ts).
enum PlacementEngine {
    enum ResolutionType: String {
        case paywall, holdout, no_audience_match, placement_not_found, placement_paused, paywall_not_available
    }

    struct StoredAssignment: Codable, Equatable {
        var variant_id: String
        var experiment_id: String?
        var placement: String?
        var confirmed: Bool?
    }

    struct Decision: Equatable {
        var audienceId: String
        var variantId: String
        var experimentId: String?
        var placement: String
        var from: String // stored | server | random
    }

    struct Resolution {
        var type: ResolutionType
        var source: String? // campaign | default_campaign | override
        var campaignId: String?
        var audienceId: String?
        var experimentId: String?
        var variantId: String?
        var paywallId: String?
        var paywall: JSONObject?
        var unmatched: [String: String] = [:]
        var assignment: Decision?
        var skipReason: String?

        init(_ type: ResolutionType) { self.type = type }
    }

    struct Input {
        var config: JSONObject
        var placement: String
        var params: JSONObject
        var now: Double
        var subscribed: Bool
        var context: RuleContext
        var occurrences: [String: [Double]]
        var assignments: [String: StoredAssignment]
        var random: () -> Double
    }

    static func hasPlacementsBlock(_ config: JSONObject?) -> Bool { config?["placements"]?.objectValue != nil }

    private static func millis(_ iso: String?) -> Double? {
        guard let iso, let d = ISO8601.date(iso) else { return nil }
        return d.timeIntervalSince1970 * 1000
    }

    private static func inSchedule(_ a: JSONObject, now: Double) -> Bool {
        if let s = a["start_at"]?.stringValue, !s.isEmpty {
            guard let start = millis(s), now >= start else { return false }
        }
        if let e = a["end_at"]?.stringValue, !e.isEmpty {
            guard let end = millis(e), now < end else { return false }
        }
        return true
    }

    private static func entitlementAllows(_ filter: String?, subscribed: Bool) -> Bool {
        switch filter ?? "unsubscribed" {
        case "all": return true
        case "unsubscribed": return !subscribed
        case "subscribed": return subscribed
        default: return false
        }
    }

    static func mismatch(_ a: JSONObject, _ input: Input, _ ctx: RuleContext) -> String? {
        if !inSchedule(a, now: input.now) { return "schedule" }
        if !entitlementAllows(a["entitlement_filter"]?.stringValue, subscribed: input.subscribed) { return "entitlement" }
        if !PlacementRules.evaluate(a["rule"], ctx) { return "rule" }
        let id = a["id"]?.stringValue ?? ""
        if !Occurrences.limitAllows(a["frequency_limit"], input.occurrences[Occurrences.audienceKey(id)], now: input.now) { return "limit" }
        return nil
    }

    static func chooseVariant(_ variants: [JSONObject], random: () -> Double) -> JSONObject? {
        let list = variants.filter { $0["id"]?.stringValue != nil }
        if list.isEmpty { return nil }
        if list.count == 1 { return list[0] }
        let weights = list.map { v -> Double in
            let p = v["percentage"]?.doubleValue ?? 0
            return p.isFinite && p > 0 ? p : 0
        }
        let sum = weights.reduce(0, +)
        let r = min(max(random(), 0), 0.999999999)
        if sum == 0 { return list[Int((r * Double(list.count)).rounded(.down))] }
        let threshold = r * sum
        var acc = 0.0
        for (i, w) in weights.enumerated() {
            acc += w
            if threshold < acc { return list[i] }
        }
        return list.last
    }

    private static func pickVariant(_ a: JSONObject, _ input: Input) -> (variant: JSONObject, from: String)? {
        let variants = (a["variants"]?.arrayValue ?? []).compactMap { $0.objectValue }
        let id = a["id"]?.stringValue ?? ""
        if let stored = input.assignments[id], let v = variants.first(where: { $0["id"]?.stringValue == stored.variant_id }) {
            return (v, "stored")
        }
        let server = (input.config["assignments_v2"]?.arrayValue ?? []).compactMap { $0.objectValue }
            .first { $0["audience_id"]?.stringValue == id }
        if let server, let v = variants.first(where: { $0["id"]?.stringValue == server["variant_id"]?.stringValue }) {
            return (v, "server")
        }
        return chooseVariant(variants, random: input.random).map { ($0, "random") }
    }

    private static func matchIn(_ audiences: [JSONValue]?, _ input: Input, _ ctx: RuleContext,
                                _ unmatched: inout [String: String]) -> JSONObject? {
        for raw in audiences ?? [] {
            guard let a = raw.objectValue, let id = a["id"]?.stringValue else { continue }
            if let why = mismatch(a, input, ctx) { unmatched[id] = why } else { return a }
        }
        return nil
    }

    static func resolve(_ input: Input) -> Resolution {
        let config = input.config
        let paywalls = config["campaign_paywalls"]?.objectValue ?? [:]
        if let ov = config["override"]?.objectValue, let pid = ov["paywall_id"]?.stringValue,
           let until = millis(ov["expires_at"]?.stringValue), until > input.now, let pw = paywalls[pid]?.objectValue {
            var r = Resolution(.paywall)
            r.source = "override"
            r.paywallId = pid
            r.paywall = pw
            return r
        }
        guard let entry = config["placements"]?[input.placement]?.objectValue else {
            var r = Resolution(.placement_not_found)
            r.skipReason = "placement_not_found"
            return r
        }
        if entry["enabled"]?.boolValue == false {
            var r = Resolution(.placement_paused)
            r.skipReason = "placement_paused"
            r.campaignId = entry["campaign_id"]?.stringValue
            return r
        }
        var ctx = input.context
        ctx.params = input.params
        ctx.eventName = input.placement
        ctx.now = input.now
        let occ = input.occurrences
        ctx.occurrences = { occ[Occurrences.triggerKey($0)] ?? [] }

        var unmatched: [String: String] = [:]
        var source = "campaign"
        var campaignId = entry["campaign_id"]?.stringValue
        var audience = matchIn(entry["audiences"]?.arrayValue, input, ctx, &unmatched)
        if audience == nil, let def = config["default_campaign"]?.objectValue, let list = def["audiences"]?.arrayValue {
            audience = matchIn(list, input, ctx, &unmatched)
            if audience != nil {
                source = "default_campaign"
                campaignId = def["campaign_id"]?.stringValue
            }
        }
        guard let audience, let audienceId = audience["id"]?.stringValue else {
            var r = Resolution(.no_audience_match)
            r.campaignId = entry["campaign_id"]?.stringValue
            r.unmatched = unmatched
            r.skipReason = input.subscribed && unmatched.values.contains("entitlement") ? "user_is_subscribed" : "no_audience_match"
            return r
        }
        func base(_ t: ResolutionType) -> Resolution {
            var r = Resolution(t)
            r.source = source
            r.campaignId = campaignId
            r.audienceId = audienceId
            r.experimentId = audience["experiment_id"]?.stringValue
            r.unmatched = unmatched
            return r
        }
        guard let picked = pickVariant(audience, input), let variantId = picked.variant["id"]?.stringValue else {
            return base(.paywall_not_available)
        }
        let decision = Decision(audienceId: audienceId, variantId: variantId, experimentId: audience["experiment_id"]?.stringValue,
                                placement: input.placement, from: picked.from)
        if picked.variant["type"]?.stringValue == "holdout" {
            var r = base(.holdout)
            r.variantId = variantId
            r.assignment = decision
            r.skipReason = "holdout"
            return r
        }
        let paywallId = picked.variant["paywall_id"]?.stringValue
        guard let paywallId, let pw = paywalls[paywallId]?.objectValue else {
            var r = base(.paywall_not_available)
            r.variantId = variantId
            r.paywallId = paywallId
            r.assignment = decision
            return r
        }
        var r = base(.paywall)
        r.variantId = variantId
        r.paywallId = paywallId
        r.paywall = pw
        r.assignment = decision
        return r
    }
}
