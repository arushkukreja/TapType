import Foundation
@preconcurrency import AVFoundation
import Speech
import CoreMedia

struct CapturedAudio: @unchecked Sendable { let buffer: AVAudioPCMBuffer }

final class StreamingAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    #if DEBUG
    private let fixtureOnly = ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("-benchmark") }
    #endif
    private var continuation: AsyncStream<CapturedAudio>.Continuation?
    private var meter: Float = 0
    private var recentLevels: [Float] = []
    private var dropped = false
    private(set) var discarded = 0
    var level: Float { lock.lock(); defer { lock.unlock() }; return meter }
    /// Levels of every buffer since the last call, oldest first (about 47 per second).
    func drainLevels() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let levels = recentLevels
        recentLevels.removeAll(keepingCapacity: true)
        return levels
    }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return dropped }
    var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }
    func begin() -> AsyncStream<CapturedAudio> {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish(); dropped = false
        let pair = AsyncStream<CapturedAudio>.makeStream(bufferingPolicy: .bufferingOldest(256))
        continuation = pair.continuation
        return pair.stream
    }
    func end() { lock.lock(); defer { lock.unlock() }; continuation?.finish(); continuation = nil; meter = 0; recentLevels.removeAll() }
    func append(_ buffer: AVAudioPCMBuffer, fixture: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        #if DEBUG
        if fixtureOnly && !fixture { discarded += 1; return }
        #endif
        guard let continuation else { discarded += 1; meter = 0; return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let target = copy.floatChannelData else { dropped = true; return }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) { target[channel].update(from: source[channel], count: Int(buffer.frameLength)) }
        var power: Float = 0
        for i in 0..<Int(buffer.frameLength) { power += source[0][i] * source[0][i] }
        let db = 20 * log10(max(sqrt(power / Float(max(1, buffer.frameLength))), 0.00001))
        meter = max(0, min(1, (db + 55) / 45))
        if recentLevels.count >= 64 { recentLevels.removeFirst(recentLevels.count - 63) }
        recentLevels.append(meter)
        if case .dropped = continuation.yield(.init(buffer: copy)) { dropped = true }
    }
}

protocol StreamingSpeech: Sendable {
    func start(input: AsyncStream<CapturedAudio>, format: AVAudioFormat) async throws
    func finish() async throws
    func cancel() async
}

actor AppleSpeechService: StreamingSpeech {
    private let text: PhraseCleanupService
    private let failure: @Sendable () async -> Void
    private var analyzer: SpeechAnalyzer?
    private var source: Task<Void, Error>?
    private var results: Task<Void, Error>?
    private var detection: Task<Void, Error>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var cancelled = false
    init(text: PhraseCleanupService, failure: @escaping @Sendable () async -> Void) { self.text = text; self.failure = failure }
    static func transcriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    }
    func start(input: AsyncStream<CapturedAudio>, format: AVAudioFormat) async throws {
        guard SpeechTranscriber.isAvailable else { throw ProviderFailure(message: "Apple’s streaming speech isn’t supported on this device.") }
        let transcriber = Self.transcriber()
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        let modules: [any SpeechModule] = [transcriber, detector]
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw ProviderFailure(message: "Download Apple Speech in TapType’s on-device models, then try again.")
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: format) else {
            throw ProviderFailure(message: "This microphone isn’t ready for Apple Speech. Please reconnect it.")
        }
        let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .userInitiated, modelRetention: .lingering))
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: target)
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(256))
        continuation = pair.continuation
        let text = self.text, failure = self.failure
        results = Task {
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    await text.receive(.init(start: result.range.start.seconds, end: result.range.end.seconds,
                                             text: String(result.text.characters), isFinal: result.isFinal))
                }
            } catch { if !Task.isCancelled { await failure() }; throw error }
        }
        detection = Task {
            do {
                for try await result in detector.results {
                    try Task.checkCancellation()
                    if !result.speechDetected && result.range.duration.seconds >= 0.6 {
                        // VAD is a boundary hint, never evidence that provisional text is final.
                        await text.silence(through: result.range.start.seconds)
                        try await analyzer.finalize(through: result.range.start)
                    }
                }
            } catch { if !Task.isCancelled { await failure() }; throw error }
        }
        try await analyzer.start(inputSequence: pair.stream)
        source = Task {
            do {
                let converter = AVAudioConverter(from: format, to: target)
                converter?.primeMethod = .none
                for await packet in input {
                    try Task.checkCancellation()
                    guard packet.buffer.format == format else { throw ProviderFailure(message: "Your microphone changed. Finish this dictation and start again.") }
                    let converted: AVAudioPCMBuffer
                    if format == target { converted = packet.buffer }
                    else {
                        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(packet.buffer.frameLength) * target.sampleRate / format.sampleRate)) + 1024) else { throw CancellationError() }
                        var supplied = false, error: NSError?
                        let status = converter.convert(to: out, error: &error) { _, state in
                            if supplied { state.pointee = .noDataNow; return nil }
                            supplied = true; state.pointee = .haveData; return packet.buffer
                        }
                        guard status != .error, error == nil else { throw error ?? ProviderFailure(message: "Your microphone couldn’t be read. Please try again.") as NSError }
                        converted = out
                    }
                    if converted.frameLength > 0, case .dropped = pair.continuation.yield(AnalyzerInput(buffer: converted)) {
                        throw ProviderFailure(message: "Speech couldn’t keep up. Finish this dictation and start a new one.")
                    }
                }
                pair.continuation.finish()
            } catch { pair.continuation.finish(); if !Task.isCancelled { await failure() }; throw error }
        }
    }
    func finish() async throws {
        try await source?.value
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try await results?.value
        try await detection?.value
        await text.finishRecognition()
    }
    func cancel() async {
        cancelled = true
        source?.cancel(); results?.cancel(); detection?.cancel(); continuation?.finish()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
    }
}

// Batch-only providers stream completed audio phrases, rather than uploading the whole recording on Stop.
actor PhraseSpeechService: StreamingSpeech {
    private let provider: SpeechProvider
    private let selection: CloudSelection?
    private let text: PhraseCleanupService
    private let failure: @Sendable () async -> Void
    private var producer: Task<Void, Error>?
    private var consumer: Task<Void, Error>?
    private var continuation: AsyncStream<(AudioClip, Double, Double, PhraseEnd)>.Continuation?
    /// How a phrase ended. Only a pause counts as a sentence break for cleanup; breaths
    /// and cuts rely on Whisper's punctuation.
    enum PhraseEnd: Sendable { case pause, breath, cut }
    init(provider: SpeechProvider, selection: CloudSelection?, text: PhraseCleanupService, failure: @escaping @Sendable () async -> Void) {
        self.provider = provider; self.selection = selection; self.text = text; self.failure = failure
    }
    func start(input: AsyncStream<CapturedAudio>, format: AVAudioFormat) async throws {
        // Room for about three minutes of six-second phrases, so speech keeps queueing
        // while a model is still loading instead of failing the dictation.
        // Each phrase carries how it ended: a pause, a short breath, or a cut mid-speech.
        let pair = AsyncStream<(AudioClip, Double, Double, PhraseEnd)>.makeStream(bufferingPolicy: .bufferingOldest(32))
        continuation = pair.continuation
        let text = self.text, provider = self.provider, selection = self.selection, failure = self.failure
        producer = Task {
            var samples: [Float] = [], time = 0.0, began = 0.0, silence = 0.0, voiced = false
            var preRoll: [Float] = []
            // Loudness of each buffer in the current phrase, to find a quiet place to split.
            var loudness: [(offset: Int, rms: Float)] = []
            let rate = format.sampleRate
            // On-device models get shorter phrases for faster text. Cloud phrases stay
            // longer: providers such as Groq bill a minimum duration per request.
            let local = selection == nil, longest: Double = local ? 6 : 12
            func emit(_ phrase: [Float], from start: Double, ending: PhraseEnd = .pause) throws {
                if case .dropped = pair.continuation.yield((.init(samples: phrase, sampleRate: rate), start, start + Double(phrase.count) / rate, ending)) {
                    throw ProviderFailure(message: "Transcription couldn’t keep up. Please finish this dictation.")
                }
            }
            func send(ending: PhraseEnd = .pause) throws {
                defer { samples.removeAll(keepingCapacity: true); loudness.removeAll(keepingCapacity: true); voiced = false; silence = 0 }
                guard voiced, !samples.isEmpty else { return }
                try emit(samples, from: began, ending: ending)
            }
            /// Sends the phrase up to the quietest stretch in its last two seconds and keeps
            /// the rest, so long unbroken speech still reaches Whisper in short pieces.
            /// Quietness is averaged over ~150 ms so the cut lands between words, not in the
            /// brief silence inside one (such as before a "p"). Pieces don't overlap: the
            /// transcript treats overlapping time ranges as replacements.
            func splitAtQuietestPoint() throws {
                let window = Int(rate * 2), span = 3
                var best: (index: Int, rms: Float)?
                for index in loudness.indices where loudness[index].offset >= max(Int(rate), samples.count - window) {
                    let around = loudness[max(0, index - span)...min(loudness.count - 1, index + span)]
                    let mean = around.reduce(0) { $0 + $1.rms } / Float(around.count)
                    if best == nil || mean < best!.rms { best = (index, mean) }
                }
                guard let best, case let cut = loudness[best.index].offset, cut > 0 else { try send(ending: .cut); return }
                try emit(Array(samples[..<cut]), from: began, ending: .cut)
                samples.removeFirst(cut)
                loudness = loudness.compactMap { $0.offset >= cut ? ($0.offset - cut, $0.rms) : nil }
                began += Double(cut) / rate
                silence = 0
            }
            do {
                for await packet in input {
                    try Task.checkCancellation()
                    guard packet.buffer.format == format, let channel = packet.buffer.floatChannelData?[0] else { throw CancellationError() }
                    let count = Int(packet.buffer.frameLength), duration = Double(count) / rate
                    var power: Float = 0
                    for i in 0..<count { power += channel[i] * channel[i] }
                    let rms = sqrt(power / Float(max(count, 1)))
                    let speech = rms > 0.008
                    if speech && !voiced {
                        began = max(0, time - Double(preRoll.count) / rate)
                        samples = preRoll; preRoll.removeAll(keepingCapacity: true); voiced = true
                    }
                    time += duration
                    if voiced {
                        loudness.append((samples.count, rms))
                        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
                        silence = speech ? 0 : silence + duration
                        let length = Double(samples.count) / rate
                        // A short pause ends an on-device phrase once it has some length, but
                        // only a pause of 0.65 s or more counts as a sentence break for cleanup.
                        if silence >= 0.65 { try send() }
                        else if local && length >= 3 && silence >= 0.3 { try send(ending: .breath) }
                        else if length >= longest { if local { try splitAtQuietestPoint() } else { try send() } }
                    } else {
                        preRoll.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
                        let excess = preRoll.count - Int(rate * 0.2)
                        if excess > 0 { preRoll.removeFirst(excess) }
                    }
                }
                try send(); pair.continuation.finish()
            } catch { pair.continuation.finish(); if !Task.isCancelled { await failure() }; throw error }
        }
        consumer = Task {
            do {
                var priorTranscript = ""
                for await (clip, start, end, ending) in pair.stream {
                    try Task.checkCancellation()
                    let samples = try clip.mono16k()
                    let decoded: String
                    if let selection { decoded = try await CloudModels.transcribe(samples, selection: selection) }
                    else { decoded = try await ModelStore.shared.transcribe(samples, model: provider.rawValue, keepLoaded: true) }
                    try Task.checkCancellation()
                    let value = selection == nil
                        ? TranscriptEchoReducer.removingImmediateEchoes(from: TranscriptEchoReducer.removingLeadingEcho(from: decoded, after: priorTranscript))
                        : decoded
                    // A VAD false positive can decode to silence; it must not end a long dictation.
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    if selection == nil { priorTranscript = value }
                    await text.receive(.init(start: start, end: end, text: value, isFinal: true))
                    if ending == .pause { await text.silence(through: end) }
                }
                // The model stays loaded for the next dictation; releasing the mic unloads it.
            } catch {
                if selection == nil { await ModelStore.shared.releasePhraseModel() }
                if !Task.isCancelled { await failure() }; throw error
            }
        }
    }
    func finish() async throws { try await producer?.value; try await consumer?.value; await text.finishRecognition() }
    func cancel() async {
        producer?.cancel(); consumer?.cancel(); continuation?.finish()
        _ = await consumer?.result
    }
}

@MainActor
final class AppleSpeechAssets: ObservableObject {
    static let shared = AppleSpeechAssets()
    @Published private(set) var installed = false
    @Published private(set) var downloading = false
    @Published private(set) var notice: String?
    private var task: Task<Void, Never>?
    func refresh() async {
        installed = await AssetInventory.status(forModules: [AppleSpeechService.transcriber()]) == .installed
    }
    func download() {
        guard !downloading else { return }
        downloading = true; notice = "Downloading Apple Speech…"
        task = Task {
            do {
                try await AssetInventory.reserve(locale: Locale(identifier: "en-US"))
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [AppleSpeechService.transcriber()]) { try await request.downloadAndInstall() }
                try Task.checkCancellation()
                await refresh(); notice = installed ? nil : "Apple Speech is still getting ready. Please try again."
            } catch { notice = Task.isCancelled ? "Download paused. You can try again later." : "Couldn’t download Apple Speech. Connect to Wi-Fi and try again." }
            downloading = false; task = nil
        }
    }
    func cancel() { task?.cancel() }
}
