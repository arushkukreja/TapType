Build 28 update: readiness is now a duration menu (Off, 1/2/3/5/10 minutes, Until I end it), default five. The logo is automatic. Model downloads are searchable within the existing verified catalog. Model integrations below are unchanged.

# TapType models — implemented in build 27

The native SwiftUI home page now has separate speech and writing choices. Apple is
the default for both. Original bypasses writing; Clean up and Rewrite reuse the
existing original-transcript fallback and meaning checks.

| Stage | Choices | Where processing occurs |
|---|---|---|
| Speech | Apple Speech | iPhone, English US |
| Downloaded speech | Whisper Base English, 149.1 MB; Whisper Small English, 488.9 MB | iPhone after download |
| Cloud speech | OpenAI `gpt-transcribe`; Groq `whisper-large-v3-turbo` | Selected provider, only after ✓ |
| Writing | Apple Foundation Models | iPhone with Apple Intelligence available |
| Cloud writing | OpenAI `gpt-6-luna`; Groq `llama-3.3-70b-versatile` | Selected provider receives transcript text |

Cloud model IDs can be edited in the provider sheet. API keys use device-only
Keychain storage; they never enter the keyboard App Group. Requests use fixed HTTPS
provider hosts, ephemeral sessions, no cookies/cache, and reject redirects. Test
connection reads the provider's model list without sending audio or dictation text.
A successful connection check does not guarantee access to every model or available quota.

WhisperKit is pinned to 1.1.1 (`1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`).
Model weights come from argmaxinc/whisperkit-coreml revision
`0f63a7800b00dd0226abd051b906c246e1907482` (MIT). The English tokenizer comes from
openai/whisper-base.en revision `911407f4214e0e1d82085af863093ec0b66f9cd6`
(Apache-2.0). Every bundled manifest entry has a pinned URL, byte count and SHA-256.

Downloads stage files and verify each one before installation. Cancel/retry retains
completed verified files; incomplete files restart. Removal switches a selected
model back to Apple. Model storage is excluded from device backup. Keep the app open
while downloading: background downloads and byte-level resumption are not implemented.
The tokenizer is validated from local files before inference; automatic model
fetching is disabled. There is no automatic cloud fallback.

Microphone ownership remains separate from providers. Build 27 restores five-minute active-input readiness per the user’s request.
Idle audio is discarded before buffering or transcription; finish/cancel retains input
only while readiness is enabled. Manual end, expiry, errors and interruptions release it. Explicit start
snapshots the providers and begins a new clip. ✓ detaches it, resamples to mono 16 kHz,
and runs the selected speech and writing stages. × discards/cancels it. Requests keep
the existing ticket, original-field and insert-once protections. Raw audio is not saved
to disk. At the 55-second limit, downloaded/cloud clips await ✓ for up to 20 seconds;
the time limit itself cannot upload them.

Still separate work: downloaded writing LLMs, multilingual selection, custom API
URLs, saved-audio retry, dictionaries/snippets, Action Button/App Intents, and native-grade
keyboard autocorrection/swipe typing. These are not presented as working options.

## Differences from Wispr Flow

Flow documents broader language, dictionary, snippets/history and shortcut features.
TapType currently offers explicit local/cloud model control and timestamped original-text
history, but has a shorter 55-second recording limit and no persistent audio history. Flow's documented iOS
limit is five minutes. Its auto-stop countdown also depends on background/keyboard
activity, while TapType uses a strict five minutes from the end of each dictation.

Flow distinguishes its Live Activity pill from iOS's microphone indicator; its pill
can persist after microphone release. Its exact background implementation cannot be
established from that visual alone. TapType now keeps idle input active when readiness is enabled; its branded Live Activity is optional. The iOS microphone-use
indicator remains system-controlled.

Notes cold-return keyboard resizing is still unresolved. Warm ready sessions avoid
repeat launches; after expiry or interruption, starting may require another app switch.
Automatic return remains a DEBUG-only private-API experiment, not an App Store-ready
promise of cursor restoration in every app.

Sources: [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift),
[OpenAI speech](https://developers.openai.com/api/docs/guides/speech-to-text),
[Groq speech](https://console.groq.com/docs/speech-to-text),
[Groq writing](https://console.groq.com/docs/text-chat),
[Flow session/indicator guide](https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios),
[Flow navigation](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android),
[Apple microphone indicator](https://support.apple.com/en-la/108331).
