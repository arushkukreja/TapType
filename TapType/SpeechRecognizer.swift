@preconcurrency import AVFoundation
import Speech
import SwiftUI
import ActivityKit

@MainActor
final class SpeechRecognizer: NSObject, ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var originalTranscript = ""
    @Published private(set) var provisionalTranscript = ""
    @Published private(set) var finalizedTranscript = ""
    @Published private(set) var refinedTranscript = ""
    @Published private(set) var lastCompletedText = ""
    @Published private(set) var cleanupNotice: String?
    @Published private(set) var isCleaning = false
    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isStarting = false
    @Published private(set) var sessionEnabled = false
    @Published private(set) var awaitingConfirmation = false
    @Published private(set) var activityNotice: String?
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var status = "Ready when you are"
    @Published var errorMessage: String?
    @Published var readinessMinutes = ReadySessionOptions.validated(UserDefaults.standard.object(forKey: "readinessMinutes") as? Int) {
        didSet {
            UserDefaults.standard.set(readinessMinutes, forKey: "readinessMinutes")
            if !isRecording && !isStarting {
                if readinessMinutes == 0 { releaseMicrophone(keepPolling: isProcessing) }
                else if sessionEnabled && engine.isRunning { readiness.reset(); readiness.beginIdle(now: uptime, minutes: readinessMinutes) }
            }
            publish()
        }
    }
    private let engine = AVAudioEngine()
    private let sink = StreamingAudioSink()
    private var speechService: (any StreamingSpeech)?
    private var cleanupService: PhraseCleanupService?
    private var finishTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var teardown: Task<Void, Never>?
    private var timer: Timer?
    private var generation = UUID()
    private var preparationGeneration = UUID()
    private var transcriptID = UUID().uuidString
    private var lastCommand = ""
    private var finalResult = false
    private var commitRequested = false
    private var tapInstalled = false
    private var handoffPending = false
    private var finishingTime: UIBackgroundTaskIdentifier = .invalid
    private var readiness = MicrophoneReadinessWindow()
    private var sessionExpiry = Date.distantPast
    private var activity: Activity<VoiceActivityAttributes>?
    private var activityPhase = ""
    private var activityUpdate: Task<Void, Never>?
    private var uptime: Double { ProcessInfo.processInfo.systemUptime }
    private let performance = DictationPerformance.shared
    var microphoneIsActive: Bool { engine.isRunning }
    var usesOnDeviceRecognition: Bool { SpeechProvider.selected.cloud == nil }
    var isReadyBetweenDictations: Bool { sessionEnabled && engine.isRunning && !isRecording && !isProcessing && !isStarting }
    var canFinishInApp: Bool { isRecording || isProcessing || awaitingConfirmation }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged), name: .AVAudioEngineConfigurationChange, object: engine)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    @objc private func interrupted(_ notification: Notification) {
        guard (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
        if isRecording { cleanupNotice = "Microphone interrupted. Finish to use your confirmed words."; stop() }
        releaseMicrophone(keepPolling: isProcessing); publish()
    }
    @objc nonisolated private func routeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, sessionEnabled, !engine.isRunning else { return }
            if isRecording { cleanupNotice = "Your microphone changed. Finish to use your confirmed words."; stop() }
            releaseMicrophone(keepPolling: isProcessing); publish()
        }
    }
    @objc private func backgrounded(_ notification: Notification) { appDidEnterBackground() }
    func appDidEnterBackground() {
        guard !isRecording, !isProcessing, !isStarting, !handoffPending else { return }
        if readinessMinutes != 0 && engine.isRunning && readiness.isOpen(now: uptime) { return }
        releaseMicrophone(); publish()
    }
    func enableSession() async {
        guard !isStarting, !isProcessing, !sessionEnabled else { return }
        isStarting = true
        let token = preparationGeneration
        defer { if preparationGeneration == token { isStarting = false }; publish() }
        guard await permissions(), token == preparationGeneration else { return }
        // URL handoffs can reach SwiftUI before the scene is active enough to claim audio input.
        let activationDeadline = uptime + 3
        while UIApplication.shared.applicationState != .active && uptime < activationDeadline && token == preparationGeneration {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard token == preparationGeneration else { return }
        guard UIApplication.shared.applicationState == .active else {
            errorMessage = "Unlock your iPhone and open TapType to start the microphone."
            return
        }
        do {
            guard KeyboardBridge.root != nil else { throw ProviderFailure(message: "The keyboard couldn’t connect. Please reopen TapType.") }
            try startEngine(); sessionEnabled = true; sessionExpiry = Date().addingTimeInterval(60)
            lastCommand = KeyboardBridge.read("command.json")["id"] as? String ?? ""
            startTimer()
        } catch { failStart(error) }
    }
    private func startTimer() {
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } } }
    }
    func start(requestID: String = UUID().uuidString) async {
        guard !isStarting, !isRecording, !isProcessing else { return }
        let preparation = preparationGeneration
        await teardown?.value; teardown = nil
        guard preparation == preparationGeneration, !isStarting, !isRecording, !isProcessing else { return }
        if !sessionEnabled { await enableSession() }
        guard preparation == preparationGeneration, sessionEnabled, !isStarting, !isRecording, !isProcessing else { return }
        isStarting = true; generation = UUID(); let epoch = generation
        transcriptID = requestID; errorMessage = nil; cleanupNotice = nil
        transcript = ""; originalTranscript = ""; provisionalTranscript = ""; finalizedTranscript = ""; refinedTranscript = ""
        finalResult = false; commitRequested = false; awaitingConfirmation = false
        performance.begin()
        let mode = CleanupMode.selected
        do {
            let provider = SpeechProvider.selected
            if provider.downloaded { _ = try ModelStore.shared.location(provider.rawValue) }
            let selection = try provider.cloud.map { try CloudSelection($0) }
            let cleaner: any PhraseCleaning
            if mode != .original, let cloud = WritingProvider.selected.cloud { cleaner = CloudPhraseCleaner(selection: try CloudSelection(cloud, writing: true)) }
            else { cleaner = FoundationPhraseCleaner.shared }
            let text = PhraseCleanupService(mode: mode, cleaner: cleaner) { [weak self] snapshot in
                await self?.apply(snapshot, epoch: epoch)
            }
            cleanupService = text
            let failure: @Sendable () async -> Void = { [weak self] in await self?.recognitionFailed(epoch: epoch) }
            let service: any StreamingSpeech
            if provider == .apple { service = AppleSpeechService(text: text, failure: failure) }
            else if provider == .openAI, let selection { service = OpenAIStreamingSpeech(selection: selection, text: text, failure: failure) }
            else { service = PhraseSpeechService(provider: provider, selection: selection, text: text, failure: failure) }
            speechService = service
            let input = sink.begin(); performance.mark("capture")
            async let warm: Void = text.prepare()
            try await service.start(input: input, format: engine.inputNode.outputFormat(forBus: 0))
            await warm
            guard generation == epoch, !Task.isCancelled else { await service.cancel(); return }
            isStarting = false; isRecording = true; readiness.reset(); status = "Listening…"; performance.mark("prepared")
            startActivity(); publish()
            watchdog?.cancel()
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1800))
                guard !Task.isCancelled, let self, generation == epoch else { return }
                cleanupNotice = "This recording reached 30 minutes. Finish to use your text, then start a new dictation."
                stop()
            }
        } catch { if generation == epoch { failStart(error) } }
    }
    private func apply(_ snapshot: DictationTextSnapshot, epoch: UUID) {
        guard generation == epoch else { return }
        transcript = snapshot.display; originalTranscript = snapshot.raw
        provisionalTranscript = snapshot.provisional; finalizedTranscript = snapshot.finalized; refinedTranscript = snapshot.refined
        if let notice = snapshot.notice { cleanupNotice = notice }
        if !snapshot.display.isEmpty { performance.mark("firstVisibleWord") }
        if !snapshot.finalized.isEmpty { performance.mark("firstFinalPhrase") }
        if !snapshot.refined.isEmpty { performance.mark("firstRefinedPhrase") }
        publish()
    }
    private func recognitionFailed(epoch: UUID) {
        guard generation == epoch, isRecording || isStarting else { return }
        cleanupNotice = "Speech was interrupted. Your confirmed words are kept."
        if isStarting { failStart(ProviderFailure(message: "Speech couldn’t start. Check your model download and try again.")) }
        else { stop() }
    }
    func stop() {
        guard isRecording, let service = speechService, let text = cleanupService else { publish(); return }
        isRecording = false; isProcessing = true; isCleaning = CleanupMode.selected != .original
        performance.mark("stop"); sink.end(); watchdog?.cancel()
        beginFinishingTime(); settleMicrophone(); publish()
        let epoch = generation
        watchdog = Task {
            try? await Task.sleep(for: .seconds(18))
            guard !Task.isCancelled else { return }
            await service.cancel()
        }
        finishTask = Task { [weak self] in
            await text.beginStop()
            do { try await service.finish() }
            catch { await text.finishRecognition() }
            guard !Task.isCancelled, let self, generation == epoch else { return }
            watchdog?.cancel(); DictationLatency.mark("transcribed", id: transcriptID)
            let result = await text.finish()
            guard !Task.isCancelled, generation == epoch else { return }
            transcript = result.refined; originalTranscript = result.finalized
            provisionalTranscript = ""; finalizedTranscript = result.finalized; refinedTranscript = result.refined
            cleanupNotice = result.notice ?? cleanupNotice
            if transcript.isEmpty { errorMessage = "We didn’t hear any confirmed words. Please try again." }
            else {
                finalResult = true; lastCompletedText = transcript
                #if DEBUG
                let diagnostic = ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("-benchmark") }
                #else
                let diagnostic = false
                #endif
                if !diagnostic, let id = UUID(uuidString: transcriptID) { TranscriptHistory.shared.record(id: id, text: originalTranscript) }
            }
            isProcessing = false; isCleaning = false; awaitingConfirmation = finalResult && !commitRequested
            DictationLatency.mark("cleaned", id: transcriptID); performance.mark("cleanText"); performance.end(outcome: finalResult ? "completed" : "noSpeech")
            speechService = nil; cleanupService = nil; finishTask = nil
            status = "Ready"; settleMicrophone(); publish(); endFinishingTime()
        }
    }
    private func tick() {
        performance.sample(); audioLevel = isRecording ? sink.level : 0
        if (isRecording || isStarting) && sink.overflowed {
            cleanupNotice = "Speech couldn’t keep up. Your confirmed words are kept."
            if isRecording { stop() } else { cancelDictation() }
        }
        if isRecording && originalTranscript.count > 100_000 { cleanupNotice = "This recording is full. Finish and start a new dictation."; stop() }
        if sessionEnabled && !isRecording && !isStarting && !isProcessing && !readiness.isOpen(now: uptime) && (readiness.deadline != nil || Date() >= sessionExpiry) { releaseMicrophone() }
        let command = KeyboardBridge.read("command.json")
        if let id = command["id"] as? String, id != lastCommand {
            lastCommand = id
            if Date().timeIntervalSince1970 - (command["time"] as? Double ?? 0) < 5 {
                if command["action"] as? String == "start" { let id = command["requestID"] as? String ?? UUID().uuidString; Task { await start(requestID: id) } }
                else if command["requestID"] as? String == transcriptID {
                    switch command["action"] as? String {
                    case "commit": commitRequested = true; awaitingConfirmation = false; stop()
                    case "cancel": cancelDictation()
                    case "clear": transcript = ""; finalResult = false; commitRequested = false; awaitingConfirmation = false
                    default: break
                    }
                }
            }
        }
        publish()
    }
    private func publish() {
        KeyboardBridge.write(["heartbeat": sessionEnabled || isProcessing || isStarting ? Date().timeIntervalSince1970 : 0,
            "recording": isRecording, "processing": isProcessing || isStarting, "text": finalResult ? transcript : "",
            "microphoneActive": engine.isRunning, "ready": isReadyBetweenDictations, "transcriptID": transcriptID,
            "level": audioLevel, "final": finalResult, "commitRequested": commitRequested,
            "awaitingConfirmation": awaitingConfirmation, "cleaning": isCleaning,
            "notice": cleanupNotice ?? "", "error": errorMessage ?? ""], to: "state.json")
        updateActivity()
    }
    func cancelDictation() {
        generation = UUID(); preparationGeneration = UUID()
        finishTask?.cancel(); finishTask = nil; watchdog?.cancel(); watchdog = nil
        sink.end()
        let service = speechService, text = cleanupService, previous = teardown
        teardown = Task { await previous?.value; await service?.cancel(); await text?.cancel() }
        speechService = nil; cleanupService = nil
        isStarting = false; isRecording = false; isProcessing = false; isCleaning = false
        transcript = ""; originalTranscript = ""; provisionalTranscript = ""; finalizedTranscript = ""; refinedTranscript = ""
        finalResult = false; commitRequested = false; awaitingConfirmation = false
        performance.end(outcome: "cancelled"); settleMicrophone(); publish(); endFinishingTime()
    }
    func disableSession() { cancelDictation(); releaseMicrophone(); KeyboardBridge.write([:], to: "pending.json"); publish() }
    func stopReadiness() { if !isRecording && !isStarting { releaseMicrophone(keepPolling: isProcessing); publish() } }
    private func releaseMicrophone(keepPolling: Bool = false) {
        readiness.reset(); sessionEnabled = false; stopEngine(); endActivity()
        if !keepPolling { timer?.invalidate(); timer = nil }
    }
    private func settleMicrophone() {
        sink.end(); audioLevel = 0
        if readinessMinutes != 0, sessionEnabled, engine.isRunning, errorMessage == nil { readiness.beginIdle(now: uptime, minutes: readinessMinutes) }
        else { releaseMicrophone(keepPolling: isProcessing) }
    }
    private func failStart(_ error: Error) {
        #if DEBUG
        if SpeechProvider.selected == .apple { let e = error as NSError; print("APPLE_START_ERROR: \(e.domain) code=\(e.code) description=\(e.localizedDescription) appState=\(UIApplication.shared.applicationState.rawValue) otherAudio=\(AVAudioSession.sharedInstance().isOtherAudioPlaying) route=\(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType.rawValue))") }
        #endif
        let code = (error as NSError).code
        errorMessage = code == 561017449 ? "The microphone is busy. Close any call or voice app and try again. If it stays busy, restart your iPhone." : (error as? ProviderFailure)?.message ?? "Speech isn’t ready. Please try again."
        cancelDictation(); releaseMicrophone(); publish()
    }
    func editCompleted(_ text: String) {
        lastCompletedText = text
        if finalResult && !commitRequested { transcript = text; refinedTranscript = text; publish() }
    }
    func cancelFromApp() { KeyboardBridge.write([:], to: "pending.json"); cancelDictation() }
    func finishFromApp() async {
        guard canFinishInApp, !isProcessing else { return }
        let id = transcriptID
        if var ticket = DictationTicket(KeyboardBridge.read("pending.json")), ticket.id == id { ticket.committed = true; KeyboardBridge.write(ticket.dictionary, to: "pending.json") }
        DictationLatency.begin(id: id); commitRequested = true; awaitingConfirmation = false; stop(); publish()
        while isProcessing && transcriptID == id { try? await Task.sleep(for: .milliseconds(50)); if Task.isCancelled { return } }
        guard transcriptID == id, finalResult, KeyboardBridge.read("pending.json")["id"] as? String == id else { return }
        #if DEBUG
        await DevKeyboardReturn.shared.returnAfterFinish(requestID: id)
        #endif
    }
    private func permissions() async -> Bool {
        if SpeechProvider.selected == .apple && SFSpeechRecognizer.authorizationStatus() != .authorized {
            let auth = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
            guard auth == .authorized else { errorMessage = "Allow Speech Recognition for TapType in Settings."; return false }
        }
        if AVAudioApplication.shared.recordPermission != .granted {
            guard await AVAudioApplication.requestRecordPermission() else { errorMessage = "Allow Microphone for TapType in Settings."; return false }
        }
        return true
    }
    private func beginFinishingTime() {
        if finishingTime == .invalid { finishingTime = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") { [weak self] in self?.cancelDictation() } }
    }
    private func endFinishingTime() {
        if finishingTime != .invalid { let token = finishingTime; finishingTime = .invalid; UIApplication.shared.endBackgroundTask(token) }
    }
    func openFromKeyboard(_ url: URL) async {
        let arrived = Date()
        guard url.scheme == "taptype", url.host == "dictate",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let document = components.queryItems?.first(where: { $0.name == "document" })?.value,
              UUID(uuidString: id) != nil, UUID(uuidString: document) != nil else { return }
        guard let handoffBegan = HostReturnIdentity.handoffStarted(KeyboardBridge.read("preparing.json"),
            requestID: id, document: document, arrived: arrived) else { return }
        handoffPending = true
        defer { handoffPending = false }
        #if DEBUG
        DevKeyboardReturn.shared.captureDestination(requestID: id, document: document, since: handoffBegan)
        #endif
        // Foreground activation may already be requesting permission / preparing audio.
        while isStarting { try? await Task.sleep(for: .milliseconds(100)) }
        if isRecording || isProcessing { cancelDictation() }
        await enableSession()
        guard sessionEnabled else { return }
        let ticket = DictationTicket(document: document, id: id)
        KeyboardBridge.write(ticket.dictionary, to: "pending.json")
        await start(requestID: id)
        #if DEBUG
        await DevKeyboardReturn.shared.returnAfterStart(since: handoffBegan, requestID: id) { [weak self] in
            self?.isRecording == true && self?.transcriptID == id
        }
        #endif
    }

    private var activityStaleDate: Date? {
        if let deadline = readiness.deadline { return deadline.isFinite ? Date().addingTimeInterval(max(0, deadline - uptime)) : nil }
        return sessionExpiry
    }
    private func startActivity() {
        guard sessionEnabled, engine.isRunning, activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            activityNotice = "Allow Live Activities in iPhone Settings → TapType to show its logo."
            return
        }
        guard UIApplication.shared.applicationState != .background else {
            activityNotice = "The TapType logo can appear next time the app opens."
            return
        }
        for old in Activity<VoiceActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        activityPhase = isRecording ? "Listening" : "Ready"
        do {
            activity = try Activity.request(
            attributes: VoiceActivityAttributes(name: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "TapType"),
            content: ActivityContent(state: .init(phase: activityPhase), staleDate: activityStaleDate), pushType: nil)
            activityNotice = nil
        } catch {
            activityNotice = "The TapType logo couldn’t appear. Dictation still works."
            #if DEBUG
            print("ACTIVITY_START_ERROR: \(error)")
            #endif
        }
    }
    func refreshActivityPresentation() {
        if sessionEnabled { startActivity() }
    }

    private func updateActivity() {
        guard let activity else { return }
        let phase = isRecording ? "Listening" : isProcessing ? "Finishing" : "Ready"
        guard phase != activityPhase else { return }
        activityPhase = phase
        let content = ActivityContent(state: VoiceActivityAttributes.ContentState(phase: phase), staleDate: activityStaleDate)
        let previous = activityUpdate
        activityUpdate = Task { await previous?.value; await activity.update(content) }
    }
    private func endActivity() {
        if let activity {
            let previous = activityUpdate
            activityUpdate = Task {
                await previous?.value
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        activity = nil; activityPhase = ""
    }
    private func startEngine() throws {
        guard !engine.isRunning else { return }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try audio.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try audio.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            throw NSError(domain: "TapType", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        if tapInstalled { input.removeTap(onBus: 0) }
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }
    private func stopEngine() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    #if DEBUG
    func testAppleStreaming() async {
        setbuf(stdout, nil)
        let keys = ["speechProvider", "writingProvider", "cleanupMode"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let cloud = ProcessInfo.processInfo.arguments.contains("--cloud-benchmark")
        let long = ProcessInfo.processInfo.arguments.contains("--long-recording")
        UserDefaults.standard.set(cloud ? "openAI" : "apple", forKey: keys[0])
        UserDefaults.standard.set(ProcessInfo.processInfo.arguments.contains("--cloud-writing") ? "openAI" : "apple", forKey: keys[1])
        UserDefaults.standard.set("cleanup", forKey: keys[2])
        defer { disableSession(); for (key, value) in zip(keys, saved) { if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } } }
        do {
            if ProcessInfo.processInfo.arguments.contains("--profile-wait") { try await Task.sleep(for: .seconds(10)) }
            for trial in 1...(long || cloud ? 1 : 3) {
                await enableSession(); await start()
                guard isRecording else { print("APPLE_BENCHMARK_START_FAILED: \(errorMessage ?? "unknown")"); return }
                let file = try AVAudioFile(forReading: Bundle.main.url(forResource: long ? "LongSpeechFixture" : "SpeechFixture", withExtension: "aiff")!)
                let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: source)
                let format = engine.inputNode.outputFormat(forBus: 0)
                let converter = AVAudioConverter(from: source.format, to: format)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate)) + 1024)!
                var sent = false, failure: NSError?
                converter.convert(to: buffer, error: &failure) { _, status in
                    if sent { status.pointee = .endOfStream; return nil }; sent = true; status.pointee = .haveData; return source
                }
                if let failure { throw failure }
                let size = Int(format.sampleRate / 20)
                for start in stride(from: 0, to: Int(buffer.frameLength), by: size) {
                    let count = min(size, Int(buffer.frameLength) - start)
                    let packet = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                    packet.frameLength = AVAudioFrameCount(count)
                    for channel in 0..<Int(format.channelCount) { packet.floatChannelData![channel].update(from: buffer.floatChannelData![channel] + start, count: count) }
                    sink.append(packet, fixture: true); try await Task.sleep(for: .milliseconds(50))
                }
                DictationLatency.begin(id: transcriptID); commitRequested = true; stop()
                while isProcessing { try await Task.sleep(for: .milliseconds(50)) }
                print("APPLE_BENCHMARK: trial=\(trial) matched=\(originalTranscript.lowercased().contains("purple bicycle")) words=\(originalTranscript.split(whereSeparator: { $0.isWhitespace }).count) notice=\(cleanupNotice ?? "none") finalized=\(finalResult) metrics=\(performance.latest)")
            }
            print("APPLE_BENCHMARK_COMPLETE")
        } catch { print("APPLE_BENCHMARK_FAILED: \(error.localizedDescription)") }
    }
    #endif

}
