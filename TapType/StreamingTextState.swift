import Foundation
import NaturalLanguage

struct SpeechSpan: Sendable, Equatable {
    let start: Double
    let end: Double
    let text: String
    let isFinal: Bool
    func overlaps(_ other: Self) -> Bool { start < other.end - 0.0001 && end > other.start + 0.0001 }
}

struct CleanupPhrase: Sendable, Identifiable {
    let id: UUID
    let raw: String
    let correction: Bool
    var refined: String?
    var draft: String?
}

struct DictationTextSnapshot: Sendable {
    var raw = ""
    var provisional = ""
    var finalized = ""
    var refined = ""
    var display = ""
    var notice: String?
}

// Only this value type decides which speech is stable and which cleanup may replace it.
struct StreamingTextState: Sendable {
    enum Phase: Sendable { case recording, finalizing, finished, cancelled }
    private(set) var phase = Phase.recording
    private(set) var spans: [SpeechSpan] = []
    private(set) var phrases: [CleanupPhrase] = []
    private(set) var pending = ""
    private var pauseThrough = -Double.infinity
    private(set) var recognitionEnded = false
    var notice: String?
    static func joined(_ values: [String]) -> String { values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ") }
    static func correctionCue(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["actually", "sorry,", "sorry ", "no,", "no i mean", "i mean", "correction", "rather,"].contains { value.hasPrefix($0) }
    }
    static func containsCorrection(_ text: String) -> Bool {
        text.range(of: #"(?i)(?:^|[.!?]\s+|\s)(?:actually[, ]|sorry[, ]|i mean\b|correction[, :])"#, options: .regularExpression) != nil
    }
    @discardableResult mutating func receive(_ span: SpeechSpan) -> Bool {
        guard phase == .recording || phase == .finalizing, !recognitionEnded,
              span.start.isFinite, span.end.isFinite, span.start >= 0, span.end >= span.start,
              span.text.count < 20_000 else { return false }
        if spans.contains(span) { return false }
        // A volatile revision must never roll back a range already finalized by Speech.
        if !span.isFinal && spans.contains(where: { $0.isFinal && $0.overlaps(span) }) { return false }
        spans.removeAll { $0.overlaps(span) || (abs($0.start - span.start) < 0.0001 && abs($0.end - span.end) < 0.0001) }
        if !span.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { spans.append(span) }
        spans.sort { $0.start < $1.start }
        rebuild()
        return true
    }
    mutating func silence(through time: Double) {
        guard time.isFinite, phase == .recording || phase == .finalizing else { return }
        pauseThrough = max(pauseThrough, time); rebuild()
    }
    mutating func beginStop() { if phase == .recording { phase = .finalizing } }
    mutating func finishRecognition() {
        guard phase != .cancelled else { return }
        recognitionEnded = true
        if spans.contains(where: { !$0.isFinal }) { notice = "Some speech couldn’t be finalized. Only confirmed words are included." }
        spans.removeAll { !$0.isFinal }
        rebuild()
    }
    mutating func finish() { guard phase != .cancelled else { return }; phase = .finished }
    mutating func cancel() { phase = .cancelled; spans.removeAll(); phrases.removeAll(); pending = "" }
    mutating func refine(id: UUID, text: String, completed: Bool) {
        guard phase != .cancelled && phase != .finished, let i = phrases.firstIndex(where: { $0.id == id }) else { return }
        if completed { phrases[i].refined = text; phrases[i].draft = nil }
        else { phrases[i].draft = text }
    }
    mutating func preservePending(_ message: String) {
        notice = message
        for i in phrases.indices where phrases[i].refined == nil { phrases[i].refined = phrases[i].raw; phrases[i].draft = nil }
    }
    var next: CleanupPhrase? { phrases.first { $0.refined == nil } }
    var snapshot: DictationTextSnapshot {
        let finalized = Self.joined(spans.filter(\.isFinal).map(\.text))
        let provisional = Self.joined(spans.filter { !$0.isFinal }.map(\.text))
        let refined = Self.joined(phrases.compactMap(\.refined))
        let display = Self.joined(phrases.map { $0.draft ?? $0.refined ?? $0.raw } + [pending, provisional])
        return .init(raw: Self.joined(spans.map(\.text)), provisional: provisional, finalized: finalized,
                     refined: refined, display: display, notice: notice)
    }
    private mutating func rebuild() {
        var units: [(String, Bool)] = [], accumulated = ""
        // Stop at the first volatile range: later finalized spans cannot jump ahead of it.
        for span in spans {
            guard span.isFinal else { break }
            accumulated = Self.joined([accumulated, span.text])
            let terminal = accumulated.last.map { ".!?。！？".contains($0) } ?? false
            if terminal || span.end <= pauseThrough || accumulated.count >= 600 || recognitionEnded {
                let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = accumulated
                tokenizer.enumerateTokens(in: accumulated.startIndex..<accumulated.endIndex) { range, _ in
                    let sentence = String(accumulated[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sentence.isEmpty {
                        // Bound each request without cutting a word in half.
                        var chunk = ""
                        for word in sentence.split(whereSeparator: \.isWhitespace) {
                            if chunk.count + word.count > 600 && !chunk.isEmpty { units.append((chunk, false)); chunk = "" }
                            chunk = Self.joined([chunk, String(word)])
                        }
                        if !chunk.isEmpty { units.append((chunk, false)) }
                    }
                    return true
                }
                accumulated = ""
            }
        }
        pending = accumulated
        var grouped: [(String, Bool)] = []
        for (text, _) in units {
            if Self.correctionCue(text), let previous = grouped.last, previous.0.count + text.count < 1200 {
                grouped.removeLast(); grouped.append((Self.joined([previous.0, text]), true))
            } else { grouped.append((text, false)) }
        }
        let old = phrases
        var prefixUnchanged = true
        phrases = grouped.enumerated().map { index, item in
            if prefixUnchanged, index < old.count, old[index].raw == item.0, old[index].correction == (item.1 || Self.containsCorrection(item.0)) { return old[index] }
            prefixUnchanged = false
            return CleanupPhrase(id: UUID(), raw: item.0, correction: item.1 || Self.containsCorrection(item.0))
        }
    }
}
