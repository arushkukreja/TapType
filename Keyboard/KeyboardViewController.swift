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

    // Shared through the app group so a fresh keyboard process still knows earlier hosts.
    private var returnTargets = HostReturnCache(KeyboardBridge.read("host-cache.json"))
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

    /// Notes the host app while the keyboard is showing in it, before any tap, so a tap
    /// still knows where to return when iOS briefly reports the Home Screen instead.
    func learn(for controller: UIInputViewController) {
        Self.enableArbiterIfNeeded()
        guard let client = Self.arbiterClient() else { return }
        _ = currentHost(client: client, controller: controller)
    }

    private func currentHost(client: NSObject, controller: UIInputViewController) -> String? {
        let hostPID = Self.integerValue(controller, selector: "_hostProcessIdentifier") ?? 0
        let state = Self.objectValue(client, selector: "currentClientState") as? NSObject
        let statePID = state.flatMap { Self.integerValue($0, selector: "processIdentifier") } ?? 0
        let stateBundle = state.flatMap { Self.objectValue($0, selector: "sourceBundleIdentifier") as? String } ?? ""
        if statePID > 0, Self.validBundle(stateBundle), stateBundle != "com.apple.springboard" {
            let before = returnTargets.bundle(for: statePID, now: ProcessInfo.processInfo.systemUptime)
            returnTargets.observe(pid: statePID, bundle: stateBundle, now: ProcessInfo.processInfo.systemUptime)
            if before != stateBundle { KeyboardBridge.write(returnTargets.dictionary, to: "host-cache.json") }
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
    /// Receives its own touches instead of going through KeyTouchStack (the globe key).
    var passesTouches = false
    /// Repeats while held (delete).
    var repeats = false
    var didRepeat = false
    private var restingColor: UIColor?
    override func layoutSubviews() {
        super.layoutSubviews()
        // An explicit shadow path avoids offscreen shadow rendering for every key.
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }
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

/// Handles all key touches the way the system keyboard does, instead of leaving each
/// key button to track its own touch:
/// - a touch anywhere in the key area, including the gaps between keys, goes to the
///   nearest key;
/// - sliding a finger moves to the key under it rather than cancelling the press;
/// - a new finger landing commits the key under the previous finger (fast-typing rollover);
/// - keys marked `repeats` (delete) repeat while held.
/// Key buttons keep their UIActions; this view triggers them with `sendActions`.
private final class KeyTouchStack: UIStackView {
    /// Light tap feedback on every key press.
    var onPress: (() -> Void)?
    private var pressed: [ObjectIdentifier: (touch: UITouch, key: KeyboardKey)] = [:]
    private var repeatTimer: Timer?

    override init(frame: CGRect) { super.init(frame: frame); isMultipleTouchEnabled = true }
    required init(coder: NSCoder) { super.init(coder: coder); isMultipleTouchEnabled = true }

    private var allKeys: [KeyboardKey] {
        arrangedSubviews.flatMap { $0.subviews }.compactMap { $0 as? KeyboardKey }
    }
    /// The globe key needs real touch events for the system input-mode menu.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        if let globe = allKeys.first(where: { $0.passesTouches && $0.convert($0.bounds, to: self).contains(point) }) { return globe }
        return self
    }
    /// Count touches slightly above the top row, like the system keyboard.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.inset(by: UIEdgeInsets(top: -10, left: 0, bottom: 0, right: 0)).contains(point)
    }
    private func nearestKey(to point: CGPoint) -> KeyboardKey? {
        var best: (key: KeyboardKey, distance: CGFloat)?
        for key in allKeys where !key.passesTouches && !key.isHidden {
            let frame = key.convert(key.bounds, to: self)
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = dx * dx + dy * dy
            if distance == 0 { return key }
            if best == nil || distance < best!.distance { best = (key, distance) }
        }
        return best?.key
    }
    private func press(_ key: KeyboardKey, for touch: UITouch) {
        pressed[ObjectIdentifier(touch)] = (touch, key)
        key.isHighlighted = true
        key.sendActions(for: .touchDown)
        onPress?()
        if key.repeats { startRepeating(key) }
    }
    private func release(_ id: ObjectIdentifier, commit: Bool) {
        guard let entry = pressed.removeValue(forKey: id) else { return }
        entry.key.isHighlighted = false
        stopRepeating()
        // A held delete key already fired while repeating; don't fire once more.
        if commit && !(entry.key.repeats && entry.key.didRepeat) { entry.key.sendActions(for: .touchUpInside) }
        else if !commit { entry.key.sendActions(for: .touchCancel) }
        entry.key.didRepeat = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Rollover: commit keys still held before pressing the new one.
        for id in Array(pressed.keys) { release(id, commit: true) }
        for touch in touches {
            if let key = nearestKey(to: touch.location(in: self)) { press(key, for: touch) }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard let entry = pressed[id], let key = nearestKey(to: touch.location(in: self)), key !== entry.key else { continue }
            // Slid to a neighboring key: move the press there, like the system keyboard.
            entry.key.isHighlighted = false
            entry.key.sendActions(for: .touchDragExit)
            stopRepeating()
            pressed[id] = (touch, key)
            key.isHighlighted = true
            key.sendActions(for: .touchDragEnter)
            if key.repeats { startRepeating(key) }
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { release(ObjectIdentifier(touch), commit: true) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { release(ObjectIdentifier(touch), commit: false) }
    }
    /// Drop any press when the keys are hidden or rebuilt mid-touch.
    func cancelAll() { for id in Array(pressed.keys) { release(id, commit: false) } }
    private func startRepeating(_ key: KeyboardKey) {
        stopRepeating()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self, weak key] _ in
            guard let self, let key else { return }
            key.didRepeat = true
            key.sendActions(for: .touchUpInside)
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak key] _ in
                key?.sendActions(for: .touchUpInside)
            }
        }
    }
    private func stopRepeating() { repeatTimer?.invalidate(); repeatTimer = nil }
}

/// One row of keys laid out on the system keyboard's grid. Every letter key is one
/// tenth of the row (less gaps), so keys line up between rows the way thumbs expect:
/// - `.centered`: equal keys centred in the row; a 9-key row lands half a key in (A under Q/W).
/// - `.third`: first and last keys (shift, delete) are wider and flush to the edges;
///   the keys between fill the centred span of 7 letters, so Z sits under S and M under K.
private final class KeyRow: UIView {
    enum Style { case centered, third }
    static let gap: CGFloat = 6
    private let style: Style
    private let keys: [UIView]

    init(_ keys: [UIView], style: Style) {
        self.keys = keys; self.style = style
        super.init(frame: .zero)
        keys.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = Self.gap, height = bounds.height
        let keyWidth = (bounds.width - 9 * gap) / 10
        let pitch = keyWidth + gap
        func place(_ view: UIView, x: CGFloat, width: CGFloat) {
            view.frame = CGRect(x: x, y: 0, width: width, height: height).integral
        }
        switch style {
        case .centered:
            let count = CGFloat(keys.count)
            let start = (bounds.width - count * keyWidth - (count - 1) * gap) / 2
            for (index, key) in keys.enumerated() { place(key, x: start + CGFloat(index) * pitch, width: keyWidth) }
        case .third:
            guard keys.count >= 3, let first = keys.first, let last = keys.last else { return }
            let sideWidth = (keyWidth * 1.35).rounded()
            place(first, x: 0, width: sideWidth)
            place(last, x: bounds.width - sideWidth, width: sideWidth)
            let middle = keys.dropFirst().dropLast()
            let count = CGFloat(middle.count)
            let span = 7 * keyWidth + 6 * gap
            let width = (span - (count - 1) * gap) / count
            for (index, key) in middle.enumerated() { place(key, x: 1.5 * pitch + CGFloat(index) * (width + gap), width: width) }
        }
    }
}

private enum KeyboardMetrics {
    // 44pt toolbar + 12pt gap + four 42pt key rows with 12pt between them,
    // plus the 12pt the content is inset from the keyboard's edges.
    static let height: CGFloat = 272
    /// Taller while reviewing an edit, so a paragraph of changes fits.
    static let reviewHeight: CGFloat = 350
}

private final class FixedHeightKeyboardView: UIInputView {
    var height = KeyboardMetrics.height { didSet { if height != oldValue { invalidateIntrinsicContentSize() } } }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: height)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        CGSize(width: targetSize.width, height: height)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority) -> CGSize {
        CGSize(width: targetSize.width, height: height)
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
    let label: String
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
        .accessibilityLabel(label)
        .buttonStyle(.plain)
    }
}

/// Scrolling level bars redrawn every frame. The app sends a burst of buffer levels
/// about ten times a second; they play back at a steady pace and each bar eases
/// toward its target, so motion stays continuous between bursts.
private final class VoiceWaveform: UIView {
    private static let barCount = 11
    private static let step: CFTimeInterval = 0.06   // seconds per bar shift
    private static let perStep = 3                   // ≈ 47 levels/s × 0.06 s
    private static let maxQueued = 14                // never lag the mic by more than ~0.3 s
    private var targets = Array(repeating: CGFloat(0), count: barCount)
    private var levels = Array(repeating: CGFloat(0), count: barCount)
    private var queue: [CGFloat] = []
    private var elapsed: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0
    private var link: CADisplayLink?

    /// Adds captured levels, oldest first. Calling with no levels lets the bars settle to rest.
    func enqueue(_ incoming: [CGFloat]) {
        queue.append(contentsOf: incoming)
        if queue.count > Self.maxQueued { queue.removeFirst(queue.count - Self.maxQueued) }
        if link == nil, !queue.isEmpty || !atRest { start() }
    }
    private var atRest: Bool { (targets + levels).allSatisfy { $0 < 0.005 } }
    private func start() {
        guard window != nil, !isHidden else { return }
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link; lastFrame = 0
    }
    private func stop() { link?.invalidate(); link = nil }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { stop() } }
    override var isHidden: Bool { didSet { if isHidden { stop() } } }
    fileprivate func frame(_ link: CADisplayLink) {
        let dt = lastFrame == 0 ? 1.0 / 60 : min(0.1, link.timestamp - lastFrame)
        lastFrame = link.timestamp
        elapsed += dt
        while elapsed >= Self.step {
            elapsed -= Self.step
            let taken = queue.prefix(Self.perStep)
            queue.removeFirst(taken.count)
            targets.removeFirst()
            targets.append(taken.max() ?? (targets.last ?? 0) * 0.5)
        }
        let ease = CGFloat(1 - exp(-dt * 20))
        for index in levels.indices { levels[index] += (targets[index] - levels[index]) * ease }
        setNeedsDisplay()
        if queue.isEmpty && atRest { stop() }
    }
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

/// Breaks the retain cycle between CADisplayLink and its target.
private final class DisplayLinkProxy: NSObject {
    private weak var waveform: VoiceWaveform?
    init(_ waveform: VoiceWaveform) { self.waveform = waveform }
    @objc func frame(_ link: CADisplayLink) {
        guard let waveform else { link.invalidate(); return }
        waveform.frame(link)
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
    private let styleButton = UIButton(type: .system)
    private var lastStyleLook = ""
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
    private let keys = KeyTouchStack()
    private let keyPreview = UILabel()
    private var previewDismissal: DispatchWorkItem?
    private weak var previewKey: UIButton?
    private let listening = UIView()
    private let waveform = VoiceWaveform()
    private let processingLogo = UIImageView(image: UIImage(systemName: "waveform"))
    private let listeningLabel = UILabel()
    /// A button that has to open TapType first (when it isn't running) for its purpose.
    private final class VoiceLink {
        let purpose: DictationPurpose
        var host: UIHostingController<OpenVoiceApp>?
        var document = ""
        init(_ purpose: DictationPurpose) { self.purpose = purpose }
    }
    private let actionLink = VoiceLink(.dictate)
    private let editLink = VoiceLink(.edit)
    private let replyLink = VoiceLink(.review)
    private var keyboardView: FixedHeightKeyboardView?
    private var heightConstraint: NSLayoutConstraint!
    private var keyboardHeight = KeyboardMetrics.height
    // Edit by voice
    private let editSlot = UIView()
    private let editButton = UIButton(type: .system)
    private let reviewPanel = UIView()
    private let reviewHeader = UILabel()
    private let reviewText = UITextView()
    private let reviewPrevious = UIButton(type: .system)
    private let reviewNext = UIButton(type: .system)
    private let reviewInclude = UIButton(type: .system)
    private let reviewCompare = UIButton(type: .system)
    private let replySlot = UIView()
    private let replyButton = UIButton(type: .system)
    /// A suggestion waiting for approval. Nothing in the text field changes until you apply it.
    private struct Review {
        var document: String
        var instruction: String
        var context: VoiceEditContext
        var matches: [VoiceEditMatch]
        var included: [Bool]
        var index = 0
        var showBefore = false
        var isUndo = false
    }
    private var review: Review?
    private var editRequest: VoiceEditRequest?
    private var applying = false
    private var editEnabled: Bool { state["voiceEditEnabled"] as? Bool ?? VoiceEditPreference.enabled }
    private var timer: Timer?
    private var stateSignal: BridgeSignal?
    private var lastRefresh: CFTimeInterval = 0
    private var lastLevelSequence = -1
    private var lastActionStyle = ""
    private var state: [String: Any] = [:]
    private var ticket: DictationTicket?
    private var visible = false
    private var upper = true
    private var numbers = false
    private var symbols = false
    private var localMessage: String?
    private var startHaptic: UIImpactFeedbackGenerator?
    private var finishHaptic: UINotificationFeedbackGenerator?
    private var cancelHaptic: UIImpactFeedbackGenerator?
    private var keyHaptic: UIImpactFeedbackGenerator?
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
        keyboardView = keyboard
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
        let contentHeight = min(keyboardHeight - 12, max(0, view.bounds.height - 12))
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
        root.axis = .vertical; root.spacing = 12
        root.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        view.addSubview(root)
        heightConstraint = view.heightAnchor.constraint(equalToConstant: KeyboardMetrics.height)
        heightConstraint.isActive = true
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
        styleButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        styleButton.showsMenuAsPrimaryAction = true
        styleButton.setContentHuggingPriority(.required, for: .horizontal)
        styleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionWidth = actionSlot.widthAnchor.constraint(equalToConstant: 44)
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
            keyHaptic = UIImpactFeedbackGenerator(style: .light, view: keys)
        } else {
            startHaptic = UIImpactFeedbackGenerator(style: .medium)
            finishHaptic = UINotificationFeedbackGenerator()
            cancelHaptic = UIImpactFeedbackGenerator(style: .light)
            keyHaptic = UIImpactFeedbackGenerator(style: .light)
        }
        keys.onPress = { [weak self] in self?.keyHaptic?.impactOccurred(intensity: 0.5); self?.keyHaptic?.prepare() }
        setUpEditControls()
        toolbar.addArrangedSubview(left); toolbar.addArrangedSubview(settingsSlot)
        toolbar.addArrangedSubview(status); toolbar.addArrangedSubview(styleButton)
        toolbar.addArrangedSubview(editSlot)
        toolbar.addArrangedSubview(actionSlot)
        keys.axis = .vertical; keys.spacing = 12; keys.distribution = .fillEqually
        // Both states occupy exactly the same area. Hiding an arranged subview
        // used to make UIStackView reflow while the host was being restored.
        root.addArrangedSubview(toolbar)
        root.addArrangedSubview(bodyPanel)
        for panel in [keys, listening, reviewPanel] {
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
        visible = true; lastLayout = ""; lastActionStyle = ""; localMessage = nil
        UIView.performWithoutAnimation { refresh(); view.layoutIfNeeded() }
        let transition = KeyboardBridge.read("keyboard-transition.json")
        if let id = transition["id"] as? String,
           let created = transition["time"] as? Double,
           (0..<12).contains(Date().timeIntervalSince1970 - created) {
            coverTransition(id: id, created: created)
        }
        timer?.invalidate()
        // The app signals each state change, so refresh immediately. The timer is a
        // fallback (and notices a stopped app); skip it when a signal just refreshed.
        stateSignal = BridgeSignal(observing: .state) { [weak self] in
            guard let self, self.visible else { return }
            self.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, CACurrentMediaTime() - self.lastRefresh > 0.08 else { return }
            self.refresh()
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // iOS hides its own mic below the keyboard only after the host app receives this
        // flag while TapType is the active keyboard. Setting it in viewDidLoad alone can
        // arrive before the keyboard is connected to the host, so send it again here.
        hasDictationKey = true
        startHaptic?.prepare(); finishHaptic?.prepare(); cancelHaptic?.prepare(); keyHaptic?.prepare()
        if hasFullAccess { directHaptics.prepare() }
        traceTransition("appeared")
        updateTransition()
        #if DEBUG
        if hasFullAccess { returnTargetResolver.learn(for: self) }
        #endif
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false; timer?.invalidate(); timer = nil; stateSignal = nil
        hideKeyPreview()
        traceTransition("disappearing")
    }

    @objc private func hostActivityChanged(_ note: Notification) {
        if note.name == .NSExtensionHostDidBecomeActive {
            #if DEBUG
            if hasFullAccess { returnTargetResolver.learn(for: self) }
            #endif
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
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        #if DEBUG
        if hasFullAccess { returnTargetResolver.learn(for: self) }
        #endif
        if isViewLoaded { refresh() }
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func playStartFeedback() {
        logFeedbackRequest("start", generator: startHaptic)
        if !directHaptics.play("start") { startHaptic?.impactOccurred(intensity: 0.8) }
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
        lastRefresh = CACurrentMediaTime()
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
            textDocumentProxy.insertText(text)
            // Remember it: an edit that doesn't name a part changes the last dictation.
            KeyboardBridge.write(["document": document, "text": text], to: "voice-edit-last.json")
            keyHaptic?.impactOccurred(intensity: 0.7)
            DictationLatency.mark("inserted", id: ticket.id)
            KeyboardBridge.command("clear", requestID: ticket.id)
            if state["microphoneActive"] as? Bool == false { KeyboardBridge.write([:], to: "state.json") }
            KeyboardBridge.write([:], to: "pending.json")
            self.ticket = nil
            localMessage = nil
        }

        // An edit instruction finished: show its suggestion, or act on a spoken review command.
        if visible, let ticket, ticket.purpose != .dictate, matches, state["final"] as? Bool == true,
           let outcome = VoiceEditOutcome(state["voiceEdit"] as? [String: Any]), outcome.id == ticket.id {
            finishInstruction(ticket, outcome: outcome, document: document)
        }

        var preparation = KeyboardBridge.read("preparing.json")
        if let id = preparation["id"] as? String, state["transcriptID"] as? String == id {
            KeyboardBridge.write([:], to: "preparing.json")
            preparation = [:]
        }
        let preparing = KeyboardHandoff.isPending(preparation, document: document, state: state)
        let active = ticket != nil || preparing
        if let review, review.document != document { self.review = nil }
        let reviewing = review != nil && !active
        let editPurpose = ticket.map { $0.purpose != .dictate } ?? false
        left.isHidden = !active && !reviewing
        settingsSlot.isHidden = active || reviewing
        let waiting = ticket != nil && !matches && alive
        let refused = waiting && state["refusedStart"] as? String == ticket?.id ? state["refusedReason"] as? String : nil
        let timedOut = waiting && Date().timeIntervalSince1970 - (ticket?.created ?? 0) > 5
        let error = matches ? state["error"] as? String ?? "" : refused ?? (timedOut ? "Couldn’t start dictation. Tap retry." : "")
        let busy = processing || preparing || (waiting && !timedOut && refused == nil)
        if active { hideKeyPreview() }
        keys.isHidden = active || reviewing
        listening.isHidden = !active
        reviewPanel.isHidden = !reviewing
        let toolbarSymbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        left.setImage(UIImage(systemName: active || reviewing ? "xmark" : "keyboard.chevron.compact.down",
                              withConfiguration: toolbarSymbol), for: .normal)
        left.tintColor = .label
        left.accessibilityLabel = reviewing ? "Cancel edit" : active ? (editPurpose ? "Cancel edit" : "Cancel dictation") : "Hide keyboard"
        status.textColor = .secondaryLabel
        status.text = !hasFullAccess ? "Allow Full Access in keyboard settings" : localMessage ?? (editPurpose ? "" : state["notice"] as? String ?? "")
        if reviewing, let review { status.text = applying ? "Applying…" : review.isUndo ? "Undo last edit" : "“\(review.instruction)”" }
        let finished = matches && state["final"] as? Bool == true
        let needsOpen = hasFullAccess && !preparing && !alive && !(matches && (finished || processing))
        let branded = needsOpen || (!active && error.isEmpty && !busy)
        listeningLabel.text = preparing ? "Getting ready…" : !error.isEmpty ? error : finished ? "Ready to insert" : !alive ? "Open TapType to reconnect" :
            state["awaitingConfirmation"] as? Bool == true ? "Tap ✓ to finish" : processing ? (state["cleaning"] as? Bool == true ? "Cleaning up…" : "Finishing…") : recording ? "Listening\niPhone Microphone" : "Connecting…"
        if ticket?.document != document && finished { listeningLabel.text = "Text ready\nTap ✓ to insert here" }
        // Show the words as they're recognized; the newest stay visible.
        let live = recording && error.isEmpty ? (state["live"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if !live.isEmpty { listeningLabel.text = live }
        if editPurpose && recording && live.isEmpty && error.isEmpty {
            listeningLabel.text = ticket?.purpose == .review ? "Say “apply”, “cancel”,\nor what to change" : "Say your edit\n“make this a bulleted list”"
        }
        listeningLabel.font = .systemFont(ofSize: !error.isEmpty ? 14 : live.isEmpty ? 20 : 17)
        listeningLabel.lineBreakMode = live.isEmpty ? .byTruncatingTail : .byTruncatingHead
        listeningLabel.numberOfLines = 3
        let showLogo = processing && error.isEmpty
        if processingLogo.isHidden == showLogo {
            processingLogo.isHidden = !showLogo
            if showLogo { processingLogo.addSymbolEffect(.pulse, options: .repeating) }
            else { processingLogo.removeAllSymbolEffects() }
        }
        waveform.isHidden = showLogo
        listeningLabel.isHidden = showLogo
        if showLogo { status.text = state["editing"] as? Bool == true ? "Working on your edit…" : "" }
        // The style menu steps aside while a message shows, so the message has room
        // beside the Edit and TapType buttons, even on a 375pt-wide iPhone.
        let showingMessage = !(status.text ?? "").isEmpty
        updateStyleButton(hidden: active || reviewing || showingMessage || !hasFullAccess || SharedSettings.cleanupMode == "original")
        if recording {
            if let sequence = state["levelSequence"] as? Int {
                if sequence != lastLevelSequence {
                    lastLevelSequence = sequence
                    waveform.enqueue((state["levels"] as? [Double] ?? []).map { CGFloat($0) })
                }
            } else {
                // An app build without level bursts: one level per refresh.
                waveform.enqueue([CGFloat(state["level"] as? Double ?? 0)])
            }
        } else {
            waveform.enqueue([])
        }
        waveform.accessibilityLabel = "Microphone input level"
        waveform.accessibilityValue = String(Int((state["level"] as? Double ?? 0) * 100))
        action.backgroundColor = .clear
        action.tintColor = .label
        spinner.color = action.tintColor
        // Rebuilding the configuration re-lays out the button, so only do it when its look changes.
        let actionStyle = "\(busy)|\(error.isEmpty)|\(active)|\(branded)|\(appName)|\(reviewing)"
        actionWidth.constant = reviewing ? 98 : 44
        if actionStyle != lastActionStyle {
            lastActionStyle = actionStyle
            var config = UIButton.Configuration.plain()
            config.baseForegroundColor = .label
            if reviewing {
                config.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
                config.attributedTitle = AttributedString("Apply", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
                config.imagePadding = 6; config.contentInsets = .zero
                config.baseForegroundColor = .white
                config.background.backgroundColor = .systemBlue
                config.background.cornerRadius = 22
                action.configuration = config
            } else {
            config.image = busy ? nil : UIImage(systemName: !error.isEmpty ? "arrow.clockwise" : active ? "checkmark" : "waveform",
                withConfiguration: branded ? UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold) : toolbarSymbol)
            config.contentInsets = .zero
            if branded {
                // Just the logo, in a circle.
                config.background.backgroundColor = UIColor.label.withAlphaComponent(0.08)
                config.background.cornerRadius = 22
            }
            action.configuration = config
            }
        }
        action.accessibilityLabel = reviewing ? "Apply changes" : !error.isEmpty ? "Retry dictation" : active ? (editPurpose ? "Finish speaking" : "Finish and insert") : "\(appName), start dictation"
        action.isEnabled = reviewing ? !applying && (review?.included.contains(true) ?? false) : !busy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }

        // A completed result can be inserted even after the app releases the mic and suspends.
        action.isHidden = false
        action.isAccessibilityElement = !needsOpen
        let showEdit = hasFullAccess && editEnabled && !active && !reviewing && !applying
        editSlot.isHidden = !showEdit
        syncLink(actionLink, in: actionSlot, needed: needsOpen && !reviewing, preparing: preparing, document: document)
        syncLink(editLink, in: editSlot, needed: needsOpen && showEdit, preparing: preparing, document: document)
        syncLink(replyLink, in: replySlot, needed: needsOpen && reviewing && !applying, preparing: preparing, document: document)
        setKeyboardHeight(reviewing ? KeyboardMetrics.reviewHeight : KeyboardMetrics.height)
        if reviewing { renderReview() }

        let layout = "\(dark)-\(upper)-\(numbers)-\(symbols)-\(needsInputModeSwitchKey)-\(textDocumentProxy.returnKeyType?.rawValue ?? 0)"
        if layout != lastLayout { lastLayout = layout; rebuildKeys() }
    }

    /// The speaking-style menu beside the TapType button. Rebuilt only when it changes.
    private func updateStyleButton(hidden: Bool) {
        let current = SharedSettings.speakingStyle
        let look = "\(hidden)|\(current)"
        guard look != lastStyleLook else { return }
        lastStyleLook = look
        styleButton.isHidden = hidden
        guard !hidden else { return }
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = .label
        config.attributedTitle = AttributedString(SharedSettings.styleTitle(current),
            attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 5
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 12)
        config.background.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        config.background.cornerRadius = 22
        styleButton.configuration = config
        styleButton.accessibilityLabel = "Speaking style"
        styleButton.accessibilityValue = SharedSettings.styleTitle(current)
        styleButton.menu = UIMenu(options: .singleSelection, children: SharedSettings.styles.map { style in
            UIAction(title: style.title, state: style.id == current ? .on : .off) { [weak self] _ in
                SharedSettings.set("speakingStyle", style.id)
                self?.keyHaptic?.impactOccurred(intensity: 0.5)
                self?.refresh()
            }
        })
    }

    private func syncLink(_ link: VoiceLink, in slot: UIView, needed: Bool, preparing: Bool, document: String) {
        if needed {
            link.host?.view.isHidden = false
            if link.host == nil || link.document != document {
                removeLink(link)
                installLink(link, in: slot, document: document)
            }
        } else if preparing { link.host?.view.isHidden = true }
        else { removeLink(link) }
    }
    private func removeLink(_ link: VoiceLink) {
        link.host?.willMove(toParent: nil); link.host?.view.removeFromSuperview(); link.host?.removeFromParent(); link.host = nil
    }
    /// Covers a button with one that opens TapType to start the microphone, for when the
    /// app isn't running. Edit and review buttons first save the text the edit is about.
    private func installLink(_ link: VoiceLink, in slot: UIView, document: String) {
        let requestID = UUID().uuidString
        var url = URLComponents(string: "taptype://dictate")!
        url.queryItems = [URLQueryItem(name: "id", value: requestID), URLQueryItem(name: "document", value: document)]
        if link.purpose != .dictate { url.queryItems?.append(URLQueryItem(name: "purpose", value: link.purpose.rawValue)) }
        let label = link.purpose == .edit ? "Edit by voice" : link.purpose == .review ? "Reply by voice" : "\(appName), start dictation"
        let purpose = link.purpose
        let host = UIHostingController(rootView: OpenVoiceApp(url: url.url!, label: label,
            prepare: { [weak self] in
                guard let self, self.visible, self.document == document else { return false }
                if purpose != .dictate, !self.writeEditRequest(id: requestID, document: document, purpose: purpose) {
                    self.refresh(); return false
                }
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
        addChild(host); slot.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: slot.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: slot.bottomAnchor)
        ])
        host.view.backgroundColor = .clear; host.didMove(toParent: self)
        link.host = host; link.document = document
    }
    @objc private func actionTapped() {
        guard let document else { return }
        guard hasFullAccess else { localMessage = "Settings → Keyboards → TapType → Allow Full Access"; refresh(); return }
        if review != nil, ticket == nil { applyReview(); return }
        if var ticket, matches, (state["error"] as? String ?? "").isEmpty {
            DictationLatency.begin(id: ticket.id)
            if ticket.document != document {
                ticket = DictationTicket(document: document, id: ticket.id, now: ticket.created, purpose: ticket.purpose)
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
        } else if review != nil {
            guard !applying else { return }
            review = nil; localMessage = "Edit cancelled. Nothing changed."
            if !directHaptics.play("cancel") { cancelHaptic?.impactOccurred() }
            refresh()
        } else { dismissKeyboard() }
    }

    // MARK: Edit by voice

    private func setUpEditControls() {
        editSlot.widthAnchor.constraint(equalToConstant: 44).isActive = true
        editSlot.heightAnchor.constraint(equalToConstant: 44).isActive = true
        editButton.translatesAutoresizingMaskIntoConstraints = false
        editButton.setImage(UIImage(systemName: "wand.and.sparkles",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)), for: .normal)
        editButton.tintColor = .label
        editButton.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        editButton.layer.cornerRadius = 22
        editButton.accessibilityLabel = "Edit by voice"
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        editSlot.addSubview(editButton)
        pin(editButton, to: editSlot)
        editSlot.isHidden = true

        reviewHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        reviewHeader.textColor = .secondaryLabel
        reviewHeader.setContentHuggingPriority(.required, for: .vertical)
        reviewText.isEditable = false
        reviewText.isSelectable = false
        reviewText.backgroundColor = UIColor.label.withAlphaComponent(0.06)
        reviewText.layer.cornerRadius = 10
        reviewText.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        reviewText.showsVerticalScrollIndicator = true
        reviewText.accessibilityLabel = "Suggested change"
        configure(reviewPrevious, symbol: "chevron.left", title: nil, label: "Previous change") { $0.reviewStep(-1) }
        configure(reviewNext, symbol: "chevron.right", title: nil, label: "Next change") { $0.reviewStep(1) }
        configure(reviewInclude, symbol: nil, title: "Skip", label: "Skip this change") { $0.toggleIncluded() }
        configure(reviewCompare, symbol: nil, title: "Before", label: "Show the original text") { $0.toggleCompare() }
        configure(replyButton, symbol: "mic.fill", title: "Reply", label: "Reply by voice") { $0.replyTapped() }
        replyButton.translatesAutoresizingMaskIntoConstraints = false
        replySlot.addSubview(replyButton)
        pin(replyButton, to: replySlot)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = UIStackView(arrangedSubviews: [reviewPrevious, reviewNext, reviewInclude, reviewCompare, spacer, replySlot])
        controls.axis = .horizontal; controls.spacing = 8; controls.alignment = .fill
        controls.heightAnchor.constraint(equalToConstant: 36).isActive = true
        for button in [reviewPrevious, reviewNext] { button.widthAnchor.constraint(equalToConstant: 40).isActive = true }
        replySlot.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let stack = UIStackView(arrangedSubviews: [reviewHeader, reviewText, controls])
        stack.axis = .vertical; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        reviewPanel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: reviewPanel.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: reviewPanel.trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: reviewPanel.topAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: reviewPanel.bottomAnchor)
        ])
        reviewPanel.isHidden = true
    }

    private func pin(_ view: UIView, to slot: UIView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
            view.topAnchor.constraint(equalTo: slot.topAnchor),
            view.bottomAnchor.constraint(equalTo: slot.bottomAnchor)
        ])
    }

    private func configure(_ button: UIButton, symbol: String?, title: String?, label: String,
                           action: @escaping (KeyboardViewController) -> Void) {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        if let symbol { config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)) }
        if let title { config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .medium)])) }
        config.imagePadding = 5
        button.configuration = config
        button.accessibilityLabel = label
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.keyHaptic?.impactOccurred(intensity: 0.5)
            action(self)
        }, for: .touchUpInside)
    }

    private func setTitle(_ title: String, of button: UIButton, label: String) {
        guard var config = button.configuration else { return }
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 14, weight: .medium)]))
        button.configuration = config
        button.accessibilityLabel = label
    }

    private func setKeyboardHeight(_ height: CGFloat) {
        guard height != keyboardHeight else { return }
        keyboardHeight = height
        heightConstraint.constant = height
        keyboardView?.height = height
        view.setNeedsLayout()
    }

    /// The text iOS lets the keyboard see around the cursor, trimmed to what an edit can use.
    private func currentContext() -> VoiceEditContext {
        let proxy = textDocumentProxy
        return VoiceEditPlanner.window(VoiceEditContext(before: proxy.documentContextBeforeInput ?? "",
            selected: proxy.selectedText ?? "", after: proxy.documentContextAfterInput ?? ""))
    }

    /// Saves what the edit is about before the instruction is spoken: the visible text,
    /// the last dictation, and when replying, the suggestion being reviewed.
    private func writeEditRequest(id: String, document: String, purpose: DictationPurpose) -> Bool {
        let request: VoiceEditRequest
        if purpose == .review, let review {
            request = VoiceEditRequest(id: id, document: document, context: review.context,
                lastDictation: lastDictation(for: document, in: review.context),
                instruction: review.isUndo ? "" : review.instruction, previous: review.matches.map(\.change))
        } else {
            let context = currentContext()
            guard !context.full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                localMessage = "There’s no text here to edit yet."
                return false
            }
            request = VoiceEditRequest(id: id, document: document, context: context,
                                       lastDictation: lastDictation(for: document, in: context))
        }
        editRequest = request
        KeyboardBridge.write(request.dictionary, to: "voice-edit-request.json")
        return true
    }

    private func lastDictation(for document: String, in context: VoiceEditContext) -> String {
        let last = KeyboardBridge.read("voice-edit-last.json")
        guard last["document"] as? String == document, let text = last["text"] as? String,
              !text.isEmpty, context.full.contains(text) else { return "" }
        return text
    }

    @objc private func editTapped() {
        guard let document, hasFullAccess, ticket == nil, review == nil, !applying else { return }
        startInstruction(.edit, document: document)
    }

    private func replyTapped() {
        guard let document, hasFullAccess, ticket == nil, review != nil, !applying else { return }
        startInstruction(.review, document: document)
    }

    private func startInstruction(_ purpose: DictationPurpose, document: String) {
        guard alive else { localMessage = "Open TapType to reconnect."; refresh(); return }
        let next = DictationTicket(document: document, purpose: purpose)
        guard writeEditRequest(id: next.id, document: document, purpose: purpose) else { refresh(); return }
        KeyboardBridge.write(next.dictionary, to: "pending.json")
        KeyboardBridge.command("start", requestID: next.id, purpose: purpose)
        ticket = next; localMessage = nil
        playStartFeedback()
        refresh()
    }

    private func finishInstruction(_ ticket: DictationTicket, outcome: VoiceEditOutcome, document: String) {
        KeyboardBridge.command("clear", requestID: ticket.id)
        if state["microphoneActive"] as? Bool == false { KeyboardBridge.write([:], to: "state.json") }
        KeyboardBridge.write([:], to: "pending.json")
        self.ticket = nil
        localMessage = nil
        let request = editRequest?.id == ticket.id ? editRequest : VoiceEditRequest(KeyboardBridge.read("voice-edit-request.json"))
        switch outcome.kind {
        case .failed:
            localMessage = outcome.message
        case .undo:
            startUndoReview(document: document)
        case .command:
            if let command = outcome.command { handle(command) }
        case .suggestion:
            guard let request, request.id == ticket.id else { localMessage = "Couldn’t show that edit. Please try again."; return }
            switch VoiceEditPlanner.plan(outcome.changes, in: request.context.full, instruction: outcome.instruction,
                                         preferred: request.preferredRange) {
            case .success(let matches):
                review = Review(document: document, instruction: outcome.instruction, context: request.context,
                                matches: matches, included: Array(repeating: true, count: matches.count))
                playFinishFeedback()
            case .failure(let issue):
                localMessage = issue.message
            }
        }
    }

    private func handle(_ command: VoiceReviewCommand) {
        guard var review else { return }
        switch command {
        case .apply: applyReview()
        case .cancel:
            self.review = nil; localMessage = "Edit cancelled. Nothing changed."
        case .undo, .refine:
            localMessage = "Say “apply”, “cancel”, or what to change."
        case .showBefore: review.showBefore = true; self.review = review
        case .showAfter: review.showBefore = false; self.review = review
        case .applyOnly(let positions):
            let chosen = Set(VoiceReviewCommand.indexes(positions, count: review.matches.count))
            guard !chosen.isEmpty else { localMessage = "There are only \(review.matches.count) changes."; return }
            review.included = review.matches.indices.map { chosen.contains($0) }
            self.review = review
            applyReview()
        case .skip(let positions):
            for index in VoiceReviewCommand.indexes(positions, count: review.matches.count) { review.included[index] = false }
            self.review = review
            localMessage = review.included.contains(true) ? nil : "All changes skipped. Say “cancel”, or include one."
        }
    }

    /// Undo is shown for approval like any other edit.
    private func startUndoReview(document: String) {
        let saved = KeyboardBridge.read("voice-edit-undo.json")
        let changes = VoiceEditChange.list(saved["changes"])
        guard saved["document"] as? String == document, !changes.isEmpty else {
            localMessage = "There’s no edit to undo here."
            return
        }
        let context = currentContext()
        switch VoiceEditPlanner.plan(changes, in: context.full, instruction: "", trusted: true) {
        case .success(let matches):
            review = Review(document: document, instruction: "Undo", context: context, matches: matches,
                            included: Array(repeating: true, count: matches.count), isUndo: true)
        case .failure:
            localMessage = "Your text changed since that edit, so it can’t be undone."
        }
    }

    private func reviewStep(_ delta: Int) {
        guard var review, !review.matches.isEmpty else { return }
        review.index = (review.index + delta + review.matches.count) % review.matches.count
        review.showBefore = false
        self.review = review; refresh()
    }
    private func toggleIncluded() {
        guard var review else { return }
        review.included[review.index].toggle()
        self.review = review; refresh()
    }
    private func toggleCompare() {
        guard var review else { return }
        review.showBefore.toggle()
        self.review = review; refresh()
    }

    private var lastReviewRender = ""
    /// Draws the current change: removed words in red with a line through them, added
    /// words in green, and a little unchanged text around it in grey.
    private func renderReview() {
        guard let review, review.matches.indices.contains(review.index) else { return }
        let match = review.matches[review.index]
        let included = review.included[review.index]
        let key = "\(review.instruction)|\(review.index)|\(review.showBefore)|\(included)|\(review.matches.count)|\(dark)|\(applying)"
        guard key != lastReviewRender else { return }
        lastReviewRender = key
        let characters = Array(review.context.full)
        let radius = 70
        let from = max(0, match.start - radius), to = min(characters.count, match.end + radius)
        let prefix = (from > 0 ? "…" : "") + String(characters[from..<match.start])
        let suffix = String(characters[match.end..<to]) + (to < characters.count ? "…" : "")
        let pieces = VoiceEditDiff.pieces(from: match.change.original, to: match.change.replacement)
        let rewrite = VoiceEditDiff.changedFraction(pieces) > 0.6
        let base: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.label]
        let quiet = base.merging([.foregroundColor: UIColor.tertiaryLabel]) { $1 }
        let removed = base.merging([.foregroundColor: UIColor.systemRed, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: UIColor.systemRed, .backgroundColor: UIColor.systemRed.withAlphaComponent(0.12)]) { $1 }
        let added = base.merging([.foregroundColor: dark ? UIColor.systemGreen : UIColor(red: 0.05, green: 0.5, blue: 0.2, alpha: 1),
            .backgroundColor: UIColor.systemGreen.withAlphaComponent(0.18),
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold)]) { $1 }
        let text = NSMutableAttributedString(string: prefix, attributes: quiet)
        if review.showBefore {
            text.append(NSAttributedString(string: match.change.original, attributes: base))
        } else if rewrite {
            // A big rewrite would be unreadable word by word: show the new version, new words in green.
            for piece in pieces where piece.kind != .removed {
                text.append(NSAttributedString(string: piece.text, attributes: piece.kind == .added ? added : base))
            }
        } else {
            for piece in pieces {
                text.append(NSAttributedString(string: piece.text, attributes: piece.kind == .added ? added : piece.kind == .removed ? removed : base))
            }
        }
        text.append(NSAttributedString(string: suffix, attributes: quiet))
        reviewText.attributedText = text
        reviewText.alpha = included ? 1 : 0.45
        reviewText.setContentOffset(.zero, animated: false)
        let count = review.matches.count
        var header = review.isUndo ? "Undo · put back your earlier text" : count == 1 ? "1 change" : "Change \(review.index + 1) of \(count)"
        if review.showBefore { header += " · Before" } else if rewrite { header += " · New version" }
        if !included { header += " · Skipped" }
        reviewHeader.text = header
        reviewPrevious.isHidden = count < 2
        reviewNext.isHidden = count < 2
        reviewInclude.isHidden = count < 2
        setTitle(included ? "Skip" : "Include", of: reviewInclude, label: included ? "Skip this change" : "Include this change")
        setTitle(review.showBefore ? "After" : "Before", of: reviewCompare,
                 label: review.showBefore ? "Show the suggested change" : "Show the original text")
        for button in [reviewPrevious, reviewNext, reviewInclude, reviewCompare, replyButton] { button.isEnabled = !applying }
    }

    /// Writes the approved changes into the text field, after checking the text is still
    /// what was reviewed.
    private func applyReview() {
        guard let review, !applying, let document, document == review.document else { return }
        let chosen = zip(review.matches, review.included).filter(\.1).map(\.0)
        guard !chosen.isEmpty else { localMessage = "All changes are skipped."; refresh(); return }
        let now = currentContext()
        var located: [VoiceEditMatch]?
        // Usually nothing moved: every change is still at the same place relative to the cursor.
        let shift = now.cursor - review.context.cursor
        let nowCharacters = Array(now.full)
        let unchanged = chosen.allSatisfy { match in
            let start = match.start + shift, end = match.end + shift
            return start >= 0 && end <= nowCharacters.count && String(nowCharacters[start..<end]) == match.change.original
        }
        if unchanged { located = chosen.map { VoiceEditMatch(change: $0.change, start: $0.start + shift, end: $0.end + shift) } }
        else if case .success(let found) = VoiceEditPlanner.plan(chosen.map(\.change), in: now.full, instruction: "", trusted: true) {
            located = found
        }
        guard let located else {
            localMessage = "Your text changed since the suggestion. Say the edit again."
            self.review = nil; refresh(); return
        }
        applying = true; refresh()
        Task { @MainActor in
            let applied = await perform(located, in: now)
            applying = false
            if applied.isEmpty {
                localMessage = "Couldn’t change the text in this app. Nothing was changed."
            } else {
                if !review.isUndo {
                    KeyboardBridge.write(["document": document, "time": Date().timeIntervalSince1970,
                        "changes": VoiceEditPlanner.undo(for: applied, in: now.full).map(\.pair)], to: "voice-edit-undo.json")
                } else { KeyboardBridge.write([:], to: "voice-edit-undo.json") }
                let skipped = located.count - applied.count
                localMessage = skipped > 0 ? "Applied \(applied.count) of \(located.count). The rest couldn’t be placed."
                    : review.isUndo ? "Undone." : "Done. Say “undo” with the wand to put it back."
                playFinishFeedback()
            }
            self.review = nil
            refresh()
        }
    }

    /// Replaces each change in the host app's text, last one first so earlier positions
    /// don't move. Before deleting anything it checks the cursor really is at the end of
    /// the passage; if not, it stops. Returns the changes it made.
    private func perform(_ matches: [VoiceEditMatch], in context: VoiceEditContext) async -> [VoiceEditMatch] {
        let proxy = textDocumentProxy
        var text = Array(context.full)
        // With a selection, the cursor may count from either end of it.
        var cursors = [context.cursor]
        if !context.selected.isEmpty { cursors.append(context.cursor + context.selected.count) }
        var applied: [VoiceEditMatch] = []
        for match in matches.sorted(by: { $0.start > $1.start }) {
            guard await moveCursor(to: match.end, from: cursors, in: text) else { break }
            for _ in 0..<(match.end - match.start) { proxy.deleteBackward() }
            if !match.change.replacement.isEmpty { proxy.insertText(match.change.replacement) }
            text.replaceSubrange(match.start..<match.end, with: Array(match.change.replacement))
            cursors = [match.start + match.change.replacement.count]
            applied.append(match)
        }
        // Put the cursor back where it was, moved along with the text.
        if !applied.isEmpty {
            let target = VoiceEditPlanner.cursor(after: applied, from: context.cursor + context.selected.count)
            _ = await moveCursor(to: target, from: cursors, in: text)
        }
        return applied
    }

    private func moveCursor(to target: Int, from cursors: [Int], in text: [Character]) async -> Bool {
        let proxy = textDocumentProxy
        guard (0...text.count).contains(target) else { return false }
        for cursor in cursors {
            if cursor != target { proxy.adjustTextPosition(byCharacterOffset: target - cursor) }
            if await cursorSettles(at: target, in: text) { return true }
            // Some apps count UTF-16 units rather than characters (emoji, accents).
            let units = String(text[min(cursor, target)..<max(cursor, target)]).utf16.count * (target >= cursor ? 1 : -1)
            if units != target - cursor {
                proxy.adjustTextPosition(byCharacterOffset: units - (target - cursor))
                if await cursorSettles(at: target, in: text) { return true }
                proxy.adjustTextPosition(byCharacterOffset: -(units - (target - cursor)))
            }
            if cursor != target { proxy.adjustTextPosition(byCharacterOffset: cursor - target) }
            _ = await cursorSettles(at: cursor, in: text)
        }
        return false
    }

    /// Waits briefly for the host to report the new cursor, then checks the text on both
    /// sides of it matches what we expect at `position`.
    private func cursorSettles(at position: Int, in text: [Character]) async -> Bool {
        let expectedBefore = String(text[..<position]), expectedAfter = String(text[position...])
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(30)) }
            let before = textDocumentProxy.documentContextBeforeInput ?? ""
            let after = textDocumentProxy.documentContextAfterInput ?? ""
            let beforeMatches = before.isEmpty ? (expectedBefore.isEmpty || expectedBefore.hasSuffix("\n"))
                : expectedBefore.hasSuffix(before) || before.hasSuffix(expectedBefore)
            let afterMatches = after.isEmpty ? (expectedAfter.isEmpty || expectedAfter.hasPrefix("\n"))
                : expectedAfter.hasPrefix(after) || after.hasPrefix(expectedAfter)
            // Require some real evidence, not two empty strings in the middle of a paragraph.
            if beforeMatches && afterMatches && (before.count + after.count > 0 || text.isEmpty) { return true }
        }
        return false
    }

    private func rebuildKeys() {
        keys.cancelAll()
        keys.arrangedSubviews.forEach { keys.removeArrangedSubview($0); $0.removeFromSuperview() }
        if !numbers {
            addRow(Array("qwertyuiop").map(String.init))
            addRow(Array("asdfghjkl").map(String.init))
            let shift = key("", symbol: upper ? "shift.fill" : "shift", special: true) { [weak self] in self?.upper.toggle(); self?.refresh() }
            keys.addArrangedSubview(KeyRow([shift] + Array("zxcvbnm").map { letter(String($0)) } + [deleteKey()], style: .third))
        } else {
            addRow(symbols ? ["[","]","{","}","#","%","^","*","+","="] : Array("1234567890").map(String.init))
            addRow(symbols ? ["_","\\","|","~","<",">","€","£","¥","•"] : ["-","/",":",";","(",")","$","&","@","\""])
            let toggle = key(symbols ? "123" : "#+=", special: true) { [weak self] in self?.symbols.toggle(); self?.refresh() }
            keys.addArrangedSubview(KeyRow([toggle] + [".",",","?","!","'"].map { letter($0) } + [deleteKey()], style: .third))
        }
        let bottom = rowStack(); bottom.distribution = .fill
        let mode = key(numbers ? "ABC" : "123", special: true) { [weak self] in self?.numbers.toggle(); self?.refresh() }
        bottom.addArrangedSubview(mode)
        mode.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.20).isActive = true
        if needsInputModeSwitchKey {
            let globe = key("", symbol: "globe", special: true) { }
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            globe.accessibilityLabel = "Next keyboard"
            (globe as? KeyboardKey)?.passesTouches = true
            globe.isUserInteractionEnabled = true
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
    private func deleteKey() -> UIButton {
        let delete = key("", symbol: "delete.left", special: true) { [weak self] in self?.textDocumentProxy.deleteBackward() }
        (delete as? KeyboardKey)?.repeats = true
        delete.accessibilityLabel = "Delete"
        return delete
    }
    private func rowStack() -> UIStackView {
        let row = UIStackView(); row.axis = .horizontal; row.spacing = KeyRow.gap; row.distribution = .fillEqually; return row
    }
    private func addRow(_ letters: [String]) {
        keys.addArrangedSubview(KeyRow(letters.map { letter($0) }, style: .centered))
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
        // KeyTouchStack routes touches; the globe key re-enables this for itself.
        button.isUserInteractionEnabled = false
        return button
    }
}
