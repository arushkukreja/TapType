#if DEBUG
import UIKit
import ObjectiveC.runtime

// Development-only experiment based on OpenWhispr's HostAppObserver.
// Uses an undocumented UIKit implementation detail. Excluded from Release.
// See THIRD-PARTY-NOTICES.md for the source and MIT license.
@MainActor
final class DevKeyboardReturn: NSObject {
    static let shared = DevKeyboardReturn()
    private var observedObject: NSObject?
    private var latestHost: (bundle: String, time: Date)?
    private var attempt = UUID()
    private var returnTarget: (id: String, bundle: String, created: Date)?
    private var startupTarget: (id: String, bundle: String)?

    // Development-only LaunchServices experiment. Resume the host directly so
    // its URL handler doesn't open/rebuild an editor or compose screen. Runtime
    // availability/signature checked. No URL fallback: it can open a different
    // editor, conversation or page instead of restoring the existing app.
    private func resumeHost(_ observedBundle: String) -> Bool {
        let bundle = HostReturnIdentity.registeredCase(observedBundle)
        var accepted = false
        defer { reportReturn(source: observedBundle, resolved: bundle, accepted: accepted) }
        guard let type = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              type.responds(to: NSSelectorFromString("defaultWorkspace")),
              let workspace = type.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject else {
            return false
        }
        let selector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: selector),
              let method = class_getInstanceMethod(type, selector), method_getNumberOfArguments(method) == 3 else { return false }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard ["B", "c"].contains(String(cString: returnType)) else { return false }
        typealias OpenApp = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let open = unsafeBitCast(method_getImplementation(method), to: OpenApp.self)
        guard let argumentType = method_copyArgumentType(method, 2) else { return false }
        defer { free(argumentType) }
        guard String(cString: argumentType).hasPrefix("@") else { return false }
        accepted = open(workspace, selector, bundle as NSString)
        return accepted
    }

    private func reportReturn(source: String, resolved: String, accepted: Bool) {
        var attempts = KeyboardBridge.read("return-status.json")["attempts"] as? [[String: Any]] ?? []
        attempts.append(["source": source, "resolved": resolved, "accepted": accepted,
                         "time": Date().timeIntervalSince1970])
        KeyboardBridge.write(["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                              "attempts": Array(attempts.suffix(8))], to: "return-status.json")
        NSLog("TapType dev return: source=%@ resolved=%@ accepted=%d", source, resolved, accepted)
    }

    func testResumeHost(_ requested: String?) {
        let host = requested ?? "com.apple.MobileSMS"
        print("RESUME_HOST: accepted=\(resumeHost(host))")
    }

    func startObserving() {
        guard observedObject == nil,
              let type = NSClassFromString("_UIRemoteKeyboards") as? NSObject.Type else { return }
        let shared = NSSelectorFromString("sharedRemoteKeyboards")
        guard type.responds(to: shared),
              let object = type.perform(shared)?.takeUnretainedValue() as? NSObject,
              object.responds(to: NSSelectorFromString("currentState")) else { return }
        observedObject = object
        object.addObserver(self, forKeyPath: "currentState", options: [.initial, .new], context: nil)
        NSLog("TapType dev return: observer ready")
    }

    func captureDestination(requestID: String, document: String, since began: Date) {
        let marker = KeyboardBridge.read("keyboard-host.json")
        KeyboardBridge.write([:], to: "keyboard-host.json")
        startupTarget = HostReturnIdentity.keyboardHost(marker, requestID: requestID, document: document,
            own: Bundle.main.bundleIdentifier ?? "").map { (requestID, $0) }
        NSLog("TapType dev return: keyboard destination=%@", startupTarget?.bundle ?? "none")
        // Do not re-date currentState: it may still describe a previous app.
        if startupTarget == nil, let host = latestHost, host.time >= began.addingTimeInterval(-1) {
            startupTarget = (requestID, host.bundle)
        }
        let hostAge: Double = latestHost.map { Date().timeIntervalSince($0.time) } ?? -1.0
        NSLog("TapType dev return: capture tapAge=%.3f host=%@ hostAge=%.3f", Date().timeIntervalSince(began), latestHost?.bundle ?? "none", hostAge)
    }

    nonisolated private static func sourceBundle(_ state: NSObject) -> String? {
        let selector = NSSelectorFromString("sourceBundleIdentifier")
        guard state.responds(to: selector) else { return nil }
        return state.perform(selector)?.takeUnretainedValue() as? String
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
        change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "currentState", let state = change?[.newKey] as? NSObject else { return }
        NSLog("TapType dev return: state class=%@ source=%@ getter=%d", NSStringFromClass(type(of: state)), Self.sourceBundle(state) ?? "none", state.responds(to: NSSelectorFromString("sourceBundleIdentifier")))
        guard let bundle = Self.sourceBundle(state) else { return }
        let time = Date()
        Task { @MainActor in
            guard let destination = HostReturnIdentity.externalHost(bundle, own: Bundle.main.bundleIdentifier ?? "") else { return }
            self.latestHost = (destination, time)
            NSLog("TapType dev return: observed host=%@", destination)
        }
    }

    func returnAfterStart(since began: Date, requestID: String? = nil, stillDictating: () -> Bool) async {
        let token = UUID()
        attempt = token
        returnTarget = nil
        let captured = startupTarget.flatMap { $0.id == requestID ? $0.bundle : nil }
        startupTarget = nil
        let deadline = Date().addingTimeInterval(2)
        var becameActive = false
        var foregroundSettlesAt: Date?
        while Date() < deadline {
            guard token == attempt, !Task.isCancelled, stillDictating() else {
                NSLog("TapType dev return: abandoned")
                return
            }
            // onOpenURL can arrive before the incoming scene becomes active.
            // Wait for that transition, but never reopen another app after the
            // user leaves or backgrounds an already-active dictation screen.
            guard UIApplication.shared.applicationState == .active else {
                if becameActive { return }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            becameActive = true
            // didBecomeActive can precede completion of the incoming system
            // animation. Let it settle on the logo before asking iOS to return,
            // avoiding overlapping transitions and a host-keyboard resize flash.
            if foregroundSettlesAt == nil { foregroundSettlesAt = Date().addingTimeInterval(0.65) }
            if Date() < foregroundSettlesAt! {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            let fresh = latestHost.flatMap { $0.time >= began.addingTimeInterval(-1) ? $0.bundle : nil }
            if let host = captured ?? fresh {
                latestHost = nil
                if let requestID { returnTarget = (requestID, host, Date()) }
                // One direct-resume request only. A scheme fallback can invoke a
                // compose/new-document route, so failures remain on TapType with
                // its existing manual-return guidance.
                if let requestID {
                    KeyboardBridge.write(["id": requestID, "time": Date().timeIntervalSince1970], to: "keyboard-return.json")
                }
                if resumeHost(host) {
                    NSLog("TapType dev return: resumed existing host")
                    return
                }
                NSLog("TapType dev return: resume refused; manual return")
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        KeyboardBridge.write(["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                              "reason": "No destination observed", "time": Date().timeIntervalSince1970], to: "return-status.json")
        NSLog("TapType dev return: no fresh destination; manual return")
    }

    func returnAfterFinish(requestID: String) async {
        guard let target = returnTarget, target.id == requestID,
              Date().timeIntervalSince(target.created) < 600,
              UIApplication.shared.applicationState == .active else { return }
        returnTarget = nil
        _ = resumeHost(target.bundle)
    }
}
#endif
