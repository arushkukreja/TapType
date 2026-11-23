import XCTest
@testable import TapTypeCore

final class VoiceEditPlannerTests: XCTestCase {
    private let note = "Budget\nWe need to finalize the budget by Friday.\nSend it to Maya.\n\nTravel\nBook flights by Friday."

    func testLocatesUniqueChangeAndApplies() throws {
        let change = VoiceEditChange(original: "Send it to Maya.", replacement: "Send it to Maya and Sam.")
        let matches = try VoiceEditPlanner.plan([change], in: note, instruction: "add Sam").get()
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(VoiceEditPlanner.applying(matches, to: note),
                       note.replacingOccurrences(of: "Send it to Maya.", with: "Send it to Maya and Sam."))
    }

    func testAmbiguousChangeIsRefusedUnlessInsidePreferredRange() {
        let change = VoiceEditChange(original: "by Friday.", replacement: "by Monday.")
        XCTAssertEqual(VoiceEditPlanner.plan([change], in: note, instruction: "change Friday to Monday"), .failure(.ambiguous))
        let travel = note.distance(from: note.startIndex, to: note.range(of: "Travel")!.lowerBound)..<note.count
        let matches = try? VoiceEditPlanner.plan([change], in: note, instruction: "", preferred: travel).get()
        XCTAssertEqual(matches?.first?.start, note.count - "by Friday.".count)
    }

    func testMissingOverlappingAndInventedChangesAreRefused() {
        XCTAssertEqual(VoiceEditPlanner.plan([.init(original: "Send it to Bob.", replacement: "x")], in: note, instruction: ""), .failure(.notFound))
        XCTAssertEqual(VoiceEditPlanner.plan([.init(original: "Send it to Maya.", replacement: "Send it to Maya.")], in: note, instruction: ""), .failure(.noChanges))
        XCTAssertEqual(VoiceEditPlanner.plan([.init(original: "finalize the budget", replacement: "approve the budget"),
                                              .init(original: "the budget by Friday", replacement: "it by Friday")], in: note, instruction: ""), .failure(.overlapping))
        XCTAssertEqual(VoiceEditPlanner.plan([.init(original: "Send it to Maya.", replacement: "Send 5 copies to Maya.")], in: note, instruction: "clarify"), .failure(.addsNumbers))
        XCTAssertNoThrow(try VoiceEditPlanner.plan([.init(original: "Send it to Maya.", replacement: "Send 5 copies to Maya.")], in: note, instruction: "say 5 copies").get())
    }

    func testQuotesAndWhitespaceFromTheModelStillMatch() throws {
        let text = "It’s due Friday. Thanks!"
        let matches = try VoiceEditPlanner.plan([.init(original: " It's due Friday. ", replacement: "It’s due Monday.")], in: text, instruction: "").get()
        XCTAssertEqual(VoiceEditPlanner.applying(matches, to: text), "It’s due Monday. Thanks!")
    }

    func testCursorFollowsTheText() {
        let text = "aaa bbb ccc"
        let match = VoiceEditMatch(change: .init(original: "bbb", replacement: "bb"), start: 4, end: 7)
        XCTAssertEqual(VoiceEditPlanner.cursor(after: [match], from: 11), 10)
        XCTAssertEqual(VoiceEditPlanner.cursor(after: [match], from: 2), 2)
        XCTAssertEqual(VoiceEditPlanner.cursor(after: [match], from: 5), 6)
        XCTAssertEqual(VoiceEditPlanner.applying([match], to: text), "aaa bb ccc")
    }

    func testUndoRestoresDeletionsAndRewrites() throws {
        let text = "One. Two. Three. Four."
        let matches = try VoiceEditPlanner.plan([.init(original: "Two. ", replacement: ""),
                                                 .init(original: "Four.", replacement: "4!")], in: text, instruction: "4").get()
        let edited = VoiceEditPlanner.applying(matches, to: text)
        XCTAssertEqual(edited, "One. Three. 4!")
        let undo = VoiceEditPlanner.undo(for: matches, in: text)
        let back = try VoiceEditPlanner.plan(undo, in: edited, instruction: "").get()
        XCTAssertEqual(VoiceEditPlanner.applying(back, to: edited), text)
    }

    func testWindowKeepsTextAroundTheCursor() {
        let context = VoiceEditContext(before: String(repeating: "a", count: 4000), after: String(repeating: "b", count: 4000))
        let trimmed = VoiceEditPlanner.window(context, limit: 1000)
        XCTAssertEqual(trimmed.full.count, 1000)
        XCTAssertEqual(trimmed.before.count, 500)
        let short = VoiceEditContext(before: "abc", after: String(repeating: "b", count: 4000))
        XCTAssertEqual(VoiceEditPlanner.window(short, limit: 100).full.count, 100)
        XCTAssertEqual(VoiceEditPlanner.window(short, limit: 100).before, "abc")
    }

    func testRequestDefaultsToSelectionThenLastDictation() {
        var request = VoiceEditRequest(id: "1", document: "d", context: VoiceEditContext(before: "Hello there. ", after: "Bye now."),
                                       lastDictation: "Bye now.")
        XCTAssertEqual(request.preferredRange, 13..<21)
        request.context = VoiceEditContext(before: "Hello ", selected: "there.", after: " Bye now.")
        XCTAssertEqual(request.preferredRange, 6..<12)
        let decoded = VoiceEditRequest(request.dictionary)
        XCTAssertEqual(decoded?.context, request.context)
        XCTAssertEqual(decoded?.lastDictation, "Bye now.")
    }
}

final class VoiceEditDiffTests: XCTestCase {
    func testWordDiffMarksRemovedAndAddedWords() {
        let pieces = VoiceEditDiff.pieces(from: "We need to finalize the budget by Friday.", to: "We need to approve the budget by Monday.")
        XCTAssertEqual(pieces.filter { $0.kind == .removed }.map(\.text), ["finalize ", "Friday."])
        XCTAssertEqual(pieces.filter { $0.kind == .added }.map(\.text), ["approve ", "Monday."])
        XCTAssertEqual(pieces.filter { $0.kind != .added }.map(\.text).joined(), "We need to finalize the budget by Friday.")
        XCTAssertEqual(pieces.filter { $0.kind != .removed }.map(\.text).joined(), "We need to approve the budget by Monday.")
    }

    func testReformatIsMostlyChanged() {
        let pieces = VoiceEditDiff.pieces(from: "Milk eggs and bread", to: "• Milk\n• Eggs\n• Bread")
        XCTAssertGreaterThan(VoiceEditDiff.changedFraction(pieces), 0.6)
        XCTAssertEqual(VoiceEditDiff.tokens("a b\nc"), ["a ", "b", "\n", "c"])
    }
}

final class VoiceReviewCommandTests: XCTestCase {
    func testShortRepliesAreCommands() {
        XCTAssertEqual(VoiceReviewCommand.parse("Apply."), .apply)
        XCTAssertEqual(VoiceReviewCommand.parse("Yes"), .apply)
        XCTAssertEqual(VoiceReviewCommand.parse("Looks good!"), .apply)
        XCTAssertEqual(VoiceReviewCommand.parse("Cancel"), .cancel)
        XCTAssertEqual(VoiceReviewCommand.parse("never mind"), .cancel)
        XCTAssertEqual(VoiceReviewCommand.parse("Undo that."), .undo)
        XCTAssertEqual(VoiceReviewCommand.parse("Apply the first one"), .applyOnly([1]))
        XCTAssertEqual(VoiceReviewCommand.parse("Only the first and third"), .applyOnly([1, 3]))
        XCTAssertEqual(VoiceReviewCommand.parse("Skip the second."), .skip([2]))
        XCTAssertEqual(VoiceReviewCommand.parse("Don't apply the last one"), .skip([-1]))
        XCTAssertEqual(VoiceReviewCommand.indexes([-1, 1, 9], count: 3), [2, 0])
    }

    func testAnythingElseRefinesTheSuggestion() {
        XCTAssertEqual(VoiceReviewCommand.parse("Also make it shorter"), .refine("Also make it shorter"))
        XCTAssertEqual(VoiceReviewCommand.parse("Keep Friday"), .refine("Keep Friday"))
        XCTAssertEqual(VoiceReviewCommand.parse("Yes, and make the second bullet more formal please"),
                       .refine("Yes, and make the second bullet more formal please"))
    }

    func testOutcomeRoundTrips() {
        let outcome = VoiceEditOutcome(id: "x", kind: .command, instruction: "skip the second", command: .skip([2]))
        XCTAssertEqual(VoiceEditOutcome(outcome.dictionary), outcome)
        let suggestion = VoiceEditOutcome(id: "y", kind: .suggestion, instruction: "bullets", changes: [.init(original: "a", replacement: "• a")])
        XCTAssertEqual(VoiceEditOutcome(suggestion.dictionary), suggestion)
        XCTAssertEqual(DictationPurpose("review"), .review)
        XCTAssertEqual(DictationPurpose(nil), .dictate)
    }
}
