import Foundation

enum DictationLatency {
    static func begin(id: String) {
        let existing = KeyboardBridge.read("latency.json")
        guard existing["id"] as? String != id else { return }
        KeyboardBridge.write(["id": id, "checked": ProcessInfo.processInfo.systemUptime], to: "latency.json")
    }
    static func mark(_ stage: String, id: String) {
        var value = KeyboardBridge.read("latency.json")
        guard value["id"] as? String == id else { return }
        value[stage] = ProcessInfo.processInfo.systemUptime
        KeyboardBridge.write(value, to: "latency.json")
    }
    static var measurements: [String: Double] {
        let value = KeyboardBridge.read("latency.json")
        guard let checked = value["checked"] as? Double else { return [:] }
        var result: [String: Double] = [:]
        for stage in ["transcribed", "cleaned", "inserted"] {
            if let time = value[stage] as? Double, (0..<600).contains(time - checked) { result[stage] = time - checked }
        }
        return result
    }
}

enum HostReturnIdentity {
    static func keyboardHost(_ marker: [String: Any], requestID: String, document: String,
                             own: String, now: Date = Date()) -> String? {
        guard marker["id"] as? String == requestID,
              marker["document"] as? String == document,
              let time = marker["time"] as? Double, time.isFinite,
              (0..<8).contains(now.timeIntervalSince1970 - time),
              let host = marker["host"] as? String else { return nil }
        return externalHost(host, own: own)
    }
    static func handoffStarted(_ marker: [String: Any], requestID: String, document: String, arrived: Date) -> Date? {
        guard marker["id"] as? String == requestID, marker["document"] as? String == document,
              let time = marker["time"] as? Double, time.isFinite,
              (0..<8).contains(arrived.timeIntervalSince1970 - time) else { return nil }
        return Date(timeIntervalSince1970: time)
    }
    static func externalHost(_ observed: String, own: String) -> String? {
        let bundle = observed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty, !bundle.isEmpty, bundle.count < 256,
              bundle.contains("."), !bundle.contains(where: { $0.isWhitespace }),
              bundle.lowercased() != own.lowercased(),
              !bundle.lowercased().hasPrefix(own.lowercased() + ".") else { return nil }
        return registeredCase(bundle)
    }
    static func registeredCase(_ observed: String) -> String {
        // Casing corrections, not an app allowlist. These registered identifiers
        // were verified on the test device; unknown hosts pass through unchanged.
        switch observed.lowercased() {
        case "com.apple.mobilesms": return "com.apple.MobileSMS"
        case "net.whatsapp.whatsapp": return "net.whatsapp.WhatsApp"
        default: return observed
        }
    }
}

struct HostReturnCache {
    static let lifetime: TimeInterval = 8
    private var values: [Int: (bundle: String, observed: TimeInterval)] = [:]
    var count: Int { values.count }

    mutating func observe(pid: Int, bundle: String, now: TimeInterval) {
        guard pid > 0, now.isFinite, !bundle.isEmpty else { return }
        prune(now: now)
        values[pid] = (bundle, now)
    }

    mutating func bundle(for pid: Int, now: TimeInterval) -> String? {
        guard pid > 0, now.isFinite else { return nil }
        prune(now: now)
        return values[pid]?.bundle
    }

    private mutating func prune(now: TimeInterval) {
        values = values.filter {
            let age = now - $0.value.observed
            return (0..<Self.lifetime).contains(age)
        }
    }
}

enum KeyboardBridge {
    static var hasRecentHandoff: Bool {
        let age = Date().timeIntervalSince1970 - (read("handoff.json")["time"] as? Double ?? 0)
        return age >= 0 && age < 8
    }
    static var root: URL? {
        let group = Bundle.main.object(forInfoDictionaryKey: "TapTypeAppGroup") as? String ?? "group.com.example.TapType"
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    static func write(_ value: [String: Any], to name: String) {
        guard let url = root?.appendingPathComponent(name),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        try? data.write(to: url, options: .atomic)
    }
    static func read(_ name: String) -> [String: Any] {
        guard let url = root?.appendingPathComponent(name), let data = try? Data(contentsOf: url),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
    static func command(_ action: String, requestID: String = "") {
        write(["id": UUID().uuidString, "action": action, "requestID": requestID,
               "time": Date().timeIntervalSince1970], to: "command.json")
    }
}

struct DictationTicket {
    static let lifetime: TimeInterval = 35 * 60
    let id: String
    let document: String
    let created: Double
    var committed: Bool

    init(document: String, id: String = UUID().uuidString, now: Double = Date().timeIntervalSince1970) {
        self.id = id; self.document = document; created = now; committed = false
    }
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let document = value["document"] as? String,
              let created = value["created"] as? Double else { return nil }
        self.id = id; self.document = document; self.created = created
        committed = value["committed"] as? Bool ?? false
    }
    var dictionary: [String: Any] {
        ["id": id, "document": document, "created": created, "committed": committed]
    }
    func textToInsert(from state: [String: Any], document: String, insertedID: String?,
                      now: Double = Date().timeIntervalSince1970) -> String? {
        guard committed, self.document == document, now - created >= 0, now - created < Self.lifetime,
              id != insertedID, state["transcriptID"] as? String == id,
              state["final"] as? Bool == true,
              state["recording"] as? Bool != true, state["processing"] as? Bool != true,
              (state["error"] as? String ?? "").isEmpty,
              let text = state["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

// Presentation only. A pending handoff never authorizes recording or insertion.
enum KeyboardHandoff {
    // Appearance callbacks alone can run during the outgoing switch. Wait for
    // the actual return signal and/or a host reactivation, then let iOS settle.
    static func canReveal(created: Double, returnTime: Double?, hostResumedAt: Double?,
                          hostInactive: Bool, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard !hostInactive, now >= created else { return false }
        let validReturn = returnTime.flatMap { $0 >= created && $0 <= now ? $0 : nil }
        let validResume = hostResumedAt.flatMap { $0 >= created && $0 <= now ? $0 : nil }
        if validReturn != nil || validResume != nil {
            let deadline = max(validReturn.map { $0 + 1.2 } ?? 0, validResume.map { $0 + 0.65 } ?? 0)
            return now >= deadline
        }
        // Recover from a cancelled opening prompt or a missing lifecycle signal.
        return now - created >= 12
    }

    static func isPending(_ value: [String: Any], document: String,
                          state: [String: Any], now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let id = value["id"] as? String, !id.isEmpty,
              value["document"] as? String == document,
              let created = value["time"] as? Double,
              now >= created, now - created < 8 else { return false }
        return state["transcriptID"] as? String != id
    }
}


// Monotonic idle timeout. Finishing/cleanup must not extend the user's five minutes.
struct MicrophoneReadinessWindow {
    static let duration: TimeInterval = 5 * 60
    private(set) var deadline: TimeInterval?
    mutating func beginIdle(now: TimeInterval, minutes: Int = 5) {
        if deadline == nil { deadline = minutes == -1 ? .infinity : now + Double(max(0, minutes)) * 60 }
    }
    mutating func reset() { deadline = nil }
    func isOpen(now: TimeInterval) -> Bool { deadline.map { now < $0 } ?? false }
}

// Zero means no idle input; -1 means no automatic idle timeout.
enum ReadySessionOptions {
    static let minutes = [0, 1, 2, 3, 5, 10, -1]
    static func validated(_ value: Int?) -> Int { value.flatMap { minutes.contains($0) ? $0 : nil } ?? 5 }
    static func title(_ value: Int) -> String {
        value == 0 ? "Off" : value == -1 ? "Until I end it" : "\(value) \(value == 1 ? "minute" : "minutes")"
    }
}
