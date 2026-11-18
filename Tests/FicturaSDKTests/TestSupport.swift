import Foundation
import XCTest
@testable import FicturaSDK

/// A fake server: records requests, answers with queued responses (default 200 `{}`).
final class FakeTransport: Transport {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var responses: [HTTPResult] = []
    var answer: ((URLRequest) -> HTTPResult)?

    func send(_ request: URLRequest, completion: @escaping (HTTPResult) -> Void) {
        lock.lock()
        requests.append(request)
        let result: HTTPResult
        if let answer { result = answer(request) }
        else if !responses.isEmpty { result = responses.removeFirst() }
        else { result = .response(status: 200, headers: [:], body: Data("{}".utf8)) }
        lock.unlock()
        DispatchQueue.global().async { completion(result) }
    }

    func requests(to path: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.path == path }
    }

    static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> HTTPResult {
        .response(status: status, headers: headers, body: Data(body.utf8))
    }
}

func body(_ r: URLRequest) -> JSONObject { JSON.parse(r.httpBody)?.objectValue ?? [:] }

final class Clock {
    var now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.now = now }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

func makeCore(transport: FakeTransport = FakeTransport(), store: KeyValueStore = MemoryStore(),
              keychain: SecureStore = MemorySecureStore(), clock: Clock = Clock(), options: FicturaOptions = {
                  var o = FicturaOptions(); o.apiBase = URL(string: "https://api.test")!; o.flushInterval = 3600; return o
              }()) -> FicturaCore {
    FicturaCore(options: options, api: API(base: options.apiBase, apiKey: "gk_test"), store: store,
                device: DeviceIdentity(keychain: keychain), transport: transport, now: { clock.now }, random: { 0.5 },
                everyEvent: ["$lib": .string(SDKInfo.lib), "$lib_version": .string(SDKInfo.version), "$os": .string("iOS")])
}

/// Flushes and waits until the core settles.
func flushAndWait(_ core: FicturaCore, file: StaticString = #filePath, line: UInt = #line) {
    let e = XCTestExpectation(description: "flush")
    core.flush { e.fulfill() }
    let r = XCTWaiter().wait(for: [e], timeout: 5)
    XCTAssertEqual(r, .completed, "flush did not finish", file: file, line: line)
}

func loadVectors() throws -> JSONObject {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "rn_vectors", withExtension: "json", subdirectory: "Vectors"))
    return try XCTUnwrap(JSON.parse(try Data(contentsOf: url))?.objectValue)
}
