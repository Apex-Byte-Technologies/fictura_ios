import XCTest
@testable import FicturaSDK

/// Values computed by the React Native SDK's own functions (Vectors/rn_vectors.json):
/// both SDKs must sample, seed and compare versions identically.
final class ParityTests: XCTestCase {
    func testSamplingBucketsMatchReactNative() throws {
        for v in try loadVectors()["sampling"]?.arrayValue ?? [] {
            let got = Sampling.bucket(deviceId: v["device_id"]!.stringValue!, event: v["event"]!.stringValue!)
            XCTAssertEqual(got, v["bucket"]!.doubleValue!, accuracy: 1e-12)
        }
    }

    func testUserSeedsMatchReactNative() throws {
        let seeds = try loadVectors()["seeds"]?.arrayValue ?? []
        XCTAssertFalse(seeds.isEmpty)
        for v in seeds {
            XCTAssertEqual(Placements.seed(forUser: v["user_id"]!.stringValue!), v["seed"]!.intValue!, v["user_id"]!.stringValue!)
        }
    }

    func testVersionComparisonMatchesReactNative() throws {
        for v in try loadVectors()["versions"]?.arrayValue ?? [] {
            let got = PlacementRules.compareVersions(v["a"]!, v["b"]!)
            XCTAssertEqual(got, v["cmp"]?.intValue, "\(v)")
        }
    }

    func testSampleKeepEdges() {
        XCTAssertTrue(Sampling.keep(deviceId: "d", event: "e", rate: 1))
        XCTAssertFalse(Sampling.keep(deviceId: "d", event: "e", rate: 0))
        XCTAssertTrue(Sampling.keep(deviceId: nil, event: "e", rate: 0.1))
    }

    func testUUIDv7IsTimeOrderedAndVersioned() {
        let a = IDs.uuidv7(Date(timeIntervalSince1970: 1_800_000_000))
        let b = IDs.uuidv7(Date(timeIntervalSince1970: 1_800_000_001))
        XCTAssertLessThan(a, b)
        XCTAssertEqual(Array(a)[14], "7")
        XCTAssertTrue("89ab".contains(Array(a)[19]))
    }
}

final class DeliveryTests: XCTestCase {
    func testBackoffIsFullJitterCapped() {
        XCTAssertEqual(Delivery.backoff(attempt: 1, random: 0.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(Delivery.backoff(attempt: 3, random: 0.5), 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(Delivery.backoff(attempt: 40, random: 0.999), Delivery.retryCap)
    }

    func testRetryAfter() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Delivery.retryAfter("120", now: now), 120)
        XCTAssertNil(Delivery.retryAfter("-5", now: now))
        XCTAssertEqual(Delivery.retryAfter("Thu, 01 Jan 1970 00:01:00 GMT", now: now), 60)
        XCTAssertNil(Delivery.retryAfter("soon", now: now))
    }

    func testTruncateNeverSplitsSurrogates() {
        let s = String(repeating: "a", count: 1023) + "😀"
        XCTAssertEqual(Delivery.truncate(s).utf16.count, 1023)
    }

    func testCapKeepsSdkKeysFirst() {
        var props: JSONObject = [:]
        for i in 0..<300 { props["k\(i)"] = .int(i) }
        props["$session_id"] = .string("s")
        let capped = Delivery.capProperties(props, keepFirst: ["$session_id"])
        XCTAssertEqual(capped.count, 255)
        XCTAssertEqual(capped["$session_id"], .string("s"))
    }
}
