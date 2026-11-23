import Foundation

// Edit by voice. The keyboard sends the text it can see and a spoken instruction; the
// app asks a writing model for changes; the keyboard shows them for approval and only
// then edits the text field. Everything here is plain logic shared by both sides.

/// What a dictation is for. Edit and review dictations are instructions, never inserted.
enum DictationPurpose: String, Sendable {
    case dictate, edit, review
    init(_ value: Any?) { self = (value as? String).flatMap(Self.init(rawValue:)) ?? .dictate }
}

/// The "Edit by voice" switch in the TapType app. Stored in the App Group so the
/// keyboard can read it.
enum VoiceEditPreference {
    static let key = "voiceEditEnabled"
    private static var store: UserDefaults? { UserDefaults(suiteName: KeyboardBridge.group) }
    static var enabled: Bool {
        get { store?.object(forKey: key) as? Bool ?? true }
        set { store?.set(newValue, forKey: key) }
    }
}

/// The text the keyboard can see around the cursor. iOS gives a keyboard only part of
/// a long document, so edits are limited to this text.
struct VoiceEditContext: Equatable, Sendable {
    var before: String
    var selected: String
    var after: String
    var full: String { before + selected + after }
    /// Where the cursor (or the start of the selection) is, in characters.
    var cursor: Int { before.count }
    var selectionRange: Range<Int>? { selected.isEmpty ? nil : before.count..<(before.count + selected.count) }
    var dictionary: [String: Any] { ["before": before, "selected": selected, "after": after] }
    init(before: String, selected: String = "", after: String = "") {
        self.before = before; self.selected = selected; self.after = after
    }
    init?(_ value: [String: Any]?) {
        guard let value, let before = value["before"] as? String, let after = value["after"] as? String else { return nil }
        self.init(before: before, selected: value["selected"] as? String ?? "", after: after)
    }
}

/// One suggested change: replace `original` (quoted exactly from the text) with `replacement`.
struct VoiceEditChange: Equatable, Sendable {
    var original: String
    var replacement: String
    var pair: [String] { [original, replacement] }
    init(original: String, replacement: String) { self.original = original; self.replacement = replacement }
    init?(_ value: Any) {
        guard let pair = value as? [String], pair.count == 2 else { return nil }
        self.init(original: pair[0], replacement: pair[1])
    }
    static func list(_ value: Any?) -> [VoiceEditChange] { (value as? [Any] ?? []).compactMap(VoiceEditChange.init) }
}

/// A change found in the text: it replaces characters `start..<end`.
struct VoiceEditMatch: Equatable, Sendable {
    var change: VoiceEditChange
    var start: Int
    var end: Int
}

enum VoiceEditIssue: Error, Equatable {
    case noChanges, notFound, ambiguous, overlapping, addsNumbers, tooLong
    var message: String {
        switch self {
        case .noChanges: "No changes were needed. Try saying it another way."
        case .notFound: "Couldn’t find that part of your text. Try naming it differently."
        case .ambiguous: "That matches more than one place. Say which one, like “the second paragraph”."
        case .overlapping: "The suggested changes overlap. Try one change at a time."
        case .addsNumbers: "The suggestion added numbers you didn’t say, so it was discarded."
        case .tooLong: "The suggestion was much longer than your text, so it was discarded."
        }
    }
}

enum VoiceEditPlanner {
    /// How much text an edit may use. The on-device model has a small context window;
    /// the text, the instruction and the reply all have to fit.
    static let maxCharacters = 5000

    /// Trims the context to at most `limit` characters around the cursor.
    static func window(_ context: VoiceEditContext, limit: Int = maxCharacters) -> VoiceEditContext {
        guard context.full.count > limit else { return context }
        let selected = String(context.selected.prefix(limit))
        let room = max(0, limit - selected.count)
        // Split the room evenly, giving one side's unused share to the other.
        let afterTake = min(context.after.count, max(room / 2, room - context.before.count))
        let beforeTake = min(context.before.count, room - afterTake)
        return VoiceEditContext(before: String(context.before.suffix(beforeTake)), selected: selected,
                                after: String(context.after.prefix(afterTake)))
    }

    /// Finds every change in `text` and checks it's safe to show. A change must quote
    /// text that appears exactly once (or once inside `preferred`, the selection or the
    /// last dictation), and changes can't overlap.
    /// `trusted` skips the checks against invented content, for changes TapType made
    /// itself (undo, or re-placing an approved suggestion).
    static func plan(_ changes: [VoiceEditChange], in text: String, instruction: String,
                     preferred: Range<Int>? = nil, trusted: Bool = false) -> Result<[VoiceEditMatch], VoiceEditIssue> {
        var matches: [VoiceEditMatch] = []
        for change in changes where change.original != change.replacement {
            guard !change.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.notFound) }
            switch locate(change.original, in: text, preferred: preferred) {
            case .success(let found):
                let original = String(Array(text)[found])
                guard original != change.replacement else { continue }
                matches.append(VoiceEditMatch(change: VoiceEditChange(original: original, replacement: change.replacement),
                                              start: found.lowerBound, end: found.upperBound))
            case .failure(let issue): return .failure(issue)
            }
        }
        guard !matches.isEmpty else { return .failure(.noChanges) }
        matches.sort { $0.start < $1.start }
        for (earlier, later) in zip(matches, matches.dropFirst()) where later.start < earlier.end { return .failure(.overlapping) }
        if trusted { return .success(matches) }
        let originals = matches.map(\.change.original).joined(separator: " ")
        let replacements = matches.map(\.change.replacement).joined(separator: " ")
        let allowed = Set(numbers(in: originals + " " + instruction + " " + text))
        if numbers(in: replacements).contains(where: { !allowed.contains($0) }) { return .failure(.addsNumbers) }
        if replacements.count > max(400, originals.count * 3) { return .failure(.tooLong) }
        return .success(matches)
    }

    /// The character range of `needle` in `text`. Retries with trimmed whitespace and
    /// straight or curly quotes, since models sometimes change those when quoting.
    static func locate(_ needle: String, in text: String, preferred: Range<Int>? = nil) -> Result<Range<Int>, VoiceEditIssue> {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        let curly = trimmed.replacingOccurrences(of: "'", with: "’")
        let straight = trimmed.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        var tried = Set<String>()
        for candidate in [needle, trimmed, curly, straight] where !candidate.isEmpty && tried.insert(candidate).inserted {
            let found = text.ranges(of: candidate).map {
                text.distance(from: text.startIndex, to: $0.lowerBound)..<text.distance(from: text.startIndex, to: $0.upperBound)
            }
            if found.count == 1 { return .success(found[0]) }
            if found.count > 1 {
                let inside = preferred.map { area in found.filter { area.contains($0.lowerBound) && $0.upperBound <= area.upperBound } } ?? []
                return inside.count == 1 ? .success(inside[0]) : .failure(.ambiguous)
            }
        }
        return .failure(.notFound)
    }

    /// Where the cursor belongs after the changes: it moves with the text before it, and
    /// ends up after a change it was inside.
    static func cursor(after matches: [VoiceEditMatch], from cursor: Int) -> Int {
        var shift = 0
        for match in matches.sorted(by: { $0.start < $1.start }) {
            if match.end <= cursor { shift += match.change.replacement.count - (match.end - match.start) }
            else if match.start < cursor { return match.start + shift + match.change.replacement.count }
        }
        return cursor + shift
    }

    /// The text after applying `matches`.
    static func applying(_ matches: [VoiceEditMatch], to text: String) -> String {
        var characters = Array(text)
        for match in matches.sorted(by: { $0.start > $1.start }) {
            characters.replaceSubrange(match.start..<match.end, with: Array(match.change.replacement))
        }
        return String(characters)
    }

    /// Changes that put the text back. Each one carries a little unchanged text on both
    /// sides, so a deletion can be found again and restored.
    static func undo(for matches: [VoiceEditMatch], in text: String, anchor: Int = 24) -> [VoiceEditChange] {
        let characters = Array(text)
        let sorted = matches.sorted { $0.start < $1.start }
        return sorted.enumerated().map { index, match in
            // Neighbouring changes split the text between them, so their undos don't overlap.
            let floor = index > 0 ? (sorted[index - 1].end + match.start + 1) / 2 : 0
            let ceiling = index + 1 < sorted.count ? (match.end + sorted[index + 1].start + 1) / 2 : characters.count
            let before = String(characters[max(floor, match.start - anchor)..<match.start])
            let after = String(characters[match.end..<min(ceiling, match.end + anchor)])
            return VoiceEditChange(original: before + match.change.replacement + after,
                                   replacement: before + match.change.original + after)
        }
    }

    private static func numbers(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
    }
}

/// Word-by-word differences, worked out here rather than trusted from the model, so the
/// highlighted preview is exactly what will be written.
enum VoiceEditDiff {
    enum Kind: Equatable, Sendable { case same, removed, added }
    struct Piece: Equatable, Sendable { var kind: Kind; var text: String }

    static func pieces(from old: String, to new: String) -> [Piece] {
        let a = tokens(old), b = tokens(new)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Piece] = []
        func emit(_ kind: Kind, _ text: String) {
            if let last = result.last, last.kind == kind { result[result.count - 1].text += text }
            else { result.append(Piece(kind: kind, text: text)) }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { emit(.removed, a[i]); i += 1 }
            else if j < b.count, inserted.contains(j) { emit(.added, b[j]); j += 1 }
            else if i < a.count, j < b.count { emit(.same, a[i]); i += 1; j += 1 }
            else { break }
        }
        return result
    }

    /// The share of text that changed, from 0 (identical) to 1 (nothing in common).
    static func changedFraction(_ pieces: [Piece]) -> Double {
        let changed = pieces.filter { $0.kind != .same }.reduce(0) { $0 + $1.text.count }
        let total = pieces.reduce(0) { $0 + $1.text.count }
        return total == 0 ? 0 : Double(changed) / Double(total)
    }

    /// Words with the spaces after them, and line breaks on their own.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        var inSpace = false
        for character in text {
            if character.isNewline {
                if !current.isEmpty { result.append(current) }
                result.append(String(character)); current = ""; inSpace = false
            } else if character.isWhitespace {
                current.append(character); inSpace = true
            } else {
                if inSpace, !current.isEmpty { result.append(current); current = "" }
                current.append(character); inSpace = false
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// What you can say while reviewing a suggestion. Anything that isn't a short command
/// is a refinement of the suggestion ("also make it shorter", "keep Friday").
enum VoiceReviewCommand: Equatable, Sendable {
    case apply, cancel, undo, showBefore, showAfter
    case applyOnly([Int]), skip([Int])
    case refine(String)

    static func parse(_ spoken: String) -> VoiceReviewCommand {
        let words = spoken.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let phrase = words.joined(separator: " ")
        guard !words.isEmpty, words.count <= 7 else { return .refine(spoken.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let apply: Set<String> = ["apply", "yes", "yeah", "yep", "yup", "ok", "okay", "do it", "approve", "accept", "looks good",
            "sounds good", "apply it", "apply all", "apply them", "apply all of them", "apply the changes", "apply changes",
            "go ahead", "confirm", "sure", "yes please", "apply that", "that's good", "perfect", "done", "save", "save it"]
        let cancel: Set<String> = ["cancel", "no", "nope", "discard", "never mind", "nevermind", "forget it", "reject",
            "don't", "do not", "cancel it", "cancel that", "no thanks", "discard it", "throw it away", "stop"]
        let undo: Set<String> = ["undo", "undo that", "undo it", "revert", "revert that", "put it back", "go back", "undo the last edit", "undo last edit"]
        if apply.contains(phrase) { return .apply }
        if cancel.contains(phrase) { return .cancel }
        if undo.contains(phrase) { return .undo }
        if ["show before", "before", "show the original", "show original", "original"].contains(phrase) { return .showBefore }
        if ["show after", "after", "show the new version", "show new version", "show changes", "show the changes"].contains(phrase) { return .showAfter }
        let positions = ordinals(words)
        guard !positions.isEmpty else { return .refine(spoken.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let verb = words.first ?? ""
        if ["skip", "drop", "remove", "reject", "exclude", "ignore"].contains(verb) || phrase.hasPrefix("don't apply") || phrase.hasPrefix("not the") {
            return .skip(positions)
        }
        if ["apply", "accept", "keep", "only", "just", "use", "approve"].contains(verb) { return .applyOnly(positions) }
        return .refine(spoken.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Change numbers mentioned, starting at 1: "the first and third" → [1, 3].
    private static func ordinals(_ words: [String]) -> [Int] {
        let names = ["first": 1, "1st": 1, "second": 2, "2nd": 2, "two": 2, "third": 3, "3rd": 3, "three": 3,
                     "fourth": 4, "4th": 4, "four": 4, "fifth": 5, "5th": 5, "five": 5, "sixth": 6, "six": 6,
                     "seventh": 7, "seven": 7, "eighth": 8, "eight": 8, "ninth": 9, "nine": 9, "tenth": 10, "ten": 10, "last": -1]
        var result: [Int] = []
        for word in words {
            if let value = names[word] ?? Int(word), value != 0, !result.contains(value) { result.append(value) }
        }
        return result
    }

    var name: String {
        switch self {
        case .apply: "apply"; case .cancel: "cancel"; case .undo: "undo"
        case .showBefore: "showBefore"; case .showAfter: "showAfter"
        case .applyOnly: "applyOnly"; case .skip: "skip"; case .refine: "refine"
        }
    }
    var dictionary: [String: Any] {
        switch self {
        case .applyOnly(let positions), .skip(let positions): ["name": name, "positions": positions]
        case .refine(let text): ["name": name, "text": text]
        default: ["name": name]
        }
    }
    init?(_ value: [String: Any]?) {
        guard let value, let name = value["name"] as? String else { return nil }
        let positions = value["positions"] as? [Int] ?? []
        switch name {
        case "apply": self = .apply
        case "cancel": self = .cancel
        case "undo": self = .undo
        case "showBefore": self = .showBefore
        case "showAfter": self = .showAfter
        case "applyOnly": self = .applyOnly(positions)
        case "skip": self = .skip(positions)
        case "refine": self = .refine(value["text"] as? String ?? "")
        default: return nil
        }
    }
    /// Turns 1-based positions (and -1 for "last") into indexes of `count` changes.
    static func indexes(_ positions: [Int], count: Int) -> [Int] {
        positions.compactMap { $0 == -1 ? count - 1 : $0 - 1 }.filter { (0..<count).contains($0) }
    }
}

/// What the keyboard asks for. Written before the instruction is spoken.
struct VoiceEditRequest {
    var id: String
    var document: String
    var context: VoiceEditContext
    /// The last text TapType inserted here, if it's still in the text: the default target.
    var lastDictation: String
    /// When reviewing: the instruction and the changes being reviewed.
    var instruction: String = ""
    var previous: [VoiceEditChange] = []

    var dictionary: [String: Any] {
        ["id": id, "document": document, "context": context.dictionary, "lastDictation": lastDictation,
         "instruction": instruction, "previous": previous.map(\.pair), "time": Date().timeIntervalSince1970]
    }
    init(id: String, document: String, context: VoiceEditContext, lastDictation: String = "",
         instruction: String = "", previous: [VoiceEditChange] = []) {
        self.id = id; self.document = document; self.context = context; self.lastDictation = lastDictation
        self.instruction = instruction; self.previous = previous
    }
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let document = value["document"] as? String,
              let context = VoiceEditContext(value["context"] as? [String: Any]) else { return nil }
        self.init(id: id, document: document, context: context, lastDictation: value["lastDictation"] as? String ?? "",
                  instruction: value["instruction"] as? String ?? "", previous: VoiceEditChange.list(value["previous"]))
    }
    /// The part to edit when the instruction doesn't say: the selection, else the last dictation.
    var preferredRange: Range<Int>? {
        if let selection = context.selectionRange { return selection }
        guard !lastDictation.isEmpty, case .success(let range) = VoiceEditPlanner.locate(lastDictation, in: context.full) else { return nil }
        return range
    }
}

/// What the app sends back once the instruction is understood.
struct VoiceEditOutcome: Equatable {
    enum Kind: String { case suggestion, command, undo, failed }
    var id: String
    var kind: Kind
    var instruction: String
    var changes: [VoiceEditChange] = []
    var command: VoiceReviewCommand?
    var message: String = ""

    var dictionary: [String: Any] {
        var value: [String: Any] = ["id": id, "kind": kind.rawValue, "instruction": instruction,
                                    "changes": changes.map(\.pair), "message": message]
        if let command { value["command"] = command.dictionary }
        return value
    }
    init(id: String, kind: Kind, instruction: String, changes: [VoiceEditChange] = [],
         command: VoiceReviewCommand? = nil, message: String = "") {
        self.id = id; self.kind = kind; self.instruction = instruction; self.changes = changes
        self.command = command; self.message = message
    }
    init?(_ value: [String: Any]?) {
        guard let value, let id = value["id"] as? String, let kind = (value["kind"] as? String).flatMap(Kind.init) else { return nil }
        self.init(id: id, kind: kind, instruction: value["instruction"] as? String ?? "",
                  changes: VoiceEditChange.list(value["changes"]),
                  command: VoiceReviewCommand(value["command"] as? [String: Any]), message: value["message"] as? String ?? "")
    }
}
