import Foundation

/// One HTTP exchange. Tests replace it.
protocol Transport: AnyObject {
    func send(_ request: URLRequest, completion: @escaping (HTTPResult) -> Void)
}

enum HTTPResult {
    /// Any HTTP answer, 2xx or not.
    case response(status: Int, headers: [String: String], body: Data)
    /// Offline, DNS, TLS, timeout.
    case failure(Error)

    var status: Int? { if case .response(let s, _, _) = self { return s }; return nil }
    var body: Data? { if case .response(_, _, let b) = self { return b }; return nil }
    var ok: Bool { (status.map { (200..<300).contains($0) }) ?? false }
    func header(_ name: String) -> String? {
        guard case .response(_, let headers, _) = self else { return nil }
        return headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

final class URLSessionTransport: Transport {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Delivery.requestTimeout
        config.waitsForConnectivity = false
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func send(_ request: URLRequest, completion: @escaping (HTTPResult) -> Void) {
        let task = session.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields { headers[String(describing: k)] = String(describing: v) }
                completion(.response(status: http.statusCode, headers: headers, body: data ?? Data()))
            } else {
                completion(.failure(error ?? URLError(.badServerResponse)))
            }
        }
        // Fictura's own calls are never traced as the app's network calls.
        task.taskDescription = "fictura"
        task.resume()
    }
}

/// Builds requests to the Fictura API with the headers every call carries.
struct API {
    let base: URL
    let apiKey: String

    func request(_ path: String, method: String = "GET", query: [String: String?] = [:], body: Data? = nil,
                 deviceId: String? = nil, accountId: String? = nil) -> URLRequest? {
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { comps.queryItems = items }
        guard let url = comps.url else { return nil }
        var r = URLRequest(url: url, timeoutInterval: Delivery.requestTimeout)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue(SDKInfo.header, forHTTPHeaderField: "x-fictura-sdk")
        if let deviceId { r.setValue(deviceId, forHTTPHeaderField: "X-Device-ID") }
        if let accountId { r.setValue(accountId, forHTTPHeaderField: "X-Account-ID") }
        r.httpBody = body
        return r
    }
}
