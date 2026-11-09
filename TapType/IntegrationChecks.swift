#if DEBUG
import Foundation
import AVFoundation

private final class StubProvider: URLProtocol, @unchecked Sendable {
    static var responseCode = 200
    static var responseData = Data()
    static var requestBody: Data?
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.requestBody = request.httpBody
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
enum IntegrationChecks {
    static func costs() async {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.json")
        let store = CloudUsageStore(file: file)
        let speech = CloudModelUsage(provider: "openAI", model: "gpt-transcribe", writing: false)
        let groq = CloudModelUsage(provider: "groq", model: "whisper-large-v3-turbo", writing: false)
        let writing = CloudModelUsage(provider: "openAI", model: "gpt-6-luna", writing: true)
        let enterprise = CloudModelUsage(provider: "groq", model: "llama-3.3-70b-versatile", writing: true)
        var checks = 0
        func check(_ value: Bool, _ name: String) { assert(value, name); checks += 1; print("COST_CHECK: \(name)=\(value)") }
        func near(_ x: Double?, _ y: Double) -> Bool { x.map { abs($0-y) < 0.000000001 } ?? false }
        let a = store.begin(speech, seconds: 60)
        check(store.entries.last?.usd == nil, "pending_not_free")
        store.complete(a, data: Data(#"{"text":"Hello"}"#.utf8))
        check(near(store.entries.last?.usd, 0.0045), "openai_minute_rate")
        let b = store.begin(groq, seconds: 1)
        store.complete(b, data: Data())
        check(near(store.entries.last?.usd, 10.0 / 3600 * 0.04), "groq_ten_second_minimum")
        let usage = Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":500,"prompt_tokens_details":{"cached_tokens":200}}}"#.utf8)
        let c = store.begin(writing); store.complete(c, data: usage)
        check(near(store.entries.last?.usd, 0.000332), "writing_cached_tokens")
        store.complete(c, data: Data())
        check(store.entries.count == 3 && near(store.entries.last?.usd, 0.000332), "duplicate_completion_idempotent")
        let d = store.begin(enterprise); store.complete(d, data: usage)
        check(store.entries.last?.usd == nil, "enterprise_rate_unknown")
        check(store.setRate(.init(input: 1, output: 2, cached: 0.5), for: enterprise), "custom_rate_saves")
        check(near(store.entries.last?.usd, 0.0019), "custom_rate_fills_unpriced_history")
        check(store.setRate(.init(input: 10, output: 20, cached: 5), for: enterprise), "rate_update_saves")
        check(near(store.entries.last?.usd, 0.0019), "priced_history_unchanged")
        check(!store.setRate(.init(input: -.infinity, output: 0, cached: 0), for: enterprise), "invalid_rate_rejected")
        let e = store.begin(writing); store.complete(e, data: Data(#"{"usage":{"prompt_tokens":10,"completion_tokens":-1}}"#.utf8))
        check(store.entries.last?.usd == nil, "invalid_tokens_not_priced")
        let f = store.begin(writing); store.complete(f, data: Data(#"{"choices":[]}"#.utf8))
        check(store.entries.last?.usd == nil, "missing_usage_not_free")
        let reloaded = CloudUsageStore(file: file)
        check(reloaded.entries.count == 6 && near(CloudUsageStore.total(reloaded.entries), CloudUsageStore.total(store.entries)), "persistence_totals")
        check(reloaded.rate(for: enterprise)?.input == 10, "custom_rate_persistence")
        do {
            let bytes = try Data(contentsOf: file)
            let json = String(decoding: bytes, as: UTF8.self)
            check(!json.contains("Hello") && !json.contains("Bearer"), "no_transcript_or_key_saved")
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProvider.self]
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let selection = CloudSelection(testProvider: .openAI, model: "gpt-6-luna", key: "test-key-never-real")
            StubProvider.responseCode = 200
            StubProvider.responseData = Data(#"{"choices":[{"message":{"content":"Send 9 copies to Maya."}}],"usage":{"prompt_tokens":1000,"completion_tokens":500}}"#.utf8)
            let rejected = await CloudModels.clean("send 3 copies to Maya", mode: .cleanup, selection: selection, session: session, usageStore: store)
            check(!rejected.usedModel && near(store.entries.last?.usd, 0.00035), "rejected_cleanup_still_costs")
            let request = StubProvider.requestBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            check(request?["reasoning_effort"] as? String == "none", "luna_cleanup_disables_reasoning")
            let before = store.entries.count
            _ = await CloudModels.clean("hello", mode: .original, selection: selection, session: session, usageStore: store)
            _ = try await CloudModels.send(CloudModels.request(selection, path: "models"), provider: .openAI, session: session)
            check(store.entries.count == before, "original_and_connection_test_not_billed")
            StubProvider.responseCode = 429
            _ = await CloudModels.clean("hello", mode: .cleanup, selection: selection, session: session, usageStore: store)
            check(store.entries.count == before + 1 && store.entries.last?.confirmed == false && store.entries.last?.usd == nil, "failed_request_flagged_unknown")
            StubProvider.responseCode = 200; StubProvider.responseData = Data(#"{"text":"Hello"}"#.utf8)
            let speechSelection = CloudSelection(testProvider: .openAI, model: "gpt-transcribe", key: "test-key-never-real")
            _ = try await CloudModels.transcribe(Array(repeating: 0, count: 16000), selection: speechSelection, session: session, usageStore: store)
            check(near(store.entries.last?.usd, 0.0045 / 60), "speech_pipeline_tracks_duration")
            let count = store.entries.count
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try? await CloudModels.transcribe([0], selection: speechSelection, session: session, usageStore: store)
            }
            await cancelled.value
            check(store.entries.count == count, "cancel_before_send_no_charge")
            let broken = root.appendingPathComponent("broken.json")
            try Data("broken".utf8).write(to: broken)
            let blocked = CloudUsageStore(file: broken)
            _ = blocked.begin(speech, seconds: 1)
            let preserved = try String(contentsOf: broken, encoding: .utf8)
            check(blocked.notice != nil && preserved == "broken", "corrupt_ledger_preserved")
            let stream = store.begin(speech, seconds: 0)
            store.streamAudio(stream, seconds: 2.83325)
            check(near(store.entries.last?.usd, 2.83325 / 60 * 0.0045), "streamed_phrase_duration_cost")
            store.streamAudio(stream, seconds: 1)
            check(store.entries.last?.seconds == 2.83325, "streamed_duration_never_decreases")
            store.markPurpose(stream, "Cancelled")
            check(near(CloudUsageStore(file: file).entries.last?.usd, 2.83325 / 60 * 0.0045), "cancelled_stream_persists_exact_cost")
            store.complete(stream, data: Data()); store.complete(stream, data: Data())
            check(store.entries.filter { $0.id == stream }.count == 1, "stream_completion_not_double_billed")
            print("COST_CHECKS_COMPLETE: \(checks)")
        } catch { assertionFailure("Cost checks failed: \(error)") }
    }

    static func history() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID(), second = UUID(), date = Date(timeIntervalSince1970: 1_794_000_000)
        let store = TranscriptHistory(directory: root)
        store.record(id: first, text: "Original first sentence", at: date)
        store.record(id: second, text: "Original first sentence", at: date.addingTimeInterval(60))
        store.record(id: first, text: "Must not replace the first sentence")
        store.record(id: UUID(), text: "  ")
        assert(store.entries.count == 2 && store.entries.first?.id == second)
        assert(store.totalWords == 6)
        for (text, expected) in [("", 0), ("Hello, world!", 2), ("One\n two   three", 3), ("... 😀", 0)] {
            assert(TranscriptRecord(id: UUID(), createdAt: date, text: text).wordCount == expected)
        }
        assert((try? CloudSettingsDraft(key: "", speech: "gpt-transcribe", writing: "model-1").validate()) != nil)
        assert((try? CloudSettingsDraft(key: "bad key", speech: "a", writing: "b").validate()) == nil)
        assert((try? CloudSettingsDraft(key: "", speech: "", writing: "b").validate()) == nil)
        assert((try? CloudSettingsDraft(key: "", speech: "bad model", writing: "b").validate()) == nil)
        print("WORD_COUNT_AND_CLOUD_DRAFT_CHECKS_COMPLETE")
        let reopened = TranscriptHistory(directory: root)
        assert(reopened.entries.count == 2 && reopened.entries.last?.text == "Original first sentence")
        assert(reopened.entries.last?.createdAt == date)
        assert(reopened.entries.first?.localTimestamp.isEmpty == false)
        assert(reopened.totalWords == 6)
        reopened.remove(first)
        assert(reopened.totalWords == 3)
        assert(TranscriptHistory(directory: root).entries.map(\.id) == [second])
        do {
            let broken = root.appendingPathComponent("broken.json")
            try Data("not valid json".utf8).write(to: broken)
            let recovered = TranscriptHistory(directory: root)
            assert(recovered.entries.count == 1 && recovered.notice != nil && FileManager.default.fileExists(atPath: broken.path))
            let blocked = root.appendingPathComponent("not-a-directory")
            try Data().write(to: blocked)
            let unavailable = TranscriptHistory(directory: blocked)
            unavailable.record(id: UUID(), text: "Do not silently lose this")
            assert(unavailable.entries.isEmpty && unavailable.notice != nil)
            print("HISTORY_CHECKS_COMPLETE: append duplicate-text distinct-ids dedup empty reload timestamps delete corrupt-file-preserved write-error")
        } catch { assertionFailure("History fixture setup failed") }
    }
    static func fixture() throws -> AudioClip {
        let file = try AVAudioFile(forReading: Bundle.main.url(forResource: "SpeechFixture", withExtension: "aiff")!)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return AudioClip(samples: Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), sampleRate: buffer.format.sampleRate)
    }
    static func providers() async {
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            print("PROVIDER_CHECK: \(name)=\(value)"); assert(value, name); checks += 1
        }
        do {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Data("abc".utf8).write(to: temporary)
            let manifest = DownloadableModel.File(path: "test", url: URL(string: "https://huggingface.co/test")!, bytes: 3,
                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            check(try ModelStore.matches(temporary, file: manifest), "download_hash_accepts_known_file")
            try Data("abd".utf8).write(to: temporary)
            check(try !ModelStore.matches(temporary, file: manifest), "download_hash_rejects_corruption")
            try Data("ab".utf8).write(to: temporary)
            check(try !ModelStore.matches(temporary, file: manifest), "download_rejects_truncation")
            let converted = try fixture().mono16k()
            check(!converted.isEmpty && converted.count < 16000 * 60, "fixture_resamples")
            let wav = AudioClip.wav([0, 1, -1, .nan])
            check(wav.count == 52 && String(data: wav.prefix(4), encoding: .utf8) == "RIFF" && Array(wav[44..<52]) == [0,0,255,127,1,128,0,0], "wav_header_and_pcm")
            do { _ = try AudioClip(samples: [1], sampleRate: .infinity).mono16k(); check(false, "invalid_rate") }
            catch { check(true, "invalid_rate") }
            let usage = CloudUsageStore(file: temporary.appendingPathExtension("usage.json"))
            defer { try? FileManager.default.removeItem(at: temporary.appendingPathExtension("usage.json")) }
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProvider.self]
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            for provider in CloudProvider.allCases {
                let selection = CloudSelection(testProvider: provider, model: "test-model", key: "test-key-never-real")
                let request = CloudModels.transcriptionRequest(wav, selection: selection, boundary: "unit-boundary")
                check(request.url?.host == provider.baseURL.host && request.url?.path.hasSuffix("/audio/transcriptions") == true, "\(provider.rawValue)_endpoint")
                check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-never-real" && request.httpBody?.range(of: wav) != nil, "\(provider.rawValue)_multipart")
                StubProvider.responseCode = 200; StubProvider.responseData = Data(#"{"text":"Send 3 copies to Maya."}"#.utf8)
                let text = try await CloudModels.transcribe([0.1], selection: selection, session: session, usageStore: usage)
                check(text == "Send 3 copies to Maya.", "\(provider.rawValue)_speech_response")
                StubProvider.responseData = Data(#"{"choices":[{"message":{"content":"Send 3 copies to Maya."}}]}"#.utf8)
                let clean = await CloudModels.clean("um send 3 copies to Maya", mode: .cleanup, selection: selection, session: session, usageStore: usage)
                check(clean.usedModel && clean.text == "Send 3 copies to Maya.", "\(provider.rawValue)_cleanup")
                StubProvider.responseData = Data(#"{"choices":[{"message":{"content":"Send 9 copies to Maya."}}]}"#.utf8)
                let rejected = await CloudModels.clean("send 3 copies to Maya", mode: .cleanup, selection: selection, session: session, usageStore: usage)
                check(!rejected.usedModel && rejected.text == "send 3 copies to Maya", "\(provider.rawValue)_meaning_guard")
                let before = StubProvider.requests
                _ = await CloudModels.clean("hello", mode: .original, selection: selection, session: session, usageStore: usage)
                check(StubProvider.requests == before, "\(provider.rawValue)_original_no_request")
                for code in [401, 429, 500] {
                    StubProvider.responseCode = code; StubProvider.responseData = Data("secret server response".utf8)
                    do { _ = try await CloudModels.send(request, provider: provider, session: session); check(false, "status_\(code)") }
                    catch { check(error is ProviderFailure && !error.localizedDescription.contains("secret"), "\(provider.rawValue)_friendly_\(code)") }
                }
                if (try? ProviderKeys.read(provider)) == nil {
                    try ProviderKeys.save("test-key-never-real", for: provider)
                    check(try ProviderKeys.read(provider) == "test-key-never-real", "\(provider.rawValue)_keychain")
                    try ProviderKeys.remove(provider)
                    check((try? ProviderKeys.read(provider)) == nil, "\(provider.rawValue)_key_removed")
                }
            }
            print("PROVIDER_CHECKS_COMPLETE: \(checks)")
        } catch { print("PROVIDER_CHECKS_ERROR: \(error.localizedDescription)") }
    }
    static func model(_ id: String, download: Bool) async {
        let store = ModelStore.shared
        guard let model = store.models.first(where: { $0.id == id }) else { print("MODEL_UNKNOWN"); return }
        if download && !store.installed.contains(id) {
            print("MODEL_DOWNLOAD_BEGIN: \(id) bytes=\(model.bytes)")
            store.download(model)
            while store.downloading != nil { try? await Task.sleep(for: .seconds(1)) }
        }
        do {
            _ = try store.location(id)
            print("MODEL_INSTALLED: \(id)")
            let start = Date()
            let result = try await store.transcribe(try fixture().mono16k(), model: id)
            print("MODEL_FIXTURE_RESULT: \(id) seconds=\(Date().timeIntervalSince(start)) text=\(result)")
            print("MODEL_CHECK_COMPLETE: \(!result.isEmpty)")
        } catch { print("MODEL_CHECK_ERROR: \(error.localizedDescription) notice=\(store.notice ?? "none")") }
    }
}
#endif
