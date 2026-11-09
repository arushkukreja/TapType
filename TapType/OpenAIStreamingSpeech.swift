import Foundation
@preconcurrency import AVFoundation

// One encoder per dictation preserves the converter's state across microphone chunks.
final class LivePCMEncoder: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private var rate: Double?
    func encode(_ clip: AudioClip) throws -> Data {
        guard !clip.samples.isEmpty else { return Data() }
        guard clip.sampleRate.isFinite, (8000...192000).contains(clip.sampleRate),
              clip.samples.count <= Int(clip.sampleRate * 5) else {
            throw ProviderFailure(message: "Live audio couldn’t be prepared. Please start again.")
        }
        if let rate, rate != clip.sampleRate {
            throw ProviderFailure(message: "Your microphone changed. Please start dictation again.")
        }
        let input = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1)!
        let output = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        if converter == nil { converter = AVAudioConverter(from: input, to: output); converter?.primeMethod = .none; rate = clip.sampleRate }
        guard let converter,
              let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(clip.samples.count)),
              let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(ceil(Double(clip.samples.count) * 24000 / clip.sampleRate) + 512)) else {
            throw ProviderFailure(message: "Live audio couldn’t be prepared. Please start again.")
        }
        source.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        var supplied = false, failure: NSError?
        let status = converter.convert(to: target, error: &failure) { _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        guard status != .error, failure == nil else { throw ProviderFailure(message: "Live audio couldn’t be prepared. Please start again.") }
        var data = Data(capacity: Int(target.frameLength) * 2)
        for i in 0..<Int(target.frameLength) {
            let sample = target.floatChannelData![0][i]
            var value = Int16((sample.isFinite ? max(-1, min(1, sample)) : 0) * 32767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}


struct SpeechCommitOrder {
    private var links: [String: String] = [:]
    private var previous = ""
    private var seen: Set<String> = []
    mutating func receive(id: String, previousID: String?) -> [String] {
        guard !seen.contains(id), links.count < 16 else { return [] }
        links[previousID ?? ""] = id
        var ordered: [String] = []
        while let next = links.removeValue(forKey: previous), !seen.contains(next) {
            seen.insert(next); previous = next; ordered.append(next)
        }
        return ordered
    }
}

actor OpenAIStreamingSpeech: StreamingSpeech {
    private struct Turn { let start: Double; let end: Double; let usage: UUID; var id: String? }
    private struct Output { var partial = ""; var final: String? }
    private let selection: CloudSelection
    private let text: PhraseCleanupService
    private let failure: @Sendable () async -> Void
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Error>?
    private var producer: Task<Void, Error>?
    private var ready = false, cancelled = false
    private var turns: [Turn] = []
    private var commitOrder = SpeechCommitOrder()
    private var delivered: Set<String> = []
    private var output: [String: Output] = [:]
    private var usage: UUID?
    private var turnBytes = 0
    private var clock = 0.0, turnStart = 0.0, silence = 0.0
    private var turnHadVoice = false
    init(selection: CloudSelection, text: PhraseCleanupService, failure: @escaping @Sendable () async -> Void) {
        self.selection = selection; self.text = text; self.failure = failure
    }
    func start(input: AsyncStream<CapturedAudio>, format: AVAudioFormat) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer " + selection.key, forHTTPHeaderField: "Authorization"); request.timeoutInterval = 10
        let socket = session.webSocketTask(with: request); self.socket = socket
        socket.maximumMessageSize = 2_000_000; socket.resume()
        receiver = Task {
            do {
                while !Task.isCancelled && !cancelled {
                    let event = try await socket.receive(), data: Data
                    switch event { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: throw CancellationError() }
                    guard data.count < 2_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CancellationError() }
                    try await receive(object)
                }
            } catch { if !cancelled { await failure() }; throw error }
        }
        try await send(["type": "session.update", "session": ["type": "transcription", "audio": ["input": [
            "format": ["type": "audio/pcm", "rate": 24000], "transcription": ["model": selection.model], "turn_detection": NSNull()]]]])
        let until = ProcessInfo.processInfo.systemUptime + 10
        while !ready && !cancelled && ProcessInfo.processInfo.systemUptime < until { try await Task.sleep(for: .milliseconds(20)) }
        guard ready, !cancelled else { throw ProviderFailure(message: "Cloud speech couldn’t connect. Check your API key, connection and model.") }
        producer = Task {
            let encoder = LivePCMEncoder()
            do {
                for await packet in input {
                    try Task.checkCancellation()
                    guard packet.buffer.format == format, let channel = packet.buffer.floatChannelData?[0] else { throw CancellationError() }
                    let values = Array(UnsafeBufferPointer(start: channel, count: Int(packet.buffer.frameLength)))
                    let power = values.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, values.count))
                    let data = try encoder.encode(.init(samples: values, sampleRate: format.sampleRate))
                    try await push(data, voiced: sqrt(power) > 0.008)
                }
                try await commit()
            } catch { if !cancelled && !Task.isCancelled { await failure() }; throw error }
        }
    }
    private func send(_ message: [String: Any]) async throws {
        guard !cancelled, let socket else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    private func push(_ data: Data, voiced: Bool) async throws {
        guard !data.isEmpty else { return }
        let duration = Double(data.count) / 48000
        clock += duration
        if usage == nil {
            let created = await CloudUsageStore.shared.begin(.init(provider: selection.provider.rawValue, model: selection.model, writing: false), seconds: 0)
            guard !cancelled, !Task.isCancelled else {
                await CloudUsageStore.shared.markPurpose(created, "Cancelled")
                throw CancellationError()
            }
            usage = created
            turnStart = clock - duration
        }
        try await append(data)
        turnHadVoice = turnHadVoice || voiced
        silence = voiced ? 0 : silence + duration
        if (turnHadVoice && silence >= 0.65) || turnBytes >= 12 * 48000 { try await commit() }
    }
    private func append(_ data: Data) async throws {
        guard let usage else { return }
        turnBytes += data.count
        await CloudUsageStore.shared.streamAudio(usage, seconds: Double(turnBytes) / 48000)
        try await send(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
    }
    private func commit() async throws {
        guard let usage, turnBytes > 0 else { return }
        guard turns.count < 8 else { throw ProviderFailure(message: "Cloud speech couldn’t keep up. Please finish this dictation.") }
        turns.append(.init(start: turnStart, end: clock, usage: usage))
        self.usage = nil; turnBytes = 0; silence = 0; turnHadVoice = false
        try await send(["type": "input_audio_buffer.commit"])
    }
    private func receive(_ event: [String: Any]) async throws {
        if let id = event["item_id"] as? String, delivered.contains(id) { return }
        switch event["type"] as? String {
        case "session.updated": ready = true
        case "input_audio_buffer.committed":
            if let id = event["item_id"] as? String {
                for ordered in commitOrder.receive(id: id, previousID: event["previous_item_id"] as? String) {
                    if let index = turns.firstIndex(where: { $0.id == nil }) { turns[index].id = ordered }
                }
            }
        case "conversation.item.input_audio_transcription.delta":
            if let id = event["item_id"] as? String, let delta = event["delta"] as? String, output.count < 12 {
                var result = output[id] ?? Output(); result.partial += delta
                guard result.partial.count < 20_000 else { throw CancellationError() }
                output[id] = result
            }
        case "conversation.item.input_audio_transcription.completed":
            if let id = event["item_id"] as? String, let final = event["transcript"] as? String, final.count < 20_000, output.count < 12 {
                var result = output[id] ?? Output(); result.final = final; output[id] = result
            }
        case "error", "conversation.item.input_audio_transcription.failed":
            throw ProviderFailure(message: "Cloud speech couldn’t finish. Check your model, key and quota.")
        default: break
        }
        // Only release consecutive turns; later final responses must not overtake earlier ones.
        while let turn = turns.first, let id = turn.id, let result = output[id] {
            if let final = result.final {
                await text.receive(.init(start: turn.start, end: turn.end, text: final, isFinal: true))
                await text.silence(through: turn.end)
                await CloudUsageStore.shared.complete(turn.usage, data: Data())
                await CloudUsageStore.shared.markPurpose(turn.usage, "Completed phrase")
                delivered.insert(id); turns.removeFirst(); output.removeValue(forKey: id)
            } else {
                if !result.partial.isEmpty { await text.receive(.init(start: turn.start, end: turn.end, text: result.partial, isFinal: false)) }
                break
            }
        }
    }
    func finish() async throws {
        try await producer?.value
        let until = ProcessInfo.processInfo.systemUptime + 15
        while !turns.isEmpty, !cancelled, ProcessInfo.processInfo.systemUptime < until { try await Task.sleep(for: .milliseconds(25)) }
        guard turns.isEmpty, !cancelled else { await cancel(); throw ProviderFailure(message: "Cloud speech took too long. Your confirmed words are kept.") }
        receiver?.cancel(); socket?.cancel(with: .normalClosure, reason: nil); session?.invalidateAndCancel()
        cancelled = true
        await text.finishRecognition()
    }
    func cancel() async {
        cancelled = true; producer?.cancel(); receiver?.cancel()
        socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel()
        if let usage { await CloudUsageStore.shared.markPurpose(usage, "Cancelled") }
        for turn in turns { await CloudUsageStore.shared.markPurpose(turn.usage, "Interrupted phrase") }
        usage = nil; turns.removeAll(); output.removeAll()
    }
}
