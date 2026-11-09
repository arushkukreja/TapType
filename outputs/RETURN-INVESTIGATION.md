# Current outcome — builds 51–53 (November 8, 2026)

Build 51's return-only diagnostic resolved Notes and completed one automatic return on
the physical iPhone 15 Pro running iOS 27.2. Recording was intentionally skipped. An
immediate second attempt did not have a usable fresh destination. Build 52 retained the
keyboard resolver's PID-to-bundle result for rapid reuse, after which the user described
the behavior as “great”; that response does not independently verify recording, final
insertion or a second automatic return.

Build 53 bounds that fallback mapping to less than eight monotonic seconds and prefers
a fresh current-state PID/bundle match. It also rejects `taptype://dictate` before any
microphone setup unless the URL matches the keyboard's fresh request/document marker.
Six focused unit tests and unsigned generic-iPhone Debug/Release builds pass. Generated
app and extension bundles all report build 53. The signed Debug app is installed and a
normal launch succeeded, but return behavior is not yet physically verified. The
equivalent iOS 27.2 Simulator still stalls before TapType runs.

The private return path remains DEBUG-only and is not an App Store-safe API. The older
investigation below is historical evidence explaining the discarded builds 45–49; its
“unresolved” status predates the later Build 51/52 device results.

# Physical return investigation — 2026-11-08

Status: automatic return remains unresolved on iPhone 15 Pro, iOS 27.2 (24B119).

## Evidence
- A return-only test skips recording, recognition, and cleanup. It still fails, ruling out audio/model startup as the immediate blocker.
- The original main-app `_UIRemoteKeyboards.currentState` observer is installed and receives events, but `sourceBundleIdentifier` is nil.
- The keyboard-side `_UIKeyboardArbiterClientInputDestination` hook installs with matching runtime signatures, but no destination event arrives during the tap query.
- The same raw hook in the main app receives an event but no source identity.
- URL `sourceApplication` is nil.
- Additional current-state fields (`hostBundleIdentifier`, `hostProcessIdentifier`, `sourceSceneIdentityString`, `sourceDisplayIdentifier`) are also nil or zero.
- The keyboard controller exposes the correct `_hostProcessIdentifier` for Notes. Its parent exposes zero. Resolving that process in the main app also fails: BSProcessHandle returns no bundle identifier; RBSProcessHandle returns RBSServiceErrorDomain/1. This was tested on the phone using the actual Notes process ID, not a guessed identifier.
- The existing app-opening operation has not yet been exercised with an automatically identified destination on this OS; no return fix is verified.

## Simulator
- Existing iOS 26.5 simulator returns using the original observer, so that result cannot verify physical iOS 27.2 compatibility.
- Installed general iOS 27.2 Simulator runtime 24B8117 and created an iPhone 15 Pro simulator.
- Also downloaded 24B91016s initially, but its profile restricts it to iPhone19,4; do not use it for the iPhone 15 Pro comparison.
- Both new simulator attempts stall in system startup before TapType is installed. General-runtime SpringBoard sample waits synchronously for BackBoardServices. Shut down the stalled simulator; no equivalent-version app test is complete.
- Host has Xcode 26.6 and macOS 26.4.1. No Xcode or macOS upgrade performed.

## Validation
- Signed iPhone diagnostic builds pass.
- 74 delivery/readiness/return-marker checks pass.
- 20 arbiter capture, callback forwarding, invalidation, timestamp and metadata checks pass. They validate our code against test doubles, not iOS callback delivery.

Do not label builds 45–49 as a verified return fix. Do not hard-code Notes, use stale cached identities, or use URL routes that open a new conversation.

## Outcome
Unsuccessful hooks, global arbiter-enabling changes, URL-source fallback, and extra runtime probes were removed from the app. Their source and logs remain in work for investigation. The previous build-44 source was restored; no microphone, speech, cleanup, sound, keyboard, model, credential, or transcript-history behavior was changed by the final source restoration. Restored build 44 passed its signed iPhone rebuild and all 64 retained delivery/readiness checks. Its source matches the existing source archive byte-for-byte. The restored app was installed; normal launch without diagnostic flags succeeded.

Apple's Developer Technical Support confirms there is no supported host-identification / automatic round-trip API for this keyboard flow: https://developer.apple.com/forums/thread/826851. That does not establish how closed-source competitors implement their own workaround, nor prove an OS update alone caused this regression.

The saved pre-streaming app source was built as a control, but an equivalent-OS A/B test could not run because the iOS 27.2 Simulator did not finish startup. No claim is made that simulator success verifies the phone.

## Current conclusion
- Apple DTS's current answer is that neither the keyboard extension nor its companion app has a public way to identify the app that hosted the keyboard. The related Apple request remains open with no promised release.
- Backgrounding the companion with `UIApplication.suspend()` is not a generic return path. For a companion launched by a keyboard extension, the system returns to the Home Screen rather than the original editor.
- `AudioRecordingIntent` is not an automatic-return API. Using it to avoid opening the companion would be a separate recording architecture and still needs a focused physical-device proof that a keyboard action can start TapType's general microphone pipeline in the app process. It is not a small verified fix for the existing handoff.
- Wispr Flow's current documentation confirms that its keyboard can request automatic return on iOS 27, with a per-recording confirmation, while also documenting app/account/OS-dependent failures and a manual-swipe fallback. This proves the experience remains achievable; it does not identify the implementation.
- KeyboardKit 10.9 also reports restored host-app resolution through a brand-new internal resolver that differs from its pre-iOS-26.4 implementation. KeyboardKit 11 isolates that sensitive code in `KeyboardKitHostPlugin`; Host App Utils is a commercial feature.
- TapType builds 45–49 tested the September open-source arbiter-hook approach, not KeyboardKit's later proprietary resolver. Physical logs show that TapType's hook installed and received `_UIKeyboardChangedInformation` callbacks, but those callbacks carried no usable external host identity on this phone. Repeating the same hook unchanged is not justified.
- Therefore build 50 remains unchanged pending either a focused capture of Wispr's successful handoff on this phone or evaluation of the current KeyboardKit host plugin. The reliable TapType fallback remains the system back-to-app control or a bottom-edge app switch; Keep ready avoids reopening TapType for later dictations during the selected readiness window.

Additional reference: https://github.com/KeyboardKit/KeyboardKit/issues/1014
Current KeyboardKit resolver: https://keyboardkit.com/blog/2026/08/27/keyboardkit-10-9
Wispr Flow return behavior: https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone
