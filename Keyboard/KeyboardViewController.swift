import UIKit
import SwiftUI
import AVFoundation
import CoreHaptics
#if DEBUG
import ObjectiveC.runtime
#endif

#if DEBUG
// iOS 27 no longer puts the host bundle on the keyboard-changed callback. The
// arbiter's current client state still pairs a process ID with its bundle ID;
// match that pair to the host PID UIKit exposes on this keyboard controller.
@MainActor
private final class KeyboardReturnTargetResolver {
    static let shared = KeyboardReturnTargetResolver()

    struct Snapshot {
        var hostPID = 0
        var statePID = 0
        var stateBundle = ""
        var mappedCount = 0
    }

    private var returnTargets = HostReturnCache()
    private(set) var snapshot = Snapshot()
    private static var enabledReplacement: IMP?

    func resolve(for controller: UIInputViewController, timeout: TimeInterval = 0.3) async -> String? {
        Self.enableArbiterIfNeeded()
        guard let client = Self.arbiterClient() else { return nil }
        Self.checkConnection(client)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        repeat {
            if let bundle = currentHost(client: client, controller: controller) { return bundle }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                // Shortcut: iOS exposes only a PID here, so reuse is limited to eight seconds.
                return returnTargets.bundle(for: snapshot.hostPID, now: ProcessInfo.processInfo.systemUptime)
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while !Task.isCancelled
        return nil
    }

    private func currentHost(client: NSObject, controller: UIInputViewController) -> String? {
        let hostPID = Self.integerValue(controller, selector: "_hostProcessIdentifier") ?? 0
        let state = Self.objectValue(client, selector: "currentClientState") as? NSObject
        let statePID = state.flatMap { Self.integerValue($0, selector: "processIdentifier") } ?? 0
        let stateBundle = state.flatMap { Self.objectValue($0, selector: "sourceBundleIdentifier") as? String } ?? ""
        if statePID > 0, Self.validBundle(stateBundle) {
            returnTargets.observe(pid: statePID, bundle: stateBundle, now: ProcessInfo.processInfo.systemUptime)
        }
        snapshot = Snapshot(hostPID: hostPID, statePID: statePID,
                            stateBundle: stateBundle, mappedCount: returnTargets.count)
        return hostPID > 0 && statePID == hostPID && Self.validBundle(stateBundle) ? stateBundle : nil
    }

    private static func validBundle(_ value: String) -> Bool {
        !value.isEmpty && value.count < 256 && value.contains(".") &&
        !value.contains(where: { $0.isWhitespace })
    }

    private static func arbiterClient() -> NSObject? {
        guard let type = NSClassFromString("_UIKeyboardArbiterClient"),
              let method = class_getClassMethod(type, NSSelectorFromString("automaticSharedArbiterClient")),
              method_getNumberOfArguments(method) == 2,
              Self.returnType(method).hasPrefix("@") else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return getter(type, NSSelectorFromString("automaticSharedArbiterClient"))?.takeUnretainedValue() as? NSObject
    }

    private static func checkConnection(_ client: NSObject) {
        let selector = NSSelectorFromString("checkConnection")
        guard let method = class_getInstanceMethod(type(of: client), selector),
              method_getNumberOfArguments(method) == 2,
              returnType(method).hasPrefix("v") else { return }
        typealias Call = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method_getImplementation(method), to: Call.self)(client, selector)
    }

    private static func objectValue(_ object: NSObject, selector name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2,
              returnType(method).hasPrefix("@") else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector)?.takeUnretainedValue()
    }

    private static func integerValue(_ object: NSObject, selector name: String) -> Int? {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let implementation = method_getImplementation(method)
        switch returnType(method).first {
        case "i":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
            return Int(unsafeBitCast(implementation, to: Getter.self)(object, selector))
        case "I":
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt32
            return Int(unsafeBitCast(implementation, to: Getter.self)(object, selector))
        case "q", "l":
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int
            return unsafeBitCast(implementation, to: Getter.self)(object, selector)
        case "Q", "L":
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
            return Int(unsafeBitCast(implementation, to: Getter.self)(object, selector))
        default: return nil
        }
    }

    private static func enableArbiterIfNeeded() {
        guard enabledReplacement == nil,
              let type = NSClassFromString("_UIKeyboardArbiterClient"),
              let method = class_getClassMethod(type, NSSelectorFromString("enabled")),
              method_getNumberOfArguments(method) == 2,
              ["B", "c"].contains(String(returnType(method).first ?? "?")) else { return }
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        let replacement = imp_implementationWithBlock(block)
        method_setImplementation(method, replacement)
        enabledReplacement = replacement
    }

    private static func returnType(_ method: Method) -> String {
        let raw = method_copyReturnType(method)
        defer { free(raw) }
        return String(cString: raw).drop(while: { "rnNoORV".contains($0) }).description
    }
}
#endif

// A short, mixing playback session makes explicit dictation cues audible in
// Silent Mode without taking microphone ownership from the companion app.
private final class KeyboardSounds: NSObject, AVAudioPlayerDelegate {
    // Insertion can recreate the keyboard controller before a cue finishes.
    static let shared = KeyboardSounds()
    private var player: AVAudioPlayer?
    private var sessionActive = false
    func play(_ name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return }
        do {
            player?.stop()
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try audio.setActive(true)
            sessionActive = true
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            player = next
            let accepted = next.play()
            #if DEBUG
            NSLog("TapType keyboard cue: %@ accepted=%d volume=%.2f", name, accepted, Double(audio.outputVolume))
            KeyboardBridge.write(["cue": name, "accepted": accepted, "volume": audio.outputVolume,
                                  "route": audio.currentRoute.outputs.map { $0.portType.rawValue },
                                  "time": Date().timeIntervalSince1970], to: "cue-status.json")
            #endif
            if !accepted { stop() }
        } catch {
            #if DEBUG
            NSLog("TapType keyboard cue failed: %@", (error as NSError).domain)
            #endif
            stop()
        }
    }
    func stop() {
        player?.stop(); player = nil
        guard sessionActive else { return }
        sessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        #if DEBUG
        var report = KeyboardBridge.read("cue-status.json")
        report["playedToEnd"] = flag
        KeyboardBridge.write(report, to: "cue-status.json")
        #endif
        stop()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        stop()
    }
}

// Keep haptic playback in the visible keyboard process. No microphone or audio
// session category is activated by this haptics-only engine.
private final class KeyboardHaptics {
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    func prepare() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if engine == nil {
                let newEngine = try CHHapticEngine()
                newEngine.playsHapticsOnly = true
                newEngine.isAutoShutdownEnabled = true
                engine = newEngine
            }
            try engine?.start()
        } catch { report("prepare", error: error); engine = nil }
    }
    func play(_ event: String) -> Bool {
        prepare()
        guard let engine else { return false }
        do {
            let times: [TimeInterval] = event == "finish" ? [0, 0.09] : [0]
            let pattern = try CHHapticPattern(events: times.map { time in
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: event == "cancel" ? 0.6 : 0.8),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.65)
                ], relativeTime: time)
            }, parameters: [])
            player = try engine.makePlayer(with: pattern)
            try player?.start(atTime: CHHapticTimeImmediate)
            report(event, error: nil)
            return true
        } catch { report(event, error: error); self.engine = nil; return false }
    }
    private func report(_ event: String, error: Error?) {
        #if DEBUG
        let failure = error as NSError?
        let result: [String: Any] = ["event": event, "accepted": error == nil,
            "domain": failure?.domain ?? "", "code": failure?.code ?? 0]
        KeyboardBridge.write(result, to: "haptic-status.json")
        NSLog("TapType keyboard haptic engine: %@ accepted=%d code=%ld", event, error == nil, failure?.code ?? 0)
        #endif
    }
}

private final class KeyboardKey: UIButton {
    private var restingColor: UIColor?
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if isHighlighted {
                restingColor = backgroundColor
                backgroundColor = traitCollection.userInterfaceStyle == .dark ? UIColor(white: 0.56, alpha: 1) : UIColor(white: 0.76, alpha: 1)
            } else { backgroundColor = restingColor }
        }
    }
}

private enum KeyboardMetrics {
    static let height: CGFloat = 260
    static let contentHeight: CGFloat = 248
}

private final class FixedHeightKeyboardView: UIInputView {
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: KeyboardMetrics.height)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: KeyboardMetrics.height)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority) -> CGSize {
        CGSize(width: targetSize.width, height: KeyboardMetrics.height)
    }
}

private struct OpenHomeApp: View {
    @Environment(\.openURL) private var openURL
    @State private var opening = false
    let url: URL
    let name: String
    let failed: () -> Void
    var body: some View {
        Button {
            guard !opening else { return }
            opening = true
            openURL(url) { accepted in
                if !accepted { failed() }
                opening = false
            }
        } label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Open \(name) settings")
        .buttonStyle(.plain)
    }
}

private struct OpenVoiceApp: View {
    @Environment(\.openURL) private var openURL
    @State private var opening = false
    let url: URL
    let name: String
    let prepare: () -> Bool
    let captureReturnTarget: @MainActor () async -> Void
    let canOpen: () -> Bool
    let failed: () -> Void
    var body: some View {
        Button {
            guard !opening, prepare() else { return }
            opening = true
            // Commit the listening layout before iOS captures the host for the
            // app switch. This task belongs to the tap, not the disappearing view.
            let launch = openURL
            Task { @MainActor in
                await captureReturnTarget()
                try? await Task.sleep(for: .milliseconds(100))
                guard canOpen() else { failed(); opening = false; return }
                launch(url) { accepted in
                    if !accepted { failed() }
                    opening = false
                }
            }
        } label: {
            // UIKit draws the same button in both states; this layer only opens
            // the companion through SwiftUI's extension-compatible URL action.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(name), start dictation")
        .buttonStyle(.plain)
    }
}

private final class VoiceWaveform: UIView {
    var levels: [CGFloat] = Array(repeating: 0, count: 11)
    func push(_ level: CGFloat) { levels.removeFirst(); levels.append(level); setNeedsDisplay() }
    override func draw(_ rect: CGRect) {
        UIColor.label.setFill()
        let gap: CGFloat = 13, width: CGFloat = 5
        let origin = (bounds.width - CGFloat(levels.count - 1) * gap - width) / 2
        for (index, value) in levels.enumerated() {
            let height = 5 + value * 43
            UIBezierPath(roundedRect: CGRect(x: origin + CGFloat(index) * gap,
                y: (bounds.height - height) / 2, width: width, height: height), cornerRadius: 2.5).fill()
        }
    }
}

final class KeyboardViewController: UIInputViewController {
    private let root = UIStackView()
    private let toolbar = UIStackView()
    private let left = UIButton(type: .system)
    private let status = UILabel()
    private let settingsSlot = UIView()
    private let settings = UIButton(type: .system)
    private let actionSlot = UIView()
    private var actionWidth: NSLayoutConstraint!
    private let action = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let bodyPanel = UIView()
    private let transitionCover = UIView()
    private var lastGeometry = ""
    private var transitionID: String?
    private var transitionCreated = 0.0
    private var hostInactive = false
    private var hostResumedAt: Double?
    private var sawHostInactive = false
    private let keys = UIStackView()
    private let keyPreview = UILabel()
    private var previewDismissal: DispatchWorkItem?
    private weak var previewKey: UIButton?
    private let listening = UIView()
    private let waveform = VoiceWaveform()
    private let processingLogo = UIImageView(image: UIImage(systemName: "waveform"))
    private let listeningLabel = UILabel()
    private var linkHost: UIHostingController<OpenVoiceApp>?
    private var linkDocument = ""
    private var timer: Timer?
    private var state: [String: Any] = [:]
    private var ticket: DictationTicket?
    private var visible = false
    private var upper = true
    private var numbers = false
    private var symbols = false
    private var localMessage: String?
    private let sounds = KeyboardSounds.shared
    private var startHaptic: UIImpactFeedbackGenerator?
    private var finishHaptic: UINotificationFeedbackGenerator?
    private var cancelHaptic: UIImpactFeedbackGenerator?
    private let directHaptics = KeyboardHaptics()
    #if DEBUG
    private let returnTargetResolver = KeyboardReturnTargetResolver.shared
    #endif
    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "TapType" }
    private var lastLayout = ""
    private var dark: Bool {
        // Match the window that draws iOS's keyboard backdrop. During host switches,
        // the proxy can still report .dark while that window is already light.
        switch viewIfLoaded?.window?.traitCollection.userInterfaceStyle {
        case .dark: return true
        case .light: return false
        default: return textDocumentProxy.keyboardAppearance == .dark
        }
    }
    private var document: String? {
        // During host teardown UIKit can return nil for its nominally nonnull
        // UUID. Swift's unconditional bridge traps before an optional check can
        // run. Read the same public Objective-C property as a nullable object.
        guard let proxy = textDocumentProxy as? NSObject,
              let identifier = proxy.value(forKey: "documentIdentifier") as? UUID else { return nil }
        return identifier.uuidString
    }
    private var alive: Bool { Date().timeIntervalSince1970 - (state["heartbeat"] as? Double ?? 0) < 3 }
    private var matches: Bool { ticket?.id == state["transcriptID"] as? String }
    private var recording: Bool { alive && matches && state["recording"] as? Bool == true }
    private var processing: Bool { alive && matches && state["processing"] as? Bool == true }

    override func loadView() {
        let keyboard = FixedHeightKeyboardView(frame: CGRect(x: 0, y: 0, width: 0, height: KeyboardMetrics.height), inputViewStyle: .keyboard)
        keyboard.allowsSelfSizing = true
        inputView = keyboard
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutKeyboardContents()
        #if DEBUG
        let geometry = "\(view.bounds.height)/\(root.frame.minY)/\(root.bounds.height)"
        if geometry != lastGeometry {
            lastGeometry = geometry
            traceTransition("layout")
        }
        #endif
    }

    private func layoutKeyboardContents() {
        // UIKit can replace the remote view's bounds after its height constraint
        // was solved. Position using the final bounds, not the earlier proposal.
        let contentHeight = min(KeyboardMetrics.contentHeight, max(0, view.bounds.height - 12))
        let frame = CGRect(x: 6, y: max(5, view.bounds.height - contentHeight - 7),
                           width: max(0, view.bounds.width - 12), height: contentHeight)
        root.frame = frame
        transitionCover.frame = frame
        root.layoutIfNeeded()
        transitionCover.layoutIfNeeded()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        hasDictationKey = true
        for name in [NSNotification.Name.NSExtensionHostWillResignActive,
                     .NSExtensionHostDidEnterBackground, .NSExtensionHostDidBecomeActive] {
            NotificationCenter.default.addObserver(self, selector: #selector(hostActivityChanged(_:)), name: name, object: nil)
        }
        traceTransition("loaded")
        // iOS supplies the rounded keyboard backdrop and bottom system controls.
        // An opaque extension background creates a second, square-edged panel over it.
        view.backgroundColor = .clear
        view.isOpaque = false
        // Match the system backdrop's top inset with breathing room below the
        // toolbar, so the TapType controls sit midway between top and keys.
        root.axis = .vertical; root.spacing = 20
        root.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        view.addSubview(root)
        view.heightAnchor.constraint(equalToConstant: KeyboardMetrics.height).isActive = true
        toolbar.axis = .horizontal; toolbar.alignment = .center; toolbar.spacing = 10
        toolbar.heightAnchor.constraint(equalToConstant: 44).isActive = true
        left.widthAnchor.constraint(equalToConstant: 44).isActive = true
        left.heightAnchor.constraint(equalToConstant: 44).isActive = true
        left.addTarget(self, action: #selector(leftTapped), for: .touchUpInside)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.numberOfLines = 2
        settingsSlot.widthAnchor.constraint(equalToConstant: 44).isActive = true
        settingsSlot.heightAnchor.constraint(equalToConstant: 44).isActive = true
        settings.translatesAutoresizingMaskIntoConstraints = false
        settings.setImage(UIImage(systemName: "gearshape",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)), for: .normal)
        settings.tintColor = .label
        settings.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        settings.layer.cornerRadius = 22
        settings.isUserInteractionEnabled = false
        settings.isAccessibilityElement = false
        settingsSlot.addSubview(settings)
        NSLayoutConstraint.activate([
            settings.leadingAnchor.constraint(equalTo: settingsSlot.leadingAnchor),
            settings.trailingAnchor.constraint(equalTo: settingsSlot.trailingAnchor),
            settings.topAnchor.constraint(equalTo: settingsSlot.topAnchor),
            settings.bottomAnchor.constraint(equalTo: settingsSlot.bottomAnchor)
        ])
        let home = UIHostingController(rootView: OpenHomeApp(url: URL(string: "taptype://home")!, name: appName,
            failed: { [weak self] in
                self?.localMessage = "Couldn’t open TapType. Please try again."
                self?.refresh()
            }))
        home.safeAreaRegions = []
        addChild(home); settingsSlot.addSubview(home.view)
        home.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            home.view.leadingAnchor.constraint(equalTo: settingsSlot.leadingAnchor),
            home.view.trailingAnchor.constraint(equalTo: settingsSlot.trailingAnchor),
            home.view.topAnchor.constraint(equalTo: settingsSlot.topAnchor),
            home.view.bottomAnchor.constraint(equalTo: settingsSlot.bottomAnchor)
        ])
        home.view.backgroundColor = .clear; home.didMove(toParent: self)
        actionWidth = actionSlot.widthAnchor.constraint(equalToConstant: 124)
        actionWidth.isActive = true
        actionSlot.heightAnchor.constraint(equalToConstant: 44).isActive = true
        action.translatesAutoresizingMaskIntoConstraints = false
        action.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        actionSlot.addSubview(action)
        NSLayoutConstraint.activate([
            action.leadingAnchor.constraint(equalTo: actionSlot.leadingAnchor),
            action.trailingAnchor.constraint(equalTo: actionSlot.trailingAnchor),
            action.topAnchor.constraint(equalTo: actionSlot.topAnchor),
            action.bottomAnchor.constraint(equalTo: actionSlot.bottomAnchor)
        ])
        spinner.translatesAutoresizingMaskIntoConstraints = false; spinner.isUserInteractionEnabled = false
        actionSlot.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: actionSlot.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: actionSlot.centerYAnchor)
        ])
        // Bind feedback to this extension's visible controls instead of relying on
        // UIKit to infer a foreground scene from an unattached generator.
        if #available(iOS 17.5, *) {
            startHaptic = UIImpactFeedbackGenerator(style: .medium, view: actionSlot)
            finishHaptic = UINotificationFeedbackGenerator(view: actionSlot)
            cancelHaptic = UIImpactFeedbackGenerator(style: .light, view: left)
        } else {
            startHaptic = UIImpactFeedbackGenerator(style: .medium)
            finishHaptic = UINotificationFeedbackGenerator()
            cancelHaptic = UIImpactFeedbackGenerator(style: .light)
        }
        toolbar.addArrangedSubview(left); toolbar.addArrangedSubview(settingsSlot)
        toolbar.addArrangedSubview(status); toolbar.addArrangedSubview(actionSlot)
        keys.axis = .vertical; keys.spacing = 8; keys.distribution = .fillEqually
        // Both states occupy exactly the same area. Hiding an arranged subview
        // used to make UIStackView reflow while the host was being restored.
        root.addArrangedSubview(toolbar)
        root.addArrangedSubview(bodyPanel)
        for panel in [keys, listening] {
            panel.translatesAutoresizingMaskIntoConstraints = false
            bodyPanel.addSubview(panel)
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: bodyPanel.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: bodyPanel.trailingAnchor),
                panel.topAnchor.constraint(equalTo: bodyPanel.topAnchor),
                panel.bottomAnchor.constraint(equalTo: bodyPanel.bottomAnchor)
            ])
        }
        waveform.backgroundColor = .clear
        waveform.translatesAutoresizingMaskIntoConstraints = false
        listeningLabel.translatesAutoresizingMaskIntoConstraints = false
        listeningLabel.font = .systemFont(ofSize: 20, weight: .regular)
        listeningLabel.numberOfLines = 3; listeningLabel.textAlignment = .center
        listening.addSubview(waveform); listening.addSubview(listeningLabel)
        processingLogo.translatesAutoresizingMaskIntoConstraints = false
        processingLogo.contentMode = .scaleAspectFit
        processingLogo.tintColor = .label
        processingLogo.isHidden = true
        processingLogo.accessibilityLabel = "TapType, finishing your text"
        listening.addSubview(processingLogo)
        NSLayoutConstraint.activate([
            processingLogo.centerXAnchor.constraint(equalTo: listening.centerXAnchor),
            processingLogo.centerYAnchor.constraint(equalTo: listening.centerYAnchor),
            processingLogo.widthAnchor.constraint(equalToConstant: 56),
            processingLogo.heightAnchor.constraint(equalToConstant: 56),
            waveform.centerXAnchor.constraint(equalTo: listening.centerXAnchor),
            waveform.topAnchor.constraint(equalTo: listening.topAnchor, constant: 30),
            waveform.widthAnchor.constraint(equalToConstant: 180), waveform.heightAnchor.constraint(equalToConstant: 52),
            listeningLabel.topAnchor.constraint(equalTo: waveform.bottomAnchor, constant: 16),
            listeningLabel.leadingAnchor.constraint(equalTo: listening.leadingAnchor, constant: 20),
            listeningLabel.trailingAnchor.constraint(equalTo: listening.trailingAnchor, constant: -20)
        ])
        rebuildKeys()
        transitionCover.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        transitionCover.isHidden = true
        transitionCover.isAccessibilityElement = true
        transitionCover.accessibilityLabel = "TapType, getting ready"
        transitionCover.backgroundColor = .clear
        transitionCover.isOpaque = false
        let transitionLogo = UIImageView(image: UIImage(systemName: "waveform",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .medium)))
        transitionLogo.tintColor = .label
        transitionLogo.contentMode = .scaleAspectFit
        transitionLogo.translatesAutoresizingMaskIntoConstraints = false
        transitionCover.addSubview(transitionLogo)
        view.addSubview(transitionCover)
        NSLayoutConstraint.activate([
            transitionLogo.centerXAnchor.constraint(equalTo: transitionCover.centerXAnchor),
            transitionLogo.centerYAnchor.constraint(equalTo: transitionCover.centerYAnchor),
            transitionLogo.widthAnchor.constraint(equalToConstant: 40),
            transitionLogo.heightAnchor.constraint(equalToConstant: 40)
        ])
        layoutKeyboardContents()
        let marker = KeyboardBridge.read("keyboard-transition.json")
        if let id = marker["id"] as? String, let created = marker["time"] as? Double,
           (0..<12).contains(Date().timeIntervalSince1970 - created) {
            coverTransition(id: id, created: created)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        upper = true
        visible = true; lastLayout = ""; localMessage = nil
        UIView.performWithoutAnimation { refresh(); view.layoutIfNeeded() }
        let transition = KeyboardBridge.read("keyboard-transition.json")
        if let id = transition["id"] as? String,
           let created = transition["time"] as? Double,
           (0..<12).contains(Date().timeIntervalSince1970 - created) {
            coverTransition(id: id, created: created)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startHaptic?.prepare(); finishHaptic?.prepare(); cancelHaptic?.prepare()
        if hasFullAccess { directHaptics.prepare() }
        traceTransition("appeared")
        updateTransition()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false; timer?.invalidate(); timer = nil
        hideKeyPreview()
        traceTransition("disappearing")
    }

    @objc private func hostActivityChanged(_ note: Notification) {
        if note.name == .NSExtensionHostDidBecomeActive {
            hostInactive = false
            if sawHostInactive { hostResumedAt = Date().timeIntervalSince1970 }
            traceTransition("host-active")
            updateTransition()
        } else {
            hostInactive = true
            sawHostInactive = true
            hostResumedAt = nil
            traceTransition("host-inactive")
        }
    }

    private func coverTransition(id: String, created: Double = Date().timeIntervalSince1970) {
        if transitionID != id {
            transitionCreated = created
            hostResumedAt = nil
            sawHostInactive = hostInactive
        }
        transitionID = id
        transitionCover.layer.removeAllAnimations()
        transitionCover.overrideUserInterfaceStyle = dark ? .dark : .light
        transitionCover.alpha = 1
        transitionCover.isHidden = false
        // Remove controls from the rendered surface as well as covering them.
        // Remote keyboard snapshots must not capture a second listening panel.
        root.alpha = 0
        root.accessibilityElementsHidden = true
        view.bringSubviewToFront(transitionCover)
        view.layoutIfNeeded()
        traceTransition("covered")
    }

    private func updateTransition() {
        guard visible, let id = transitionID else { return }
        let returning = KeyboardBridge.read("keyboard-return.json")
        let returnTime = returning["id"] as? String == id ? returning["time"] as? Double : nil
        if KeyboardHandoff.canReveal(created: transitionCreated, returnTime: returnTime,
                                     hostResumedAt: hostResumedAt, hostInactive: hostInactive) {
            revealTransition(id: id, animated: true)
        }
    }

    private func traceTransition(_ event: String) {
        #if DEBUG
        var events = KeyboardBridge.read("transition-trace.json")["events"] as? [[String: Any]] ?? []
        events.append(["event": event, "time": Date().timeIntervalSince1970,
                       "covered": transitionID != nil, "visible": visible,
                       "viewHeight": viewIfLoaded?.bounds.height ?? 0,
                       "contentY": root.frame.minY, "contentHeight": root.bounds.height])
        KeyboardBridge.write(["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                              "events": Array(events.suffix(32))], to: "transition-trace.json")
        #endif
    }

    private func revealTransition(id: String, animated: Bool) {
        guard transitionID == id else { return }
        if KeyboardBridge.read("keyboard-transition.json")["id"] as? String == id {
            KeyboardBridge.write([:], to: "keyboard-transition.json")
        }
        traceTransition("revealed")
        transitionID = nil
        root.alpha = 1
        UIView.animate(withDuration: animated && !UIAccessibility.isReduceMotionEnabled ? 0.15 : 0,
            animations: { self.transitionCover.alpha = 0 }, completion: { [weak self] _ in
                guard let self, self.transitionID == nil else { return }
                self.transitionCover.isHidden = true
                self.root.accessibilityElementsHidden = false
                self.transitionID = nil
            })
    }
    override func textDidChange(_ textInput: UITextInput?) { super.textDidChange(textInput); if isViewLoaded { refresh() } }
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func playStartFeedback() {
        logFeedbackRequest("start", generator: startHaptic)
        if !directHaptics.play("start") { startHaptic?.impactOccurred(intensity: 0.8) }
        sounds.play("Start")
        startHaptic?.prepare()
    }
    private func playFinishFeedback() {
        logFeedbackRequest("finish", generator: finishHaptic)
        if !directHaptics.play("finish") { finishHaptic?.notificationOccurred(.success) }
        finishHaptic?.prepare()
    }

    private func logFeedbackRequest(_ event: String, generator: UIFeedbackGenerator?) {
        #if DEBUG
        if #available(iOS 17.5, *) {
            NSLog("TapType keyboard feedback: %@ visible=%d attached=%d fullAccess=%d", event,
                  visible, generator?.view?.window != nil, hasFullAccess)
        }
        #endif
    }

    private func refresh() {
        updateTransition()
        guard let document else { return }
        // Keep our controls in the same appearance as the system keyboard surface.
        overrideUserInterfaceStyle = dark ? .dark : .light
        state = hasFullAccess ? KeyboardBridge.read("state.json") : [:]
        let pending = hasFullAccess ? DictationTicket(KeyboardBridge.read("pending.json")) : nil
        let insertedID = KeyboardBridge.read("inserted.json")["id"] as? String
        ticket = pending.flatMap { Date().timeIntervalSince1970 - $0.created < DictationTicket.lifetime && $0.id != insertedID ? $0 : nil }

        if visible, let ticket, let text = ticket.textToInsert(from: state, document: document, insertedID: insertedID) {
            // Persist before insertion: a keyboard reload cannot replay a completed dictation.
            KeyboardBridge.write(["id": ticket.id], to: "inserted.json")
            sounds.play("Complete")
            textDocumentProxy.insertText(text)
            DictationLatency.mark("inserted", id: ticket.id)
            KeyboardBridge.command("clear", requestID: ticket.id)
            if state["microphoneActive"] as? Bool == false { KeyboardBridge.write([:], to: "state.json") }
            KeyboardBridge.write([:], to: "pending.json")
            self.ticket = nil
            localMessage = nil
        }

        var preparation = KeyboardBridge.read("preparing.json")
        if let id = preparation["id"] as? String, state["transcriptID"] as? String == id {
            KeyboardBridge.write([:], to: "preparing.json")
            preparation = [:]
        }
        let preparing = KeyboardHandoff.isPending(preparation, document: document, state: state)
        let active = ticket != nil || preparing
        left.isHidden = !active
        settingsSlot.isHidden = active
        let waiting = ticket != nil && !matches && alive
        let timedOut = waiting && Date().timeIntervalSince1970 - (ticket?.created ?? 0) > 5
        let error = matches ? state["error"] as? String ?? "" : timedOut ? "Couldn’t start dictation. Tap retry." : ""
        let busy = processing || preparing || (waiting && !timedOut)
        if active { hideKeyPreview() }
        keys.isHidden = active
        listening.isHidden = !active
        let toolbarSymbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        left.setImage(UIImage(systemName: active ? "xmark" : "keyboard.chevron.compact.down",
                              withConfiguration: toolbarSymbol), for: .normal)
        left.tintColor = .label
        left.accessibilityLabel = active ? "Cancel dictation" : "Hide keyboard"
        status.textColor = .secondaryLabel
        status.text = !hasFullAccess ? "Allow Full Access in keyboard settings" : localMessage ?? (state["notice"] as? String ?? "")
        let finished = matches && state["final"] as? Bool == true
        let needsOpen = hasFullAccess && !preparing && !alive && !(matches && (finished || processing))
        let branded = needsOpen || (!active && error.isEmpty && !busy)
        actionWidth.constant = branded ? 124 : 44
        listeningLabel.text = preparing ? "Getting ready…" : !error.isEmpty ? error : finished ? "Ready to insert" : !alive ? "Open TapType to reconnect" :
            state["awaitingConfirmation"] as? Bool == true ? "Tap ✓ to finish" : processing ? (state["cleaning"] as? Bool == true ? "Cleaning up…" : "Finishing…") : recording ? "Listening\niPhone Microphone" : "Connecting…"
        if ticket?.document != document && finished { listeningLabel.text = "Text ready\nTap ✓ to insert here" }
        listeningLabel.font = .systemFont(ofSize: error.isEmpty ? 20 : 14)
        listeningLabel.numberOfLines = 3
        let showLogo = processing && error.isEmpty
        if processingLogo.isHidden == showLogo {
            processingLogo.isHidden = !showLogo
            if showLogo { processingLogo.addSymbolEffect(.pulse, options: .repeating) }
            else { processingLogo.removeAllSymbolEffects() }
        }
        waveform.isHidden = showLogo
        listeningLabel.isHidden = showLogo
        if showLogo { status.text = "" }
        waveform.push(recording ? CGFloat(state["level"] as? Double ?? 0) : 0)
        waveform.accessibilityLabel = "Microphone input level"
        waveform.accessibilityValue = String(Int((state["level"] as? Double ?? 0) * 100))
        action.backgroundColor = .clear
        action.tintColor = .label
        spinner.color = action.tintColor
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = .label
        config.image = busy ? nil : UIImage(systemName: !error.isEmpty ? "arrow.clockwise" : active ? "checkmark" : "waveform",
            withConfiguration: branded ? UIImage.SymbolConfiguration(pointSize: 18, weight: .medium) : toolbarSymbol)
        config.contentInsets = .zero
        if branded {
            config.attributedTitle = AttributedString(appName, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
            config.imagePadding = 6
            config.background.backgroundColor = UIColor.label.withAlphaComponent(0.08)
            config.background.cornerRadius = 22
        }
        action.configuration = config
        action.accessibilityLabel = !error.isEmpty ? "Retry dictation" : active ? "Finish and insert" : "\(appName), start dictation"
        action.isEnabled = !busy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }

        // A completed result can be inserted even after the app releases the mic and suspends.
        action.isHidden = false
        action.isAccessibilityElement = !needsOpen
        if needsOpen {
            linkHost?.view.isHidden = false
            if linkHost == nil || linkDocument != document {
                removeLink()
                let requestID = UUID().uuidString
                var url = URLComponents(string: "taptype://dictate")!
                url.queryItems = [URLQueryItem(name: "id", value: requestID), URLQueryItem(name: "document", value: document)]
                let host = UIHostingController(rootView: OpenVoiceApp(url: url.url!, name: appName,
                    prepare: { [weak self] in
                        guard let self, self.visible, self.document == document else { return false }
                        let marker: [String: Any] = ["id": requestID, "document": document, "time": Date().timeIntervalSince1970]
                        KeyboardBridge.write(marker, to: "handoff.json")
                        KeyboardBridge.write(marker, to: "preparing.json")
                        KeyboardBridge.write(marker, to: "keyboard-transition.json")
                        self.playStartFeedback()
                        UIView.performWithoutAnimation {
                            self.refresh()
                            self.coverTransition(id: requestID)
                        }
                        return true
                    }, captureReturnTarget: { [weak self] in
                        #if DEBUG
                        guard let self, self.visible, self.document == document else { return }
                        let bundle = await self.returnTargetResolver.resolve(for: self)
                        let detail = self.returnTargetResolver.snapshot
                        let now = Date().timeIntervalSince1970
                        KeyboardBridge.write(["id": requestID, "document": document,
                            "host": bundle ?? "", "time": now], to: "keyboard-host.json")
                        KeyboardBridge.write(["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                            "host": bundle ?? "none", "hostPID": detail.hostPID,
                            "statePID": detail.statePID, "stateBundle": detail.stateBundle,
                            "mapped": detail.mappedCount, "time": now], to: "keyboard-host-probe.json")
                        NSLog("TapType keyboard return target: host=%@ hostPID=%d statePID=%d source=%@",
                              bundle ?? "none", detail.hostPID, detail.statePID,
                              detail.stateBundle.isEmpty ? "none" : detail.stateBundle)
                        #endif
                    }, canOpen: { [weak self] in
                        self?.visible == true && self?.document == document && KeyboardBridge.read("preparing.json")["id"] as? String == requestID
                    }, failed: { [weak self] in
                        guard KeyboardBridge.read("preparing.json")["id"] as? String == requestID else { return }
                        KeyboardBridge.write([:], to: "preparing.json")
                        KeyboardBridge.write([:], to: "handoff.json")
                        self?.localMessage = "Couldn’t open TapType. Please try again."
                        self?.refresh()
                        self?.revealTransition(id: requestID, animated: false)
                    }))
                // Match the ready-state UIKit button; host-app safe areas must not offset this 44pt control.
                host.safeAreaRegions = []
                addChild(host); actionSlot.addSubview(host.view)
                host.view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    host.view.leadingAnchor.constraint(equalTo: actionSlot.leadingAnchor),
                    host.view.trailingAnchor.constraint(equalTo: actionSlot.trailingAnchor),
                    host.view.topAnchor.constraint(equalTo: actionSlot.topAnchor),
                    host.view.bottomAnchor.constraint(equalTo: actionSlot.bottomAnchor)
                ])
                host.view.backgroundColor = .clear; host.didMove(toParent: self)
                linkHost = host; linkDocument = document
            }
        } else if preparing { linkHost?.view.isHidden = true }
        else { removeLink() }

        let layout = "\(dark)-\(upper)-\(numbers)-\(symbols)-\(needsInputModeSwitchKey)-\(textDocumentProxy.returnKeyType?.rawValue ?? 0)"
        if layout != lastLayout { lastLayout = layout; rebuildKeys() }
    }

    private func removeLink() {
        linkHost?.willMove(toParent: nil); linkHost?.view.removeFromSuperview(); linkHost?.removeFromParent(); linkHost = nil
    }
    @objc private func actionTapped() {
        guard let document else { return }
        guard hasFullAccess else { localMessage = "Settings → Keyboards → TapType → Allow Full Access"; refresh(); return }
        if var ticket, matches, (state["error"] as? String ?? "").isEmpty {
            DictationLatency.begin(id: ticket.id)
            if ticket.document != document {
                ticket = DictationTicket(["id": ticket.id, "document": document, "created": ticket.created, "committed": true])!
            }
            ticket.committed = true
            KeyboardBridge.write(ticket.dictionary, to: "pending.json")
            if state["final"] as? Bool != true { KeyboardBridge.command("commit", requestID: ticket.id) }
            self.ticket = ticket
            playFinishFeedback()
        } else {
            guard alive else { return }
            let next = DictationTicket(document: document)
            KeyboardBridge.write(next.dictionary, to: "pending.json")
            KeyboardBridge.command("start", requestID: next.id)
            ticket = next; localMessage = nil
            playStartFeedback()
        }
        refresh()
    }
    @objc private func leftTapped() {
        let preparation = KeyboardBridge.read("preparing.json")
        if let document, KeyboardHandoff.isPending(preparation, document: document, state: state) {
            KeyboardBridge.write([:], to: "preparing.json")
            KeyboardBridge.write([:], to: "handoff.json")
            if !directHaptics.play("cancel") { cancelHaptic?.impactOccurred() }
            refresh()
            return
        }
        if let ticket {
            logFeedbackRequest("cancel", generator: cancelHaptic)
            if !directHaptics.play("cancel") { cancelHaptic?.impactOccurred() }
            cancelHaptic?.prepare()
            KeyboardBridge.command("cancel", requestID: ticket.id)
            KeyboardBridge.write([:], to: "pending.json")
            self.ticket = nil; refresh()
        } else { dismissKeyboard() }
    }

    private func rebuildKeys() {
        keys.arrangedSubviews.forEach { keys.removeArrangedSubview($0); $0.removeFromSuperview() }
        if !numbers {
            addRow(Array("qwertyuiop").map(String.init), inset: 0)
            addRow(Array("asdfghjkl").map(String.init), inset: 17)
            let row = rowStack()
            row.addArrangedSubview(key("", symbol: upper ? "shift.fill" : "shift", special: true) { [weak self] in self?.upper.toggle(); self?.refresh() })
            for c in Array("zxcvbnm") { row.addArrangedSubview(letter(String(c))) }
            row.addArrangedSubview(key("", symbol: "delete.left", special: true) { [weak self] in self?.textDocumentProxy.deleteBackward() })
            keys.addArrangedSubview(row)
        } else {
            addRow(symbols ? ["[","]","{","}","#","%","^","*","+","="] : Array("1234567890").map(String.init), inset: 0)
            addRow(symbols ? ["_","\\","|","~","<",">","€","£","¥","•"] : ["-","/",":",";","(",")","$","&","@","\""], inset: 0)
            let row = rowStack()
            row.addArrangedSubview(key(symbols ? "123" : "#+=", special: true) { [weak self] in self?.symbols.toggle(); self?.refresh() })
            for c in [".",",","?","!","'"] { row.addArrangedSubview(letter(c)) }
            row.addArrangedSubview(key("", symbol: "delete.left", special: true) { [weak self] in self?.textDocumentProxy.deleteBackward() })
            keys.addArrangedSubview(row)
        }
        let bottom = rowStack(); bottom.distribution = .fill
        let mode = key(numbers ? "ABC" : "123", special: true) { [weak self] in self?.numbers.toggle(); self?.refresh() }
        bottom.addArrangedSubview(mode)
        mode.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.20).isActive = true
        if needsInputModeSwitchKey {
            let globe = key("", symbol: "globe", special: true) { }
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            globe.accessibilityLabel = "Next keyboard"
            bottom.addArrangedSubview(globe)
            globe.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.12).isActive = true
        }
        let space = key("space") { [weak self] in self?.textDocumentProxy.insertText(" ") }
        bottom.addArrangedSubview(space)
        let returnTitle: String
        switch textDocumentProxy.returnKeyType {
        case .search: returnTitle = "search"
        case .go: returnTitle = "go"
        case .send: returnTitle = "send"
        case .done: returnTitle = "done"
        case .next: returnTitle = "next"
        default: returnTitle = "return"
        }
        let enter = key(returnTitle, special: true) { [weak self] in self?.textDocumentProxy.insertText("\n") }
        if returnTitle != "return" { enter.backgroundColor = .systemBlue; enter.setTitleColor(.white, for: .normal) }
        bottom.addArrangedSubview(enter)
        enter.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.23).isActive = true
        keys.addArrangedSubview(bottom)
    }
    private func rowStack() -> UIStackView {
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 6; row.distribution = .fillEqually; return row
    }
    private func addRow(_ letters: [String], inset: CGFloat) {
        let row = rowStack()
        letters.forEach { row.addArrangedSubview(letter($0)) }
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset)
        keys.addArrangedSubview(row)
    }
    private func letter(_ value: String) -> UIButton {
        let text = upper ? value.uppercased() : value
        let button = key(text) { [weak self] in
            guard let self else { return }
            self.hideKeyPreview(after: 0.09)
            self.textDocumentProxy.insertText(text)
            if self.upper && value.first?.isLetter == true { self.upper = false; self.refresh() }
        }
        button.titleLabel?.font = .systemFont(ofSize: 22)
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button else { return }
            self.showKeyPreview(text, from: button)
        }, for: [.touchDown, .touchDragEnter])
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, self.previewKey === button else { return }
            self.hideKeyPreview(after: 0.09)
        }, for: .touchUpInside)
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, self.previewKey === button else { return }
            self.hideKeyPreview()
        }, for: [.touchCancel, .touchUpOutside, .touchDragExit])
        return button
    }
    private func showKeyPreview(_ text: String, from button: UIButton) {
        previewDismissal?.cancel()
        previewKey = button
        let keyFrame = button.convert(button.bounds, to: view)
        let width: CGFloat = max(52, keyFrame.width + 16)
        keyPreview.frame = CGRect(x: max(4, min(view.bounds.width - width - 4, keyFrame.midX - width / 2)),
            y: max(3, keyFrame.minY - 53), width: width, height: 53)
        keyPreview.text = text; keyPreview.font = .systemFont(ofSize: 32)
        keyPreview.textAlignment = .center; keyPreview.textColor = .label
        keyPreview.backgroundColor = dark ? UIColor(white: 0.42, alpha: 1) : .white
        keyPreview.layer.cornerRadius = 9; keyPreview.layer.masksToBounds = true
        keyPreview.isUserInteractionEnabled = false; keyPreview.isAccessibilityElement = false
        keyPreview.isHidden = false
        if keyPreview.superview == nil { view.addSubview(keyPreview) }
        view.bringSubviewToFront(keyPreview)
    }
    private func hideKeyPreview(after delay: TimeInterval = 0) {
        previewDismissal?.cancel()
        if delay == 0 { keyPreview.isHidden = true; previewKey = nil; return }
        let work = DispatchWorkItem { [weak self] in self?.keyPreview.isHidden = true; self?.previewKey = nil }
        previewDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func key(_ title: String, symbol: String? = nil, special: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = KeyboardKey(type: .custom)
        button.setTitle(title, for: .normal); button.setTitleColor(.label, for: .normal); button.tintColor = .label
        button.accessibilityTraits.insert(.keyboardKey)
        button.titleLabel?.font = .systemFont(ofSize: 16)
        if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
        button.backgroundColor = dark ? UIColor(white: special ? 0.24 : 0.31, alpha: 1) : special ? UIColor(white: 0.68, alpha: 1) : .white
        button.layer.cornerRadius = 6
        button.layer.shadowColor = UIColor.black.cgColor; button.layer.shadowOpacity = 0.16
        button.layer.shadowOffset = CGSize(width: 0, height: 1); button.layer.shadowRadius = 0
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}
