import Foundation

/// The ids an event was recorded under. A batch carries one identity, so an
/// event logged before `identify` or `logout` is sent as the user it was.
struct EventIds: Codable, Equatable {
    var deviceId: String
    var accountId: String?
    var revenuecatId: String?
}

enum EventStatus: String, Codable {
    case success, failure, info
}

struct QueuedEvent: Codable, Equatable {
    var event_name: String
    var status: EventStatus
    var properties: JSONObject
    var uuid: String
    var timestamp: String
    var size: Int
    var ids: EventIds

    /// What goes on the wire.
    struct Wire: Codable, Equatable {
        var event_name: String
        var status: EventStatus
        var properties: JSONObject
        var uuid: String
        var timestamp: String
    }

    var wire: Wire { Wire(event_name: event_name, status: status, properties: properties, uuid: uuid, timestamp: timestamp) }
}

/// The batch body for POST /api/v1/events/log (the React Native SDK's envelope).
struct EventBatch: Encodable {
    var revenuecat_id: String?
    var attribution: JSONObject?
    var attributes: JSONObject?
    var attributes_set_once: JSONObject?
    var attributes_unset: [String]?
    var platform: String
    var app_version: String?
    var country: String?
    var client_dropped: Int?
    var client_dropped_reasons: [String: Int]?
    var sent_at: String
    var events: [QueuedEvent.Wire]

    enum CodingKeys: String, CodingKey {
        case revenuecat_id, attribution, attributes, attributes_set_once, attributes_unset, platform, app_version,
             country, client_dropped, client_dropped_reasons, sent_at, events
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // revenuecat_id is always present, null when unknown, as the React Native SDK sends it.
        try c.encode(revenuecat_id, forKey: .revenuecat_id)
        try c.encodeIfPresent(attribution, forKey: .attribution)
        try c.encodeIfPresent(attributes, forKey: .attributes)
        try c.encodeIfPresent(attributes_set_once, forKey: .attributes_set_once)
        try c.encodeIfPresent(attributes_unset, forKey: .attributes_unset)
        try c.encode(platform, forKey: .platform)
        try c.encodeIfPresent(app_version, forKey: .app_version)
        try c.encodeIfPresent(country, forKey: .country)
        try c.encodeIfPresent(client_dropped, forKey: .client_dropped)
        try c.encodeIfPresent(client_dropped_reasons, forKey: .client_dropped_reasons)
        try c.encode(sent_at, forKey: .sent_at)
        try c.encode(events, forKey: .events)
    }
}

/// Persistent attribute changes waiting for the server to store them.
struct AttributeState: Codable, Equatable {
    var set: JSONObject = [:]
    var setOnce: JSONObject = [:]
    var pendingOnce: [String] = []
    var pendingUnset: [String] = []
    var dirty = false
    var version = 0
}
