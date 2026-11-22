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
    /// Installed models that have been loaded once, so iOS has optimized them for this
    /// iPhone's chip. That first load can take minutes for large models; doing it here
    /// keeps it out of a dictation.
    @Published private(set) var prepared: Set<String> = []
    @Published private(set) var preparing: String?
    private var prepareTask: Task<Void, Never>?
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
        prepared = Set(installed.filter { manager.fileExists(atPath: folder($0).appendingPathComponent("prepared").path) })
    }
    /// Prepares every installed model that hasn't been prepared yet, one at a time.
    func prepareInstalledModels() {
        guard preparing == nil, !inUse, downloading == nil,
              let next = models.first(where: { installed.contains($0.id) && !prepared.contains($0.id) }) else { return }
        preparing = next.id
        let location = folder(next.id)
        prepareTask = Task {
            defer { preparing = nil; prepareTask = nil }
            do {
                // Validate locally first so WhisperKit cannot silently download a missing tokenizer.
                _ = try await AutoTokenizerWrapper.from(modelFolder: location)
                // prewarm loads and unloads each part in turn, which triggers and caches
                // iOS's on-device optimization without holding the whole model in memory.
                let pipeline = try await WhisperKit(WhisperKitConfig(modelFolder: location.path, tokenizerFolder: location,
                    verbose: false, logLevel: .none, prewarm: true, load: false, download: false))
                await pipeline.unloadModels()
                try Data("1".utf8).write(to: location.appendingPathComponent("prepared"), options: .atomic)
                refresh()
                notice = "\(next.name) is ready. Choose it under Speech model."
                prepareInstalledModels()
            } catch {
                notice = "\(next.name) couldn’t get ready. Uninstall it and download it again."
            }
        }
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
                notice = "\(model.name) downloaded. Getting it ready for this iPhone. The first time can take a few minutes."
                Task { @MainActor in self.prepareInstalledModels() }
            } catch {
                if Task.isCancelled { notice = "Download paused. Tap Download to continue." }
                else { notice = (error as? ProviderFailure)?.message ?? "Download stopped. Check your connection and storage, then try again." }
            }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func remove(_ id: String) {
        guard !inUse, downloading != id, preparing != id, loadTask?.id != id, models.contains(where: { $0.id == id }) else { return }
        guard phraseModel != id else { notice = "Finish your dictation before removing this model."; return }
        do {
            try manager.removeItem(at: folder(id))
            if SpeechProvider.selected.rawValue == id { UserDefaults.standard.set("apple", forKey: "speechProvider") }
            refresh(); notice = "Model removed."
        } catch { notice = "Couldn’t remove this model. Please try again." }
    }
    /// Unloads the phrase model. Called when the microphone is released, on memory
    /// warnings, and after errors; it stays loaded between dictations otherwise.
    func releasePhraseModel() async {
        guard !inUse else { return }
        if let load = loadTask { _ = try? await load.task.value }
        guard !inUse else { return }
        let pipeline = phrasePipeline
        phrasePipeline = nil; phraseModel = nil
        await pipeline?.unloadModels()
    }
    /// Starts loading a prepared model in the background so the first phrase of a
    /// dictation doesn't wait for it. Does nothing if it's already loaded or loading.
    func preload(_ id: String) {
        guard prepared.contains(id), preparing == nil, phraseModel != id, loadTask?.id != id else { return }
        Task { _ = try? await phrasePipeline(for: id) }
    }
    private var loadTask: (id: String, task: Task<WhisperKit, Error>)?
    /// The loaded pipeline for `id`, loading it once and sharing an in-flight load.
    private func phrasePipeline(for id: String) async throws -> WhisperKit {
        if let existing = phrasePipeline, phraseModel == id { return existing }
        if let load = loadTask, load.id == id { return try await load.task.value }
        let location = try location(id)
        let previous = phrasePipeline
        phrasePipeline = nil; phraseModel = nil
        await previous?.unloadModels()
        let task = Task { () throws -> WhisperKit in
            // Validate locally first so WhisperKit cannot silently download a missing tokenizer.
            do { _ = try await AutoTokenizerWrapper.from(modelFolder: location) }
            catch { throw ProviderFailure(message: "This model’s files need to be downloaded again. Remove the model and retry its download.") }
            return try await WhisperKit(WhisperKitConfig(modelFolder: location.path, tokenizerFolder: location,
                verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
        }
        loadTask = (id, task)
        do {
            let pipeline = try await task.value
            if loadTask?.id == id { loadTask = nil }
            phrasePipeline = pipeline; phraseModel = id
            return pipeline
        } catch {
            if loadTask?.id == id { loadTask = nil }
            throw error
        }
    }
    func transcribe(_ samples: [Float], model id: String, keepLoaded: Bool = false) async throws -> String {
        guard !inUse else { throw ProviderFailure(message: "A dictation is already finishing. Please wait a moment.") }
        guard preparing == nil else { throw ProviderFailure(message: "A downloaded model is getting ready. Try again in a few minutes, or choose Apple Speech.") }
        inUse = true; defer { inUse = false }
        let pipeline = try await phrasePipeline(for: id)
        #if DEBUG
        let decodeStart = ProcessInfo.processInfo.systemUptime
        #endif
        do {
            try Task.checkCancellation()
            let result = try await pipeline.transcribe(audioArray: samples,
                // Phrases reach Whisper only after the level check heard sound, so treat a
                // phrase as silent only when Whisper is nearly certain. Its default (0.6)
                // dropped whole phrases of real speech when they started mid-sentence.
                decodeOptions: DecodingOptions(verbose: false, language: "en", temperatureFallbackCount: 0,
                    skipSpecialTokens: true, withoutTimestamps: true, noSpeechThreshold: 0.95, concurrentWorkerCount: 1))
            if !keepLoaded { await pipeline.unloadModels(); phrasePipeline = nil; phraseModel = nil }
            try Task.checkCancellation()
            let text = result.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--whisper-fixture") { print("WHISPER_PHRASE: seconds=\(Double(samples.count) / 16000) decode=\(ProcessInfo.processInfo.systemUptime - decodeStart) words=\(text.split(whereSeparator: \.isWhitespace).count) text=\(text)") }
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
