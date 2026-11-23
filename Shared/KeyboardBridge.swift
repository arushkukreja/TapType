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

/// Which app owns a process ID, learned whenever iOS reports it. iOS can report a stale
/// current app (the Home Screen) at the moment of a tap while still giving the host's
/// PID, so the mapping is kept for ten minutes (uptime-based, shared via the app group);
/// iOS doesn't reuse a PID that quickly.
struct HostReturnCache {
    static let lifetime: TimeInterval = 600
    private var values: [Int: (bundle: String, observed: TimeInterval)] = [:]
    var count: Int { values.count }

    init() {}
    init(_ stored: [String: Any]) {
        for (key, value) in stored {
            guard let pid = Int(key), let entry = value as? [String: Any],
                  let bundle = entry["bundle"] as? String, let observed = entry["observed"] as? Double else { continue }
            values[pid] = (bundle, observed)
        }
    }
    var dictionary: [String: Any] {
        Dictionary(uniqueKeysWithValues: values.map { (String($0.key), ["bundle": $0.value.bundle, "observed": $0.value.observed] as [String: Any]) })
    }

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
    static var group: String {
        Bundle.main.object(forInfoDictionaryKey: "TapTypeAppGroup") as? String ?? "group.com.example.TapType"
    }
    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
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
    static func command(_ action: String, requestID: String = "", purpose: DictationPurpose = .dictate) {
        write(["id": UUID().uuidString, "action": action, "requestID": requestID, "purpose": purpose.rawValue,
               "time": Date().timeIntervalSince1970], to: "command.json")
        BridgeSignal.post(.command)
    }
}

/// Settings the keyboard shows and can change. They live in the app group so the app
/// and keyboard always agree; the keyboard needs Full Access to write them.
enum SharedSettings {
    static let file = "settings.json"
    /// Speaking styles in menu order: stored value and title.
    static let styles: [(id: String, title: String)] = [
        ("natural", "As spoken"), ("formal", "Formal"), ("casual", "Casual"),
        ("veryCasual", "Very casual"), ("excited", "Excited")
    ]
    static func styleTitle(_ id: String) -> String { styles.first { $0.id == id }?.title ?? "As spoken" }
    static var speakingStyle: String {
        let value = KeyboardBridge.read(file)["speakingStyle"] as? String ?? ""
        return styles.contains { $0.id == value } ? value : "natural"
    }
    /// The app's "Your words" choice, mirrored so the keyboard can hide styles for Original.
    static var cleanupMode: String { KeyboardBridge.read(file)["cleanupMode"] as? String ?? "cleanup" }
    static func set(_ key: String, _ value: String) {
        var values = KeyboardBridge.read(file)
        guard values[key] as? String != value else { return }
        values[key] = value
        KeyboardBridge.write(values, to: file)
    }
}

/// Instant wake-ups between the app and keyboard, so neither side waits for its
/// next polling tick. Darwin notifications carry no data: the receiver still reads
/// the shared files, and the existing timers remain as a fallback.
final class BridgeSignal: @unchecked Sendable {
    enum Kind: String, Sendable { case state, command }

    static func name(_ kind: Kind) -> String { "\(KeyboardBridge.group).bridge.\(kind.rawValue)" }

    static func post(_ kind: Kind) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name(kind) as CFString), nil, nil, true)
    }

    private let kind: Kind
    private let handler: @MainActor () -> Void

    /// Calls `handler` on the main thread whenever the other process posts `kind`.
    /// Observation stops when this object is released.
    init(observing kind: Kind, handler: @escaping @MainActor () -> Void) {
        self.kind = kind
        self.handler = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        { _, observer, _, _, _ in
                                            guard let observer else { return }
                                            let signal = Unmanaged<BridgeSignal>.fromOpaque(observer).takeUnretainedValue()
                                            let handler = signal.handler
                                            DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
                                        },
                                        Self.name(kind) as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                           Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(Self.name(kind) as CFString), nil)
    }
}

struct DictationTicket {
    static let lifetime: TimeInterval = 35 * 60
    let id: String
    let document: String
    let created: Double
    var committed: Bool
    /// Edit and review tickets carry instructions; their words are never inserted.
    var purpose: DictationPurpose

    init(document: String, id: String = UUID().uuidString, now: Double = Date().timeIntervalSince1970,
         purpose: DictationPurpose = .dictate) {
        self.id = id; self.document = document; created = now; committed = false; self.purpose = purpose
    }
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let document = value["document"] as? String,
              let created = value["created"] as? Double else { return nil }
        self.id = id; self.document = document; self.created = created
        committed = value["committed"] as? Bool ?? false
        purpose = DictationPurpose(value["purpose"])
    }
    var dictionary: [String: Any] {
        ["id": id, "document": document, "created": created, "committed": committed, "purpose": purpose.rawValue]
    }
    func textToInsert(from state: [String: Any], document: String, insertedID: String?,
                      now: Double = Date().timeIntervalSince1970) -> String? {
        guard purpose == .dictate, DictationPurpose(state["purpose"]) == .dictate,
              committed, self.document == document, now - created >= 0, now - created < Self.lifetime,
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

/// A recognized word with its time in the recording, in seconds.
struct TimedWord: Equatable, Sendable {
    /// Includes a leading space when it starts a new word (punctuation attaches without one).
    let text: String
    let start: Double
    let end: Double
    var center: Double { (start + end) / 2 }
}

/// Decides which words are final when long speech is cut without a pause. Words near a
/// cut are guessed without hearing what follows, so the model may end a sentence there
/// or mishear a word. Only words ending well before the cut are committed; the rest are
/// decoded again with the next phrase, together with some audio already committed so the
/// model knows the sentence is continuing. Times are absolute; overlapping decodes are
/// reconciled by keeping only words centered after the last committed point.
struct PhraseBoundaryWindow {
    static let rightContext = 1.5
    static let leftContext = 2.0
    /// Never hold back more than this much audio; commit everything instead.
    static let maxCarry = 8.0
    private(set) var committedThrough = -Double.infinity

    /// `words` come from decoding audio that ends at `audioEnd`. `atPause` means the phrase
    /// ended in silence (or the recording ended), so every word can be committed. Returns
    /// the words to commit and where the next decode's audio should start, or nil to carry none.
    mutating func split(_ words: [TimedWord], audioEnd: Double, atPause: Bool) -> (commit: [TimedWord], keepFrom: Double?) {
        let fresh = words.filter { $0.center >= committedThrough }
        let limit = audioEnd - Self.rightContext
        guard !atPause, let next = fresh.firstIndex(where: { $0.end > limit }) else {
            committedThrough = audioEnd
            return (fresh, nil)
        }
        // Don't cut inside a word: a token without a leading space continues the previous one.
        var boundary = next
        while boundary > 0, !fresh[boundary].text.hasPrefix(" ") { boundary -= 1 }
        let commit = Array(fresh[..<boundary])
        let held = fresh[boundary...]
        guard let first = held.first, audioEnd - first.start <= Self.maxCarry else {
            committedThrough = audioEnd
            return (fresh, nil)
        }
        if let last = commit.last { committedThrough = (last.end + first.start) / 2 }
        else { committedThrough = max(committedThrough, first.start - 0.04) }
        return (commit, max(0, first.start - Self.leftContext))
    }
    mutating func reset() { committedThrough = -Double.infinity }
}

/// Removes what speech models write for sounds rather than speech: bracketed labels
/// such as "(music)" or "[BLANK_AUDIO]", and whole-phrase phantom captions Whisper is
/// known to produce on near-silence ("Thanks for watching!"). Short phrases people really
/// dictate, like "Thank you." or "Okay.", are kept.
enum TranscriptArtifacts {
    static let phantomPhrases: Set<String> = [
        "thanks for watching", "thank you for watching", "thanks for watching and see you next time",
        "please subscribe", "subscribe to my channel", "like and subscribe"
    ]
    static func cleaned(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"\s*[\(\[][^\)\]]{0,40}[\)\]]\s*"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[♪♫*]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = value.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return phantomPhrases.contains(bare) ? "" : value
    }
}

// Whisper's short, independent phrase decodes can occasionally repeat the end
// of one decode at the beginning of the next. Remove only an immediate echo;
// separate, deliberately repeated dictation remains untouched.
enum TranscriptEchoReducer {
    private static func normalized(_ word: Substring) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    static func removingLeadingEcho(from text: String, after previous: String) -> String {
        let incoming = text.split(whereSeparator: \.isWhitespace)
        let prior = previous.split(whereSeparator: \.isWhitespace)
        guard !incoming.isEmpty, !prior.isEmpty else { return text }
        let limit = min(12, incoming.count, prior.count)
        for count in stride(from: limit, through: 2, by: -1) {
            let tail = prior.suffix(count).map(normalized)
            let head = incoming.prefix(count).map(normalized)
            guard !tail.contains(""), tail == head else { continue }
            return incoming.dropFirst(count).joined(separator: " ")
        }
        return text
    }

    static func removingImmediateEchoes(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count > 1 else { return text }
        var result: [Substring] = []
        var index = 0
        while index < words.count {
            let limit = min(12, result.count, words.count - index)
            var echoed = 0
            if limit >= 2 {
                for count in stride(from: limit, through: 2, by: -1) {
                    let tail = result.suffix(count).map(normalized)
                    let head = words[index..<(index + count)].map(normalized)
                    if !tail.contains(""), tail == head { echoed = count; break }
                }
            }
            if echoed > 0 { index += echoed }
            else { result.append(words[index]); index += 1 }
        }
        return result.joined(separator: " ")
    }
}
