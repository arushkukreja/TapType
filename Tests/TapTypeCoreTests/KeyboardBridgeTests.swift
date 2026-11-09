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
