import ActivityKit

struct VoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String
    }
    var name: String
}
