import Foundation
import CryptoKit
import SwiftUI
import WhisperKit
import ArgmaxCore

struct DownloadableModel: Decodable, Identifiable {
    struct File: Decodable {
        let path: String
        let url: URL
        let bytes: Int64
        let sha256: String
    }
    let id: String
    let name: String
    let files: [File]
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64) -> Void
    init(_ update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { update(totalBytesWritten) }
}

@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()
    let models: [DownloadableModel]
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloading: String?
    @Published private(set) var fraction: Double = 0
    @Published private(set) var inUse = false
    @Published var notice: String?
    private var downloadTask: Task<Void, Never>?
    private var phrasePipeline: WhisperKit?
    private var phraseModel: String?
    private let manager = FileManager.default
    private var root: URL {
        manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models", isDirectory: true)
    }
    init() {
        models = (try? JSONDecoder().decode([DownloadableModel].self, from: Data(contentsOf: Bundle.main.url(forResource: "ModelCatalog", withExtension: "json")!))) ?? []
        refresh()
    }
    private func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private func refresh() {
        installed = Set(models.filter { manager.fileExists(atPath: folder($0.id).appendingPathComponent("installed").path) }.map(\.id))
    }
    func location(_ id: String) throws -> URL {
        guard installed.contains(id) else { throw ProviderFailure(message: "Download this model in TapType’s On-device models settings first.") }
        return folder(id)
    }
    nonisolated static func matches(_ url: URL, file: DownloadableModel.File) throws -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) == file.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }
    func download(_ model: DownloadableModel) {
        guard downloading == nil, !inUse, !installed.contains(model.id) else { return }
        downloading = model.id; fraction = 0; notice = nil
        downloadTask = Task {
            defer { downloading = nil; downloadTask = nil; refresh() }
            do {
                var root = self.root
                try manager.createDirectory(at: root, withIntermediateDirectories: true)
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                guard capacity > model.bytes + 200_000_000 else { throw ProviderFailure(message: "Free up more space on your iPhone, then try this download again.") }
                let staging = root.appendingPathComponent(".\(model.id).partial", isDirectory: true)
                try manager.createDirectory(at: staging, withIntermediateDirectories: true)
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                var completed: Int64 = 0
                for file in model.files {
                    try Task.checkCancellation()
                    guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains(".."),
                          file.url.scheme == "https", file.url.host == "huggingface.co", file.bytes > 0,
                          file.sha256.count == 64 else { throw ProviderFailure(message: "This model’s download details are unavailable. Please update TapType.") }
                    let destination = staging.appendingPathComponent(file.path)
                    let existing = try await Task.detached { try Self.matches(destination, file: file) }.value
                    if !existing {
                        let before = completed, total = model.bytes
                        let delegate = DownloadProgress { [weak self] bytes in
                            Task { @MainActor in
                                guard self?.downloading == model.id else { return }
                                self?.fraction = min(1, Double(before + bytes) / Double(total))
                            }
                        }
                        let (temporary, response) = try await session.download(from: file.url, delegate: delegate)
                        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                              try await Task.detached(operation: { try Self.matches(temporary, file: file) }).value else {
                            try? manager.removeItem(at: temporary)
                            throw ProviderFailure(message: "The download couldn’t be verified. Tap Download to retry.")
                        }
                        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                        try manager.moveItem(at: temporary, to: destination)
                    }
                    completed += file.bytes; fraction = Double(completed) / Double(model.bytes)
                }
                try Task.checkCancellation()
                try Data("1".utf8).write(to: staging.appendingPathComponent("installed"), options: .atomic)
                if manager.fileExists(atPath: folder(model.id).path) { try manager.removeItem(at: folder(model.id)) }
                try manager.moveItem(at: staging, to: folder(model.id))
                notice = "\(model.name) is ready. Choose it under Speech model."
            } catch {
                if Task.isCancelled { notice = "Download paused. Tap Download to continue." }
                else { notice = (error as? ProviderFailure)?.message ?? "Download stopped. Check your connection and storage, then try again." }
            }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func remove(_ id: String) {
        guard !inUse, downloading != id, models.contains(where: { $0.id == id }) else { return }
        guard phraseModel != id else { notice = "Finish your dictation before removing this model."; return }
        do {
            try manager.removeItem(at: folder(id))
            if SpeechProvider.selected.rawValue == id { UserDefaults.standard.set("apple", forKey: "speechProvider") }
            refresh(); notice = "Model removed."
        } catch { notice = "Couldn’t remove this model. Please try again." }
    }
    func releasePhraseModel() async {
        guard !inUse else { return }
        let pipeline = phrasePipeline
        phrasePipeline = nil; phraseModel = nil
        await pipeline?.unloadModels()
    }
    func transcribe(_ samples: [Float], model id: String, keepLoaded: Bool = false) async throws -> String {
        guard !inUse else { throw ProviderFailure(message: "A dictation is already finishing. Please wait a moment.") }
        let location = try location(id)
        inUse = true; defer { inUse = false }
        let pipeline: WhisperKit
        if let existing = phrasePipeline, phraseModel == id { pipeline = existing }
        else {
            await phrasePipeline?.unloadModels(); phrasePipeline = nil; phraseModel = nil
            // Validate locally first so WhisperKit cannot silently download a missing tokenizer.
            do { _ = try await AutoTokenizerWrapper.from(modelFolder: location) }
            catch { throw ProviderFailure(message: "This model’s files need to be downloaded again. Remove the model and retry its download.") }
            try Task.checkCancellation()
            pipeline = try await WhisperKit(WhisperKitConfig(modelFolder: location.path, tokenizerFolder: location,
                verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
            if keepLoaded { phrasePipeline = pipeline; phraseModel = id }
        }
        do {
            try Task.checkCancellation()
            let result = try await pipeline.transcribe(audioArray: samples,
                decodeOptions: DecodingOptions(verbose: false, language: "en", temperatureFallbackCount: 0,
                    skipSpecialTokens: true, withoutTimestamps: true, concurrentWorkerCount: 1))
            if !keepLoaded { await pipeline.unloadModels(); phrasePipeline = nil; phraseModel = nil }
            try Task.checkCancellation()
            let text = result.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--whisper-fixture") { print("WHISPER_PHRASE: seconds=\(Double(samples.count) / 16000) words=\(text.split(whereSeparator: \.isWhitespace).count)") }
            #endif
            guard !text.isEmpty || keepLoaded else { throw ProviderFailure(message: "We didn’t hear any speech. Please try again.") }
            return text
        } catch {
            await pipeline.unloadModels()
            phrasePipeline = nil; phraseModel = nil
            if error is CancellationError { throw error }
            throw (error as? ProviderFailure) ?? ProviderFailure(message: "This model couldn’t finish. Try a shorter dictation or choose Apple Speech.")
        }
    }
}
