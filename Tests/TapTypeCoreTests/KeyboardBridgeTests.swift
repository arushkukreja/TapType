import XCTest
@testable import TapTypeCore

final class HostReturnIdentityTests: XCTestCase {
    private let requestID = "11111111-1111-1111-1111-111111111111"
    private let document = "22222222-2222-2222-2222-222222222222"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshMatchingMarkerAuthorizesHandoff() throws {
        let marker: [String: Any] = ["id": requestID, "document": document,
                                     "time": now.timeIntervalSince1970 - 1]
        let began = try XCTUnwrap(HostReturnIdentity.handoffStarted(marker, requestID: requestID,
            document: document, arrived: now))
        XCTAssertEqual(began.timeIntervalSince1970, now.timeIntervalSince1970 - 1)
    }

    func testInvalidMarkersDoNotAuthorizeHandoff() {
        let valid: [String: Any] = ["id": requestID, "document": document,
                                    "time": now.timeIntervalSince1970 - 1]
        var wrongID = valid; wrongID["id"] = UUID().uuidString
        var wrongDocument = valid; wrongDocument["document"] = UUID().uuidString
        var expired = valid; expired["time"] = now.timeIntervalSince1970 - 8
        var future = valid; future["time"] = now.timeIntervalSince1970 + 0.001
        var nonfinite = valid; nonfinite["time"] = Double.nan
        for marker in [wrongID, wrongDocument, expired, future, nonfinite] {
            XCTAssertNil(HostReturnIdentity.handoffStarted(marker, requestID: requestID,
                document: document, arrived: now))
        }
    }

    func testKeyboardHostRequiresFreshMatchingExternalBundle() {
        let marker: [String: Any] = ["id": requestID, "document": document,
            "host": "com.apple.mobilesms", "time": now.timeIntervalSince1970 - 1]
        XCTAssertEqual(HostReturnIdentity.keyboardHost(marker, requestID: requestID, document: document,
            own: "com.arushkukreja.TapTypeDev", now: now), "com.apple.MobileSMS")
        XCTAssertNil(HostReturnIdentity.keyboardHost(marker, requestID: UUID().uuidString,
            document: document, own: "com.arushkukreja.TapTypeDev", now: now))
        var own = marker; own["host"] = "com.arushkukreja.TapTypeDev.keyboard"
        XCTAssertNil(HostReturnIdentity.keyboardHost(own, requestID: requestID, document: document,
            own: "com.arushkukreja.TapTypeDev", now: now))
    }
}

final class HostReturnCacheTests: XCTestCase {
    func testRapidReuseAndOverwrite() {
        var cache = HostReturnCache()
        cache.observe(pid: 42, bundle: "com.apple.mobilenotes", now: 100)
        XCTAssertEqual(cache.bundle(for: 42, now: 107.999), "com.apple.mobilenotes")
        cache.observe(pid: 42, bundle: "com.apple.MobileSMS", now: 108)
        XCTAssertEqual(cache.bundle(for: 42, now: 109), "com.apple.MobileSMS")
        XCTAssertEqual(cache.count, 1)
    }

    func testEntryExpiresAtEightSeconds() {
        var cache = HostReturnCache()
        cache.observe(pid: 42, bundle: "com.apple.mobilenotes", now: 100)
        XCTAssertNil(cache.bundle(for: 42, now: 108))
        XCTAssertEqual(cache.count, 0)
    }

    func testFutureAndStaleEntriesArePruned() {
        var cache = HostReturnCache()
        cache.observe(pid: 1, bundle: "com.example.first", now: 100)
        XCTAssertNil(cache.bundle(for: 1, now: 99))
        cache.observe(pid: 1, bundle: "com.example.first", now: 100)
        cache.observe(pid: 2, bundle: "com.example.second", now: 109)
        XCTAssertNil(cache.bundle(for: 1, now: 109))
        XCTAssertEqual(cache.bundle(for: 2, now: 109), "com.example.second")
        XCTAssertEqual(cache.count, 1)
    }
}

final class TranscriptEchoReducerTests: XCTestCase {
    func testRemovesOnlyAnImmediateWhisperEcho() {
        XCTAssertEqual(TranscriptEchoReducer.removingLeadingEcho(from: "from yesterday I can help", after: "Hey Sarah, from yesterday"), "I can help")
        XCTAssertEqual(TranscriptEchoReducer.removingImmediateEchoes(from: "The proposal from yesterday proposal from yesterday is ready"), "The proposal from yesterday is ready")
    }

    func testKeepsSeparateRepeatedDictation() {
        XCTAssertEqual(TranscriptEchoReducer.removingImmediateEchoes(from: "Yes. Then later, yes."), "Yes. Then later, yes.")
        XCTAssertEqual(TranscriptEchoReducer.removingImmediateEchoes(from: "No, no, that is not right."), "No, no, that is not right.")
    }
}

final class BridgeSignalTests: XCTestCase {
    @MainActor
    func testObserverReceivesPostedSignalOnMainThread() {
        let received = expectation(description: "signal delivered")
        let signal = BridgeSignal(observing: .state) {
            XCTAssertTrue(Thread.isMainThread)
            received.fulfill()
        }
        BridgeSignal.post(.state)
        wait(for: [received], timeout: 2)
        withExtendedLifetime(signal) {}
    }

    @MainActor
    func testReleasedObserverStopsReceiving() {
        let unexpected = expectation(description: "no delivery after release")
        unexpected.isInverted = true
        var signal: BridgeSignal? = BridgeSignal(observing: .command) { unexpected.fulfill() }
        signal = nil
        XCTAssertNil(signal)
        BridgeSignal.post(.command)
        wait(for: [unexpected], timeout: 0.5)
    }
}

final class TranscriptArtifactsTests: XCTestCase {
    func testRemovesSoundLabels() {
        XCTAssertEqual(TranscriptArtifacts.cleaned("(upbeat music) Send the report [BLANK_AUDIO] by Friday."), "Send the report by Friday.")
        XCTAssertEqual(TranscriptArtifacts.cleaned("♪ ♪"), "")
    }
    func testDropsPhantomCaptionsOnly() {
        XCTAssertEqual(TranscriptArtifacts.cleaned(" Thanks for watching!"), "")
        XCTAssertEqual(TranscriptArtifacts.cleaned("Thank you."), "Thank you.")
        XCTAssertEqual(TranscriptArtifacts.cleaned("Okay."), "Okay.")
        XCTAssertEqual(TranscriptArtifacts.cleaned("Thank you for the update."), "Thank you for the update.")
    }
}

final class PhraseBoundaryWindowTests: XCTestCase {
    private func words(_ items: [(String, Double, Double)]) -> [TimedWord] { items.map { TimedWord(text: $0.0, start: $0.1, end: $0.2) } }

    func testPauseCommitsEverything() {
        var window = PhraseBoundaryWindow()
        let result = window.split(words([(" Hello", 0, 0.5), (" there.", 0.5, 1.0)]), audioEnd: 1.2, atPause: true)
        XCTAssertEqual(result.commit.map(\.text).joined(), " Hello there.")
        XCTAssertNil(result.keepFrom)
    }

    func testCutHoldsBackWordsNearTheEnd() {
        var window = PhraseBoundaryWindow()
        let first = window.split(words([(" so", 8.0, 8.3), (" we", 8.4, 8.6), (" can", 8.7, 9.0), (" check", 10.9, 11.3), (" out.", 11.4, 11.9)]),
                                 audioEnd: 12.0, atPause: false)
        XCTAssertEqual(first.commit.map(\.text).joined(), " so we can")
        XCTAssertEqual(first.keepFrom ?? -1, 8.9, accuracy: 0.001)
        // The next decode overlaps the committed words; only new ones are kept.
        let second = window.split(words([(" can", 8.95, 9.0), (" check", 10.9, 11.3), (" that", 11.4, 11.7), (" the", 11.8, 12.0), (" text.", 12.1, 12.6)]),
                                  audioEnd: 13.0, atPause: true)
        XCTAssertEqual(second.commit.map(\.text).joined(), " check that the text.")
    }

    func testDoesNotSplitInsideAWord() {
        var window = PhraseBoundaryWindow()
        let result = window.split(words([(" pro", 9.0, 9.5), ("posal", 10.6, 11.0), (" to", 11.1, 11.3)]), audioEnd: 12.0, atPause: false)
        XCTAssertEqual(result.commit, [])
        XCTAssertEqual(result.keepFrom ?? -1, 7.0, accuracy: 0.001)
    }

    func testCommitsEverythingRatherThanCarryingTooMuch() {
        var window = PhraseBoundaryWindow()
        let result = window.split(words([(" word", 1.0, 1.5)]), audioEnd: 12.0, atPause: false)
        XCTAssertEqual(result.commit.count, 1)
        XCTAssertNil(result.keepFrom)
    }
}
