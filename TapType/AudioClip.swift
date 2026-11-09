import Foundation
@preconcurrency import AVFoundation

struct AudioClip: Sendable {
    let samples: [Float]
    let sampleRate: Double
    func mono16k() throws -> [Float] {
        guard !samples.isEmpty, sampleRate.isFinite, (8000...192000).contains(sampleRate), samples.count <= Int(sampleRate * 60) else {
            throw ProviderFailure(message: "This recording is empty or too long. Please try again.")
        }
        if sampleRate == 16000 { return samples }
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 16000 / sampleRate) + 1024)),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ProviderFailure(message: "Couldn’t prepare this recording. Please try again.")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        var supplied = false, failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            guard !supplied else { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        guard status != .error, failure == nil, output.frameLength > 0 else {
            throw ProviderFailure(message: "Couldn’t prepare this recording. Please try again.")
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
    static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func text(_ s: String) { data.append(Data(s.utf8)) }
        func u16(_ n: UInt16) { var value = n.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var value = n.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(samples.count * 2 + 36)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16); text("data"); u32(UInt32(samples.count * 2))
        for sample in samples {
            let sample = sample.isFinite ? max(-1, min(1, sample)) : 0
            u16(UInt16(bitPattern: Int16(sample * 32767)))
        }
        return data
    }
}
