#if DEBUG
import Foundation
import AVFoundation

private actor SlowPhraseCleaner: PhraseCleaning {
    var active = 0, maximum = 0, calls = 0
    func prepare(mode: CleanupMode) {}
    func clean(_ phrase: CleanupPhrase, context: String, mode: CleanupMode, update: @escaping @Sendable (String) async -> Void) async -> PhraseEdit {
        active += 1; maximum = max(maximum, active); calls += 1
        await update("Refining")
        try? await Task.sleep(for: .milliseconds(80))
        active -= 1
        return .init(text: phrase.raw.uppercased(), usedModel: true, notice: nil)
    }
}
@MainActor
enum PipelineChecks {
    static func run() async {
        setbuf(stdout, nil)
        var n = 0
        func check(_ yes: Bool, _ name: String) { print("PIPELINE_CHECK: \(name)=\(yes)"); assert(yes, name); n += 1 }
        var state = StreamingTextState()
        state.receive(.init(start: 0, end: 1, text: "Send three", isFinal: false))
        check(state.snapshot.provisional == "Send three" && state.next == nil, "volatile_visible_not_queued")
        state.receive(.init(start: 0, end: 1, text: "Send five", isFinal: false))
        check(state.snapshot.raw == "Send five", "volatile_replaces_not_appends")
        state.silence(through: 2)
        check(state.next == nil, "vad_does_not_promote_volatile")
        let final = SpeechSpan(start: 0, end: 1, text: "Send five copies.", isFinal: true)
        state.receive(final)
        let id = state.next!.id
        state.receive(final)
        check(state.phrases.count == 1 && state.next!.id == id, "duplicate_final_deduplicated")
        state.receive(.init(start: 0, end: 1, text: "Old draft", isFinal: false))
        check(state.snapshot.finalized == "Send five copies.", "final_not_overwritten_by_volatile")
        state.refine(id: id, text: "Send five", completed: false)
        state.refine(id: id, text: "Send five copies.", completed: true)
        state.receive(.init(start: 2, end: 3, text: "Actually, send three copies.", isFinal: true))
        check(state.phrases.count == 1 && state.next?.correction == true && state.next?.id != id, "cross_sentence_correction_requeues_pair")
        state.refine(id: id, text: "Stale output", completed: true)
        check(!state.snapshot.display.contains("Stale"), "superseded_cleanup_ignored")
        state.receive(.init(start: 4, end: 5, text: "Still changing", isFinal: false))
        state.beginStop(); state.finishRecognition()
        check(!state.snapshot.raw.contains("changing") && state.snapshot.notice != nil, "stop_keeps_only_confirmed_speech")
        state.preservePending("Fallback")
        check(state.snapshot.refined == state.snapshot.finalized, "fallback_preserves_all_original_words")
        state.cancel(); state.receive(final)
        check(state.snapshot.raw.isEmpty && state.phrases.isEmpty, "cancel_ignores_late_events")
        var ordering = StreamingTextState()
        ordering.receive(.init(start: 2, end: 3, text: "Second.", isFinal: true))
        ordering.receive(.init(start: 0, end: 1, text: "First.", isFinal: true))
        check(ordering.snapshot.finalized == "First. Second.", "audio_time_orders_results")
        var commits = SpeechCommitOrder()
        check(commits.receive(id: "second", previousID: "first").isEmpty, "cloud_ack_waits_for_predecessor")
        check(commits.receive(id: "first", previousID: nil) == ["first", "second"], "cloud_commit_chain_orders_acknowledgments")
        check(commits.receive(id: "second", previousID: "first").isEmpty, "cloud_duplicate_ack_ignored")
        check(commits.receive(id: "third", previousID: "second") == ["third"], "cloud_order_continues_after_delivery")
        check(FoundationPhraseCleaner.validCorrection("Send 5 copies.", raw: "Send three copies. Actually, send five copies."), "explicit_correction_accepts_spoken_numbers")
        check(!FoundationPhraseCleaner.validCorrection("Send 3 copies.", raw: "Send three copies. Actually, send five copies."), "explicit_correction_preserves_corrected_value")
        check(!FoundationPhraseCleaner.validCorrection("Send 9 copies.", raw: "Send three copies. Actually, send five copies."), "explicit_correction_rejects_invented_value")
        check(FoundationPhraseCleaner.outputText("<transcript>Hello.</transcript>") == "Hello.", "cleanup_wrapper_removed")
        check(FoundationPhraseCleaner.outputText("<trans") == "" && FoundationPhraseCleaner.outputText("<transcript>Hello.</trans") == "Hello.", "partial_cleanup_wrapper_hidden")
        check(FoundationPhraseCleaner.outputText("Hello.") == "Hello.", "plain_cleanup_unchanged")
        check(FoundationPhraseCleaner.repeatsContext("Please keep that uncertainty. Review the introduction first, then the project schedule.", raw: "Please keep that uncertainty.", context: "Review the introduction first, then the project schedule."), "cleanup_cannot_copy_previous_phrase")
        check(!FoundationPhraseCleaner.repeatsContext("Review the introduction first, then the project schedule.", raw: "Review the introduction first, then the project schedule.", context: "Review the introduction first, then the project schedule."), "intentional_spoken_repetition_preserved")
        let cleaner = SlowPhraseCleaner()
        let service = PhraseCleanupService(mode: .cleanup, cleaner: cleaner) { _ in }
        await service.receive(.init(start: 0, end: 1, text: "First.", isFinal: true))
        await service.receive(.init(start: 2, end: 3, text: "Second.", isFinal: true))
        await service.finishRecognition()
        let result = await service.finish()
        check(result.refined == "FIRST. SECOND.", "serial_cleanup_preserves_order")
        let maximum = await cleaner.maximum
        check(maximum == 1, "no_overlapping_llm_operations")
        let cancelling = PhraseCleanupService(mode: .cleanup, cleaner: SlowPhraseCleaner()) { _ in }
        await cancelling.receive(final); try? await Task.sleep(for: .milliseconds(20)); await cancelling.cancel()
        try? await Task.sleep(for: .milliseconds(120))
        let cancelled = await cancelling.snapshot()
        check(cancelled.display.isEmpty, "late_llm_completion_after_cancel_ignored")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        for i in 0..<1024 { buffer.floatChannelData![0][i] = 0.1 }
        let sink = StreamingAudioSink()
        sink.append(buffer)
        check(!sink.isCapturing && sink.discarded == 1 && sink.level == 0, "idle_audio_discarded_before_copy")
        let input = sink.begin(); sink.append(buffer); sink.end()
        var received = 0
        for await packet in input { received += Int(packet.buffer.frameLength) }
        check(received == 1024, "capture_and_stop_flush_exactly_once")
        sink.append(buffer); check(!sink.isCapturing && sink.level == 0, "post_stop_audio_discarded")
        print("PIPELINE_CHECKS_COMPLETE: \(n)")
    }
    static func audioProbe() async {
        setbuf(stdout, nil)
        let audio = AVAudioSession.sharedInstance()
        for (category, mode, options) in [(AVAudioSession.Category.playAndRecord, AVAudioSession.Mode.measurement, AVAudioSession.CategoryOptions.mixWithOthers.union(.defaultToSpeaker)), (.playAndRecord, .default, .defaultToSpeaker), (.record, .measurement, [])] {
            do {
                try? audio.setActive(false)
                try audio.setCategory(category, mode: mode, options: options)
                try audio.setActive(true)
                print("AUDIO_PROBE: category=\(category.rawValue) mode=\(mode.rawValue) active=true route=\(audio.currentRoute.inputs.map(\.portType.rawValue))")
                try? await Task.sleep(for: .milliseconds(300))
                try? audio.setActive(false)
            } catch { let e = error as NSError; print("AUDIO_PROBE: category=\(category.rawValue) code=\(e.code) other=\(audio.isOtherAudioPlaying) hint=\(audio.secondaryAudioShouldBeSilencedHint)") }
        }
        print("AUDIO_PROBE_COMPLETE")
    }

    static func fixtureBenchmark() async {
        setbuf(stdout, nil)
        let args = ProcessInfo.processInfo.arguments
        let quietOpenAI = args.contains("--quiet-openai-fixture")
        let long = args.contains("--long-recording") || quietOpenAI, cloud = args.contains("--cloud-writing")
        do {
            if args.contains("--profile-wait") { try await Task.sleep(for: .seconds(30)) }
            let file = try AVAudioFile(forReading: Bundle.main.url(forResource: long ? "LongSpeechFixture" : "SpeechFixture", withExtension: "aiff")!)
            let format = file.processingFormat
            let fileBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: fileBuffer)
            let previousUsage = Set(CloudUsageStore.shared.entries.map(\.id))
            let performance = DictationPerformance.shared
            performance.begin()
            let cloudProvider: CloudProvider = args.contains("--groq-fixture") ? .groq : .openAI
            let cleaner: any PhraseCleaning = cloud ? CloudPhraseCleaner(selection: try CloudSelection(cloudProvider, writing: true)) : FoundationPhraseCleaner.shared
            let text = PhraseCleanupService(mode: .cleanup, cleaner: cleaner) { snapshot in
                await MainActor.run {
                    if !snapshot.display.isEmpty { performance.mark("firstVisibleWord") }
                    if !snapshot.finalized.isEmpty { performance.mark("firstFinalPhrase") }
                    if !snapshot.refined.isEmpty { performance.mark("firstRefinedPhrase") }
                }
            }
            let service: any StreamingSpeech
            if args.contains("--openai-fixture") || quietOpenAI { service = OpenAIStreamingSpeech(selection: try CloudSelection(.openAI), text: text) { print("FILE_PIPELINE_SPEECH_ERROR") } }
            else if args.contains("--groq-fixture") { service = PhraseSpeechService(provider: .groq, selection: try CloudSelection(.groq), text: text) { print("FILE_PIPELINE_SPEECH_ERROR") } }
            else if args.contains("--whisper-fixture") { service = PhraseSpeechService(provider: .base, selection: nil, text: text) { print("FILE_PIPELINE_SPEECH_ERROR") } }
            else { service = AppleSpeechService(text: text) { print("FILE_PIPELINE_SPEECH_ERROR") } }
            let input = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingOldest(256))
            async let warm: Void = text.prepare()
            try await service.start(input: input.stream, format: format)
            await warm; performance.mark("prepared"); performance.mark("capture")
            let size = Int(format.sampleRate / 20)
            let frameCount = quietOpenAI ? min(Int(fileBuffer.frameLength), Int(format.sampleRate * 20)) : Int(fileBuffer.frameLength)
            for start in stride(from: 0, to: frameCount, by: size) {
                let count = min(size, frameCount - start)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                var power: Float = 0
                for index in 0..<count { let sample = fileBuffer.floatChannelData![0][start + index]; power += sample * sample }
                let rms = sqrt(power / Float(max(1, count)))
                let gain: Float = quietOpenAI && rms > 0.004 ? 0.004 / rms : 1
                for channel in 0..<Int(format.channelCount) {
                    for index in 0..<count { buffer.floatChannelData![channel][index] = fileBuffer.floatChannelData![channel][start + index] * gain }
                }
                if quietOpenAI {
                    var quietPower: Float = 0
                    for index in 0..<count { let sample = buffer.floatChannelData![0][index]; quietPower += sample * sample }
                    assert(sqrt(quietPower / Float(max(1, count))) < 0.008, "Quiet fixture crossed the former upload gate")
                }
                input.continuation.yield(.init(buffer: buffer)); performance.sample()
                try await Task.sleep(for: .milliseconds(50))
            }
            performance.mark("stop"); input.continuation.finish(); await text.beginStop()
            try await service.finish()
            let result = await text.finish()
            performance.mark("cleanText"); performance.end(outcome: "fileFixture")
            if quietOpenAI {
                let entries = CloudUsageStore.shared.entries.filter { !previousUsage.contains($0.id) && $0.model.provider == CloudProvider.openAI.rawValue && !$0.model.writing }
                let seconds = entries.compactMap(\.seconds).reduce(0, +)
                let passed = result.finalized.lowercased().contains("purple bicycle") && entries.count == 2 && entries.allSatisfy { $0.confirmed && $0.purpose == "Completed phrase" } && (19.8...20.2).contains(seconds)
                print("QUIET_OPENAI_COMPLETE: passed=\(passed) turns=\(entries.count) seconds=\(seconds) confirmed=\(entries.allSatisfy(\.confirmed))")
                assert(passed, "Quiet OpenAI audio was not forwarded and finalized in full")
            }
            print("FIXTURE_REFINED: \(result.refined)")
            print("FILE_PIPELINE_COMPLETE: matched=\(result.finalized.lowercased().contains("purple bicycle")) words=\(result.finalized.split(whereSeparator: { $0.isWhitespace }).count) requests=\(await text.requests) notice=\(result.notice ?? "none") metrics=\(performance.latest)")
        } catch { let e = error as NSError; print("FILE_PIPELINE_ERROR: \(e.domain) \(e.code) \(e.localizedDescription)") }
    }

}
#endif
