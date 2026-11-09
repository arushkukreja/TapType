import SwiftUI

struct ContentView: View {
    @StateObject private var speech = SpeechRecognizer()
    @ObservedObject private var history = TranscriptHistory.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHandoff = true
    @State private var handoffInProgress = false
    @State private var activationID = UUID()
    @State private var handoffHelp = false
    @State private var showHistory = false
    @State private var showCloud = false
    @State private var showCosts = false
    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "TapType" }

    private var homeScreen: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 4) {
                        Text("\(history.totalWords.formatted()) words").font(.largeTitle.bold()).monospacedDigit()
                        Text("\(history.entries.count.formatted()) dictations").font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                Section {
                    Picker("Keep ready", selection: $speech.readinessMinutes) {
                        ForEach(ReadySessionOptions.minutes, id: \.self) { minutes in
                            Text(ReadySessionOptions.title(minutes)).tag(minutes)
                        }
                    }.pickerStyle(.menu).disabled(speech.isStarting)
                } footer: {
                    Text(speech.readinessMinutes == 0 ? "Mic off after each dictation." : "Mic on while ready. Idle audio discarded.")
                    if let notice = speech.activityNotice { Text(notice) }
                }

                ModelSettingsView(cloud: $showCloud, busy: speech.isStarting || speech.isRecording || speech.isProcessing || speech.awaitingConfirmation)

                Section {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 14) {
                            setupStep("1", "Add TapType", "Settings → General → Keyboard → Keyboards → Add New Keyboard.")
                            setupStep("2", "Allow Full Access", "Open TapType’s keyboard settings and turn it on.")
                            setupStep("3", "Start talking", "In any text field, hold the globe, choose TapType, then tap its button. Finish with ✓.")
                            Button("Open Settings", systemImage: "arrow.up.right.square") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }.padding(.vertical, 8)
                    } label: { Text("Set up your keyboard") }

                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 16) {
                            faq("When is the microphone on?", "Only after you tap TapType. Stay ready keeps input active for your selected duration after ✓ or ×. No idle audio is saved or transcribed. Choose Off under Keep ready to release the microphone between dictations.")
                            faq("Do my words leave my iPhone?", "Apple Speech and Apple cleanup run on this iPhone. Downloaded Whisper models stay local too. If you choose a cloud model, completed phrases are sent while you speak and provider charges apply. Idle audio is discarded.")
                            faq("Why does TapType open?", "The first tap starts a microphone session. Repeat taps stay in your keyboard while the session is ready. After the session expires, an interruption, or force-quitting TapType, it may need to open again.")
                            faq("Are transcripts saved?", "Completed originals are saved only on this iPhone, with local dates and times. History stays on this device. Earlier dictations cannot be recovered.")
                            faq("Why Full Access?", "It lets the keyboard exchange dictation commands and text with this app.")
                            faq("How does cleanup work?", "Speech and writing models are separate choices. Cleanup removes fillers; Rewrite improves phrasing. If cleanup fails, your original words are kept.")
                        }.padding(.vertical, 8)
                    } label: { Text("Common questions") }
                }

                

                Section {
                    Button { showCosts = true } label: {
                        HStack {
                            Text("Cloud usage")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }.contentShape(Rectangle())
                    }
                    Button { showHistory = true } label: {
                        HStack {
                            Text("Original transcripts")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                        }.contentShape(Rectangle())
                    }
                    if let notice = history.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }

            }
            .contentMargins(.top, 8, for: .scrollContent)
            .navigationTitle(appName)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showHistory) { TranscriptHistoryView() }
            .navigationDestination(isPresented: $showCosts) { CloudUsageView() }
            .tint(.primary)
        }
    }

    private func setupStep(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())
            faq(title, detail)
        }
    }

    private func faq(_ question: String, _ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question).font(.subheadline.weight(.medium))
            Text(answer).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        ZStack {
            homeScreen.opacity(showHandoff ? 0 : 1).accessibilityHidden(showHandoff)
            if showHandoff {
                Color.black.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "waveform")
                        .font(.system(size: 48, weight: .semibold))
                        .accessibilityLabel("\(appName), getting ready")
                    if handoffHelp {
                        Text(speech.errorMessage == nil ? "Swipe along the bottom edge to return to your app." : "We couldn’t start dictation. Please try again.")
                            .font(.subheadline).multilineTextAlignment(.center)
                        Button("Open \(appName)") {
                            TransitionShield.shared.allowExplicitHome()
                            activationID = UUID(); handoffInProgress = false
                            handoffHelp = false; showHandoff = false
                        }.buttonStyle(.bordered)
                    }
                }.foregroundStyle(.white).padding(32)
            }
        }
        .background(TransitionShieldAnchor(covered: showHandoff && !handoffHelp, isFallback: showHandoff && handoffHelp))
        .preferredColorScheme(.dark)
        // A Form section can recreate its presentation host during the first sheet animation.
        .sheet(isPresented: $showCloud) { CloudSettingsView() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            let id = UUID(); activationID = id
            if phase != .active { showHandoff = true }
            if phase == .background && !TransitionShield.shared.handoffPending { handoffInProgress = false; handoffHelp = false }
            if phase == .active {
                handoffInProgress = TransitionShield.shared.handoffPending
                speech.refreshActivityPresentation()
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard activationID == id, scenePhase == .active else { return }
                    if !handoffInProgress && !TransitionShield.shared.handoffPending && !KeyboardBridge.hasRecentHandoff { showHandoff = false }
                }
            }
        }
        .onOpenURL { url in
            if url.scheme == "taptype", url.host == "home" {
                TransitionShield.shared.allowExplicitHome()
                activationID = UUID(); handoffInProgress = false
                handoffHelp = false; showHandoff = false
                showHistory = false; showCloud = false; showCosts = false
            } else if url.scheme == "taptype", url.host == "dictate" {
                TransitionShield.shared.beginHandoff()
                activationID = UUID(); handoffHelp = false
                showHandoff = true
                handoffInProgress = true
                KeyboardBridge.write([:], to: "handoff.json")
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--return-test") {
                    let began = Date()
                    Task {
                        let requestID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value
                        let document = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "document" })?.value
                        if let requestID, let document {
                            DevKeyboardReturn.shared.captureDestination(requestID: requestID, document: document, since: began)
                        }
                        await DevKeyboardReturn.shared.returnAfterStart(since: began, requestID: requestID) { true }
                        await finishHandoffScreen()
                    }
                    return
                }
                #endif
                Task {
                    await speech.openFromKeyboard(url)
                    await finishHandoffScreen()
                }
            }
        }
        .alert(appName, isPresented: Binding(get: { speech.errorMessage != nil }, set: { if !$0 { speech.errorMessage = nil } })) {
            Button("OK") { speech.errorMessage = nil }
        } message: { Text(speech.errorMessage ?? "") }
        .task {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--text-preview") { speech.editCompleted("Please send five copies to Maya."); return }
            if args.contains("--audio-probe") { await PipelineChecks.audioProbe(); return }
            if args.contains("--apple-benchmark") || args.contains("--cloud-benchmark") { await speech.testAppleStreaming(); return }
            if args.contains("--apple-assets") {
                AppleSpeechAssets.shared.download()
                while AppleSpeechAssets.shared.downloading { try? await Task.sleep(for: .milliseconds(200)) }
                print("APPLE_ASSETS_INSTALLED: \(AppleSpeechAssets.shared.installed)")
            }
            #endif
        }
    }

    private func finishHandoffScreen() async {
        // Completion of openURL is not completion of iOS's transition. Never
        // reveal the home screen on a timer; only a later ordinary activation
        // or an explicit user action may reveal it.
        try? await Task.sleep(for: .seconds(2))
        if scenePhase != .background && TransitionShield.shared.handoffPending { handoffHelp = true }
    }
}
