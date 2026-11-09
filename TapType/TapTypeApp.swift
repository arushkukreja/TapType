import SwiftUI

@main
struct TapTypeApp: App {
    @UIApplicationDelegateAdaptor(TransitionAppDelegate.self) private var appDelegate
    init() {
        TransitionShield.shared.startObserving()
        if UserDefaults.standard.string(forKey: "speechProvider") == "openAILive" { UserDefaults.standard.set("apple", forKey: "speechProvider") }
        _ = DictationPerformance.shared
        #if DEBUG
        DevKeyboardReturn.shared.startObserving()
        if ProcessInfo.processInfo.arguments.contains("--file-benchmark") {
            Task { @MainActor in await PipelineChecks.fixtureBenchmark() }
        }
        if ProcessInfo.processInfo.arguments.contains("--pipeline-tests") {
            Task { @MainActor in await PipelineChecks.run(); await IntegrationChecks.costs() }
        }
        if ProcessInfo.processInfo.arguments.contains("--handoff-report") {
            setbuf(stdout, nil)
            print("HANDOFF_REPORT: \(KeyboardBridge.read("return-status.json"))")
            print("CUE_REPORT: \(KeyboardBridge.read("cue-status.json"))")
        }
        if ProcessInfo.processInfo.arguments.contains("--latency-report") {
            setbuf(stdout, nil)
            print("CHECKMARK_TIMINGS_SECONDS: \(DictationLatency.measurements)")
        }
        #endif
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class TransitionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Cold-launch URLs are available here before ContentView or onOpenURL.
        if options.urlContexts.contains(where: { $0.url.host == "dictate" }) {
            TransitionShield.shared.beginHandoff()
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = TransitionSceneDelegate.self
        return configuration
    }
}

final class TransitionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if options.urlContexts.contains(where: { $0.url.host == "dictate" }) {
            TransitionShield.shared.beginHandoff()
        }
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if contexts.contains(where: { $0.url.host == "dictate" }) {
            TransitionShield.shared.beginHandoff()
        }
    }
}

// SwiftUI's scenePhase update can be rendered after UIKit has captured its
// app-switching snapshot. Cover the actual window synchronously at the scene
// boundary, before that snapshot, and keep it covered during URL handoffs.
@MainActor
final class TransitionShield: NSObject {
    static let shared = TransitionShield()
    private weak var window: UIWindow?
    private let cover = UIView()
    private var observing = false
    private var covered = true
    private(set) var handoffPending = false
    private var handoffReachedForeground = false

    override init() {
        super.init()
        cover.backgroundColor = .black
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.accessibilityViewIsModal = true
        cover.layer.zPosition = 10_000
        let logo = UIImageView(image: UIImage(systemName: "waveform",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .semibold)))
        logo.tintColor = .white
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.isAccessibilityElement = true
        logo.accessibilityLabel = "TapType, getting ready"
        cover.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 56),
            logo.heightAnchor.constraint(equalToConstant: 56)
        ])
    }

    func startObserving() {
        guard !observing else { return }
        observing = true
        if KeyboardBridge.hasRecentHandoff { beginHandoff() }
        for name in [UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification,
                     UIScene.willEnterForegroundNotification,
                     UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneTransition), name: name, object: nil)
        }
    }

    @objc private func sceneTransition(_ notification: Notification) {
        if let scene = notification.object as? UIWindowScene,
           let window, scene !== window.windowScene { return }
        if notification.name == UIScene.didActivateNotification {
            if handoffPending { handoffReachedForeground = true }
            return
        }
        // Only a real UIKit foreground -> background departure ends a handoff.
        // SwiftUI may report an initial .background during cold launch; that is
        // not evidence that the return to the user's app has finished.
        if notification.name == UIScene.didEnterBackgroundNotification && handoffReachedForeground {
            handoffPending = false
            handoffReachedForeground = false
        }
        show()
    }

    func beginHandoff() {
        handoffPending = true
        handoffReachedForeground = handoffReachedForeground || UIApplication.shared.applicationState == .active
        show()
    }

    func allowExplicitHome() {
        handoffPending = false
        handoffReachedForeground = false
    }

    func attach(to window: UIWindow) {
        self.window = window
        if covered { show() }
    }

    func show() {
        covered = true
        guard let window else { return }
        UIView.performWithoutAnimation {
            cover.frame = window.bounds
            if cover.superview !== window { window.addSubview(cover) }
            window.bringSubviewToFront(cover)
            cover.isHidden = false
            cover.layoutIfNeeded()
        }
    }

    func revealForeground(isFallback: Bool = false) {
        guard let state = window?.windowScene?.activationState,
              state == .foregroundActive || (isFallback && state == .foregroundInactive) else { return }
        guard isFallback || !handoffPending else { return }
        covered = false
        cover.isHidden = true
    }
}

// Updates happen with the SwiftUI render transaction: removing the native cover
// exposes either the committed home view or the committed black fallback view.
struct TransitionShieldAnchor: UIViewRepresentable {
    let covered: Bool
    let isFallback: Bool
    final class Anchor: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { TransitionShield.shared.attach(to: window) }
        }
    }
    func makeUIView(context: Context) -> Anchor { Anchor() }
    func updateUIView(_ uiView: Anchor, context: Context) {
        if let window = uiView.window { TransitionShield.shared.attach(to: window) }
        if covered { TransitionShield.shared.show() }
        else { TransitionShield.shared.revealForeground(isFallback: isFallback) }
    }
}

