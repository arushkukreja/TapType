# TapType

<p align="center">
  <img src="outputs/TapType-app-icon.png" width="112" alt="TapType app icon">
</p>

<p align="center"><b>Private AI dictation keyboard for iPhone.</b><br>
Tap, talk, and your words land in any app. Runs on-device by default.</p>

TapType is a custom iOS keyboard that turns speech into clean text. Tap the
TapType button, speak, then tap ✓. Your words are transcribed, optionally
cleaned up, and inserted into whatever text field you're in: Messages, Mail,
Notes, Slack, or a prompt box.

By default everything runs on Apple's on-device speech and writing models, so
your voice and words stay on your iPhone and there's nothing extra to download.
Local Whisper models and cloud providers (OpenAI, Groq) are optional.

> [!NOTE]
> TapType is a personal project and working prototype, not an App Store
> release. To use it, build and install it from Xcode (see
> [Build and install](#build-and-install)).

## Features

- **Works in any app.** A full custom keyboard (letters, numbers, symbols) with
  a TapType dictation button, ✓ to finish, and × to cancel.
- **On-device by default.** Apple SpeechAnalyzer for streaming transcription and
  Apple Foundation Models for cleanup when Apple Intelligence is available.
- **Choose your speech model:**
  - Apple Speech (on-device, default)
  - Whisper Base or Whisper Small (downloadable, on-device, English)
  - OpenAI or Groq (cloud, opt-in, using your own API key)
- **Choose your output:** Original, Clean up (removes filler words), or Rewrite
  (improves phrasing). If cleanup fails, your original words are kept.
- **Keep ready.** Leave the mic ready between dictations for 1, 2, 3, 5, or
  10 minutes, until you end it, or turn it off. Idle audio is discarded.
- **History and stats.** Total words, number of dictations, and every original
  transcript with timestamps, stored only on your phone.
- **Live Activity and Dynamic Island** status while dictating.
- **Cloud cost estimates** based on submitted audio or token usage, if you use
  a cloud provider.

## How it works

1. Switch to the TapType keyboard in any app (hold the 🌐 key).
2. Tap **TapType** and speak.
3. Tap **✓** to transcribe, clean up if selected, and insert the text.
4. Or tap **×** to cancel without inserting anything.

## Speed

Measured on an iPhone 15 Pro with Apple Speech and on-device cleanup, text was
ready about 0.5 to 1.4 seconds after tapping ✓. These are observed samples, not
guarantees. Details are in [STREAMING-PERFORMANCE.md](outputs/STREAMING-PERFORMANCE.md).

## Models

| Model | Used for | Where it runs |
| --- | --- | --- |
| Apple Speech | Streaming transcription | On device (default) |
| Whisper Base / Small (English) | Transcription | On device, after download |
| Apple Foundation Models | Clean up and Rewrite | On device (needs Apple Intelligence) |
| OpenAI | Transcription and cleanup | Cloud, opt-in |
| Groq (`whisper-large-v3-turbo` by default) | Transcription and cleanup | Cloud, opt-in |

## Privacy

- The microphone starts only after you tap TapType.
- Idle Keep ready audio is discarded before any transcription or networking.
- Raw microphone audio is never saved to disk.
- On-device models never upload your audio.
- Cloud providers receive data only if you select them. While a cloud model is
  selected, completed phrases are sent as you speak.
- OpenAI and Groq API keys are stored as device-only Keychain items in the
  companion app, not in the keyboard extension or shared storage.
- Transcript history stays in the app's private container, uses file
  protection, and is excluded from device backups.
- The keyboard needs **Allow Full Access** so it can exchange dictation commands
  and text with the companion app through an App Group.

## Requirements

- iPhone running iOS 26 or later (developed and tested on an iPhone 15 Pro)
- Apple Intelligence for on-device Clean up and Rewrite (optional)
- Mac with Xcode 26.6 or newer
- An Apple developer account for device signing
- OpenAI or Groq API key (optional, for cloud models)

## Web version

`web/` holds a browser version of TapType: tap the mic (or press Space), speak,
tap ✓, and the cleaned-up text is copied for you to paste anywhere. It's static
files with no build step and uses the same cleanup rules and safety checks as the
iOS app (`web/cleanup.js` is a port of `LocalTextProcessor.swift`).

- **Speech:** the browser's own recognition (Chrome, Edge, Safari), or OpenAI / Groq
  with your own key. Browser speech runs on-device only where the browser supports
  it; otherwise it goes to the browser maker's speech service.
- **Writing:** rules only (removes um, uh and stutters), Chrome's built-in on-device
  AI, or OpenAI / Groq.
- API keys and history are kept in the browser's local storage.

Run it locally (microphone access needs `localhost` or HTTPS):

```bash
python3 -m http.server 4173 --directory web
```

Tests: `node --test web/cleanup.test.mjs`

## Build and install

1. Clone the repository.
2. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and set your
   Apple Developer Team ID and a bundle ID you own. This file is gitignored.
3. Register an App Group named `group.<your bundle ID>` in your Apple Developer
   account (or let Xcode's automatic signing create it).
4. Open `TapType.xcodeproj`, select the `TapType` scheme, and run on a physical
   iPhone.
5. On your iPhone, go to **Settings → General → Keyboard → Keyboards → Add New
   Keyboard**, add TapType, and turn on **Allow Full Access**.

## Known limitations

- Secure fields (like passwords) and apps that block third-party keyboards fall
  back to the system keyboard.
- No autocorrect, predictive text, or swipe typing.
- Whisper models are English-only, and downloads require the app to stay open.
- Cloud usage numbers are local estimates, not provider bills.
- Cleanup is conservative but can't guarantee perfect meaning preservation. Use
  Original mode to skip it.

## Roadmap

- Custom vocabulary and phrases
- More writing styles
- Tone that adapts to who you're writing to

Ideas, feedback, and issues are welcome.

## Project structure

```text
TapType/       Companion app: speech, cleanup, models, history, and costs
Keyboard/      UIKit custom keyboard
Shared/        App and keyboard communication
LiveActivity/  Dynamic Island and Live Activity
Tests/         Shared-logic tests (run with `swift test`)
outputs/       Development notes, test reports, and screenshots
```

## Development notes

- Automatic return to the app that opened the keyboard is a DEBUG-only
  experiment built on private iOS APIs (`TapType/DevKeyboardReturn.swift`). It is
  fragile, not App Store compatible, and compiled out of Release builds. Use
  iOS's back-to-app control instead.
- Microphone capture, keyboard behavior, insertion, and haptics need testing on
  a physical device. The app also includes DEBUG-only pipeline checks.
- More detail: [Test status](outputs/TEST-STATUS.md),
  [Code review](outputs/CODE-REVIEW.md),
  [Automatic-return investigation](outputs/RETURN-INVESTIGATION.md).

## Attribution

The development-only return observer adapts an MIT-licensed approach from
[OpenWhispr](https://github.com/OpenWhispr/openwhispr). WhisperKit and bundled
dependency notices are in `TapType/Licenses.txt`. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

TapType is an independent project and is not affiliated with Apple, OpenAI,
Groq, Wispr Flow, Granola, or Handy.

## License

TapType is released under the [MIT License](LICENSE). Third-party components
are covered by their own licenses, listed in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and `TapType/Licenses.txt`.
