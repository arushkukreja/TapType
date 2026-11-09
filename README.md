# TapType

<p align="center">
  <img src="outputs/TapType-app-icon.png" width="112" alt="TapType app icon">
</p>

TapType is an experimental native iPhone dictation keyboard. Tap the TapType
button, speak, then tap ✓ to transcribe, optionally clean up, and insert the
result once into the active text field.

The project combines a SwiftUI companion app, a UIKit custom keyboard, a Live
Activity, on-device speech and writing models, downloadable Whisper models,
and optional OpenAI or Groq providers.

> [!IMPORTANT]
> TapType is a development prototype, not an App Store release. Automatic
> return to the originating app is a DEBUG-only experiment built on private
> iOS APIs. It is not reliable, is excluded from Release builds, and must not
> be treated as an App Store-supported feature.

## Current status

- Current development build: **57**
- Deployment target: **iOS 26 or later**
- Primary physical test device: iPhone 15 Pro on iOS 27.2
- Debug and Release device builds compile with Xcode 26.6
- Build 57 is installed and launches on the physical device
- The iOS 27.2 Simulator currently stalls during system startup, so there is
  no equivalent-version simulator pass

The latest detailed evidence and open limitations are in
[TEST-STATUS.md](outputs/TEST-STATUS.md). Historical entries in that file are
retained for traceability; the newest entry and current source take precedence.

## Features

- Native custom keyboard with letters, numbers, symbols, pressed-key feedback,
  a TapType dictation action, ✓ to finish, and × to cancel
- Apple SpeechAnalyzer/SpeechTranscriber streaming transcription
- Apple Foundation Models cleanup when Apple Intelligence is available
- Downloadable Whisper Base and Small models for local English transcription
- Optional OpenAI and Groq speech and writing models using the user's API keys
- Original, Clean up, and Rewrite modes
- Ordered, exactly-once transcript insertion
- Local original-transcript history with timestamps and word counts
- Configurable Keep ready microphone window
- Live Activity and Dynamic Island status
- Local cloud-cost estimates based on submitted audio or returned token usage
- Start, finish, and cancel haptics; start and successful-insertion sounds play
  through the media audio path

## How dictation works

1. Select the TapType keyboard in another app.
2. Tap **TapType**.
3. Speak while the keyboard shows its listening waveform.
4. Tap **✓** to finish, transcribe, clean up if selected, and insert once.
5. Tap **×** instead to cancel without insertion.

There is no separate Insert button and no live transcript preview in the
keyboard. While processing, the keyboard shows an animated TapType logo.

## Speech and writing choices

| Choice | Purpose | Processing location |
| --- | --- | --- |
| Apple Speech | Streaming transcription | On device |
| Whisper Base / Small | Phrase transcription | On device |
| OpenAI | Streaming transcription or cleanup | Cloud, opt-in |
| Groq | Phrase transcription or cleanup | Cloud, opt-in |
| Apple Foundation Models | Cleanup or rewrite | On device |

OpenAI streaming sends all audio captured during an explicit dictation,
including pauses. Keep ready audio outside an active dictation is discarded
locally and is not encoded, stored, or uploaded.

## Privacy and security

- The microphone starts only after an explicit TapType dictation request.
- Idle Keep ready buffers are discarded before transcription or networking.
- Raw microphone audio is not saved to disk.
- Selecting an on-device speech model does not upload dictated audio.
- Cloud providers are optional and receive data only when selected.
- OpenAI and Groq keys are stored as device-only Keychain items in the companion
  app. They are not stored in the repository, App Group, or keyboard extension.
- Original transcript history stays in the app's private container, uses file
  protection, and is excluded from device backup.
- The custom keyboard requests **Allow Full Access** because the companion app
  and extension communicate through an App Group. Review this requirement
  before using or distributing the keyboard.

The repository does not contain the developer's runtime Keychain, transcript
history, microphone recordings, or cloud-usage database.

## Requirements

- macOS with Xcode 26.6 or a compatible newer Xcode
- iPhone running iOS 26 or later
- An Apple developer team for device signing
- A registered App Group shared by the app and keyboard extension
- Optional Apple Intelligence for on-device writing cleanup
- Optional OpenAI or Groq account and API key for cloud models

## Build and install

1. Clone the repository.
2. Open `TapType.xcodeproj`.
3. Update `DEVELOPMENT_TEAM` and `TAPTYPE_BUNDLE_ID` in the project settings.
4. Register an App Group for the new bundle ID.
5. Update the literal App Group in `TapType/Shared.entitlements` so it matches
   `TAPTYPE_APP_GROUP`.
6. Select the `TapType` scheme and run on a physical iPhone.
7. On the phone, add TapType under **Settings → General → Keyboard → Keyboards**
   and enable **Allow Full Access**.

The committed project contains the original developer Team ID, bundle ID, and
App Group identifier for reproducible local development. They are identifiers,
not signing credentials, and another developer must replace them.

## Verification

Run the committed Swift package tests:

```sh
swift test
```

The app also contains DEBUG-only pipeline and fixture checks. Physical-device
testing is still required for microphone capture, custom-keyboard behavior,
insertion, haptics, audio cues, and app switching.

Build 57's quiet-speech regression test ran on the physical phone. Twenty
seconds of audio kept below the former local upload threshold produced two
confirmed OpenAI turns totaling 20 seconds and finalized 50 words. One normal
quiet microphone dictation remains the final real-acoustic check.

See also:

- [Code review](outputs/CODE-REVIEW.md)
- [Test status](outputs/TEST-STATUS.md)
- [Automatic-return investigation](outputs/RETURN-INVESTIGATION.md)
- [Streaming performance notes](outputs/STREAMING-PERFORMANCE.md)
- [Third-party notices](THIRD-PARTY-NOTICES.md)

## Known limitations

- Automatic return uses private APIs in DEBUG and can fail after any iOS update.
  Release builds exclude this experiment. Use iOS's back-to-app control or an
  edge swipe when automatic return is unavailable.
- Secure fields and apps that disable third-party keyboards fall back to the
  system keyboard.
- The keyboard does not provide autocorrect, predictive text, or swipe typing.
- Downloadable Whisper models are English-only in this version.
- Model downloads require the app to remain open.
- Cloud usage values are local estimates, not a provider billing statement.
- Cleanup validation is conservative but cannot guarantee perfect preservation
  of meaning. Original mode bypasses writing cleanup.

## Project structure

```text
TapType/       Companion app, speech, cleanup, models, history, and costs
Keyboard/      UIKit custom keyboard
Shared/        App/keyboard communication and delivery state
LiveActivity/  Dynamic Island and Live Activity presentation
Tests/         Focused shared-logic tests
outputs/       Historical test reports and development screenshots
```

## Private-API development experiment

`TapType/DevKeyboardReturn.swift` and DEBUG sections of
`Keyboard/KeyboardViewController.swift` inspect undocumented UIKit and
LaunchServices behavior to investigate return to the app that opened the
keyboard. These calls are fragile, are not an App Store contract, and are
compiled out of Release. The Release binaries were checked for the relevant
private selector strings after Build 57.

## Attribution

The development-only return observer adapts an MIT-licensed approach from
[OpenWhispr](https://github.com/OpenWhispr/openwhispr). WhisperKit and bundled
dependency notices are included in `TapType/Licenses.txt`. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for details.

TapType is an independent development prototype. It is not affiliated with
Handy, Wispr Flow, OpenAI, Groq, or Apple.

## License

A project-level license has not yet been selected. Public repository visibility
does not grant permission to copy, modify, or redistribute TapType. Third-party
components remain governed by their own licenses and notices.
