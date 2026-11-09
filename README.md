# TapType — development build 57

A native iPhone app, voice keyboard, and Dynamic Island Live Activity. Inspired by
Handy's simple dictation interaction and the supplied Wispr keyboard references.
Apple Speech is the default. You can also download Whisper Base or Small for local
English transcription, or use OpenAI/Groq with your own API key. Writing is a separate
choice: Apple Foundation Models, OpenAI, or Groq. Original skips the writing stage.

## Home screen

One native SwiftUI Form with Speech model, Your words, and Writing model menus.
Centered word and dictation totals count saved original transcripts and appear above Keep ready. Speech and Writing
show only model names and only available choices. On-device models expands inline with
Get, download progress, Cancel and a native Uninstall action. Cloud providers has a
chevron and opens secure API-key entry, connection testing and editable model names.
Done validates and saves model/key edits; Back discards uncommitted edits.
Setup and FAQs stay collapsed. There is no scratchpad or test section. While dictating,
the companion keeps its normal home screen: no live transcript, waveform, recording
actions, or End session button. The keyboard retains its listening waveform, processing logo and ✓/×.
Keep ready → Off releases idle input.

Download sizes: Base 149.1 MB; Small 488.9 MB. Keep the app open for downloads.
Files are pinned to a model revision and checked by size and SHA-256. Retrying keeps
verified completed files; it restarts an incomplete file. Downloads are excluded from
backup. Both models are English-only in this version and run locally after download.
Apple remains selected until you change the picker. Missing models cannot be selected.

For cloud use, enter your key under Cloud providers and tap Done, test the connection, then select
that provider in Speech model and/or Writing model. Keys are device-only Keychain
items in the main app, never shared with the keyboard. Provider usage charges and
privacy terms apply. Connection testing sends no dictated audio or transcript.
OpenAI defaults: gpt-transcribe / gpt-6-luna. Groq defaults:
whisper-large-v3-turbo / llama-3.3-70b-versatile. Model names can be edited as provider
availability changes. Existing saved model names remain unchanged. No custom API base
URLs or silent cloud fallback are supported.

## Streaming transcription (build 34)

Requires iOS 26 or later. Apple Speech uses SpeechAnalyzer and SpeechTranscriber with
volatile results and audio timestamps. Download Apple Speech under On-device models
if iOS has not installed its assets. Foundation Models requires a supported device
with Apple Intelligence enabled and ready; otherwise cleanup preserves the raw text.

| Speech choice | During dictation | Where it runs |
| --- | --- | --- |
| Apple Speech | Volatile recognition stays internal; finalized phrases are queued | On device |
| OpenAI configured transcription model | Continuous PCM upload; VAD commits phrases, then provider partial/final results | Cloud |
| Whisper Base / Small | Completed audio phrases decoded while capture continues | On device |
| Groq | Completed audio phrases uploaded while capture continues | Cloud |

The expensive `gpt-live-transcribe` option is removed and blocked in settings. Its
previous selection migrates to Apple Speech. Existing keys, downloads, transcripts,
usage history and other model selections remain intact. Batch-only models cannot
produce word-by-word results before a phrase completes; their streaming-first path
processes phrases during recording instead of waiting for the whole recording.

Raw, volatile, finalized and refined text remain separate. Only finalized phrases
are queued for cleanup, using sentence/VAD boundaries. One serial cleanup worker
streams Foundation Models or selected cloud writing output into an internal draft. It
prewarms a fresh Apple session, uses bounded read-only context, and reprocesses an
adjacent explicit correction together with its preceding phrase. IDs and audio
ranges prevent stale edits, duplicate phrases and out-of-order responses. Cleanup
that fails validation retains the original phrase. Model edits still need review.

✓ stops capture, finalizes speech, drains queued cleanup and inserts once. Volatile
words are never silently promoted to final. Copy and Edit are available for the
last completed text in the app. Audio is bounded in memory, never saved to disk.
Readiness audio is discarded before copying, metering, encoding or networking;
only an explicit dictation opens transcription. Cancellation invalidates late output.
Cloud calls already sent during speech can still be billed after cancellation.

For OpenAI speech, every PCM chunk captured during an explicit dictation is uploaded.
The local loudness estimate chooses phrase boundaries only; it never discards quiet
speech. A quiet-only turn is committed after 12 seconds or when ✓ is tapped. This
also means OpenAI speech usage includes pauses while an explicit dictation is active.

Device observations using a synthetic fixture paced in real time: Apple first word
1.16–1.41 seconds after capture, Stop-to-clean 0.69–1.38 seconds across three trials
with the microphone engine running. A 60-second/165-word file-fed Apple workload
cleaned 14 phrases during recording and finished 0.55–0.57 seconds after Stop.
The cheaper OpenAI speech plus streamed cloud writing sample finished 2.10 seconds
after Stop. These fixture timings exclude host insertion. An older live Notes test
measured exactly-once insertion at 1.509 seconds from ✓; it predates the current
no-transcript-preview keyboard UI. None of these measurements is a latency guarantee.

Signposts, app CPU time, physical footprint, thermal state and coarse battery samples
are instrumented. MetricKit gathers later OS aggregates. App metrics exclude work
performed by separate system model services; battery differences are not joule
measurements. See TEST-STATUS.md for measured scope and profiling limitations.

Sources: [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer),
[OpenAI realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription),
[Groq speech-to-text](https://console.groq.com/docs/speech-to-text).

## Cloud cost estimates

Cloud usage shows estimated USD total, this-month total, request count, and per-model
speech/writing usage. Tracking starts with build 32 on this device; it is not an account
billing sync. Local speech and Apple cleanup have no cloud requests to track.

Speech estimates use submitted audio duration (16 kHz phrase uploads, 24 kHz streaming) and published per-minute rates;
Groq applies its 10-second minimum per request. Writing uses response prompt/completion
and cached-input token counts. A successful response counts even when cleanup rejects
the edited wording. Batch/cleanup failures remain unconfirmed and excluded from
totals, with a visible notice that the provider may still bill them. Streaming counts
submitted audio even if cancelled or interrupted, including the last in-flight chunk
whose receipt cannot be proven. It excludes unsent queued and standby audio. Missing token usage
or missing model prices are marked unavailable, never silently priced as free.

Published rates checked November 8, 2026:
- OpenAI: gpt-transcribe $0.0045/minute; gpt-4o-transcribe $0.006/minute;
  gpt-4o-mini-transcribe $0.003/minute (duration-based estimates).
- OpenAI gpt-6-luna: $0.10 input, $0.01 cached input, $0.50 output per million tokens.
- Groq Whisper Large V3 Turbo: $0.04/hour; Large V3: $0.111/hour.
- Groq's current Llama enterprise model requires your account's custom rate.

Sources: [OpenAI pricing](https://developers.openai.com/api/docs/pricing),
[GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna),
[Groq models](https://console.groq.com/docs/models),
[Groq speech billing](https://console.groq.com/docs/speech-to-text).

Tap a model in Cloud usage to enter account-specific or otherwise unknown rates.
Custom rates apply to future requests and older requests that had no known rate;
previously priced history keeps its captured rate. Credits, taxes, discounts, requests
outside TapType and requests whose usage was never returned are not included. Rates
are a dated snapshot, not a live price feed. Consult your provider for the actual bill.
Usage is stored locally with file protection and excluded from backup. It contains
model identifiers, dates, durations/token counts and rates, never audio/text/API keys.
Cloud settings is now presented from the stable screen root, avoiding first-tap sheet
dismissal caused by presenting from a dynamic Form section.

## Use it

1. Install/run the TapType app on your iPhone (iOS 26+). Allow Microphone and Speech Recognition.
2. Add TapType in Settings → General → Keyboard → Keyboards → Add New Keyboard.
   Open its settings and enable Allow Full Access for shared-container communication.
3. Opening TapType leaves the microphone off. There is no Enable Session step.
4. In another app, choose TapType with the globe and tap its TapType button.
5. Speak. The keys change into a voice-reactive waveform with cancel and checkmark controls.
6. Tap ✓. A finish chime and haptic respond immediately. The keyboard waits for the
   final transcript and optional cleanup, inserts it once, and returns to the keys.
   There is no Insert button.
7. Tap × to cancel without inserting.

If the microphone is inactive, the TapType button opens the companion and starts
dictation. The URL is accepted only when its request and text-field IDs match a fresh
keyboard marker in TapType's App Group; an arbitrary `taptype://dictate` URL cannot
authorize microphone startup. Debug builds pair UIKit's keyboard host process ID with
the keyboard arbiter's current client bundle, then request direct app resume through a
guarded, undocumented LaunchServices call. Fresh state wins; a process-local mapping
may be reused for less than eight seconds to support an immediate repeat handoff. There
is no supported-app catalog. Known identifier-casing differences for Messages and
WhatsApp are corrected. See THIRD-PARTY-NOTICES.md for the earlier OpenWhispr basis.

There is no URL-scheme fallback. In particular, TapType never opens sms:// to return,
because that can open a new conversation. If direct resume is unavailable or refused,
use the system back-to-app link or bottom-edge swipe. This also applies to the in-app
checkmark's return. New dictation requests discard the previous return destination.
A resumed app controls its own editor/cursor restoration; exact state preservation
is not guaranteed for every host. Build 51 confirmed one return-only round trip from
Notes on the physical iOS 27.2 phone; recording was deliberately skipped, and the next
immediate attempt lacked a fresh mapping. After Build 52 added process-local reuse, the
user described the result as “great,” but microphone start, insertion, and a second
return were not separately reported step by step. The older iOS 26.5 Simulator result
is not equivalent physical validation, and the iOS 27.2 Simulator still stalls before
TapType runs. This experiment is excluded from Release and may break after iOS updates.

The microphone starts only after tapping TapType. Opening the app or changing Keep
ready never starts input. The menu offers Off, 1, 2, 3, 5 (default), 10 minutes, or
Until I end it. Off combines zero-minute and Stay off behavior: input stops after
finishing/cancelling a dictation. Timed sessions retain input and the command listener;
idle buffers are discarded before buffering, metering, recognition or storage.
Each completed dictation starts a new idle period. Cleanup does not extend it.
Changing the duration during an idle session applies a new timer immediately.
Keep ready → Off (between dictations), errors and interruptions release input. Until I end it removes the idle
timeout, not iOS interruption/termination limits. It can use more battery.

The TapType logo is automatic during the session. There is no app-level logo toggle;
iOS Live Activities authorization still applies. The orange microphone privacy dot
is controlled by iOS and remains visible while input is active. Leaving the app for
Notes retains readiness; force-quitting ends microphone input. iOS may briefly retain
an activity snapshot. Open TapType to clear a stale activity.

The title is centered and the home page starts with word and dictation totals above Keep ready. It uses text-only rows, compact
model pickers and an inline Base/Small download list, without a model sheet or search.
Unavailable speech models stay out of the picker until installed or configured.

The handoff uses a black logo cover at the native window and scene boundaries,
including cold-launch URL detection before SwiftUI renders. Normal app opening
reveals the home screen; failed returns offer a manual-return hint and an explicit
Open TapType button. A short pause after foreground activation separates incoming and
outgoing system animations. The controls stay in a fixed-size, bottom-positioned
area while UIKit restores the remote keyboard. Build 23 removes the inset material
card and border: its SwiftUI logo now sits directly on the native rounded keyboard
surface, inheriting its background instead of adding a second tint. The cover is
prepared before the first render and revealed after return/activation. The Notes
top-to-bottom movement remains unresolved; build 22 was user-confirmed not to fix it.
Simulator recordings still show the system keyboard resizing on return. An extension-local
cover cannot cover the surrounding host toolbar or control the host's window animation.
Build 53 ties the destination and recording authorization to the original keyboard
tap, rejects stale or self-targeting hosts, and limits cached PID mappings to eight
seconds. All visible keyboard controls, the TapType button and transition logo are UIKit-drawn.
The same UIKit button stays visible before and after connecting, in one 44-point slot.
A transparent SwiftUI hit target handles only the extension-compatible app-opening action.

Automatic return is a partially demonstrated private DEBUG experiment, not an App Store contract.
The current physical evidence is the single Build 51 return-only success and the user's
positive Build 52 report described above; a complete Build 53 dictation/insert/repeat
cycle has not been physically rechecked. The signed Build 53 app is installed on the
physical phone and a normal launch succeeded. Rejected system-navigation and extension-host
fallback experiments remain removed. Use the system back-to-app control or bottom-edge
swipe whenever return is unavailable.

Opening TapType manually during recording shows the settings-only home page. Finish
or cancel from the keyboard. No live or completed transcript cards, recording controls,
or Copy/Edit actions appear on home. Word and dictation totals appear above Keep ready. Original transcripts remain in
the dedicated history screen, without the aggregate totals card. The keyboard shows its listening waveform and then an
animated TapType logo during processing, with no provisional text preview.

Start and successful-insertion cues use short AVAudioPlayer playback with a mixing
playback audio session. They respect media volume and the current output route, and
are configured to play in Silent Mode. The finish cue starts when the final text is inserted, not when ✓ is tapped.
The original start/complete tones are retained with higher gain and no clipping. The
player survives keyboard-controller redraws and releases its playback session after
each cue; it never requests microphone
input. Apple documents playback as unaffected by the Ring/Silent switch: see
https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionCategoriesandModes/AudioSessionCategoriesandModes.html

TapType cannot add controls to Apple's or another vendor's keyboard. Secure text
fields and apps that reject custom keyboards use the system keyboard. This is a
basic native-style keyboard, without autocorrect, predictive text, or swipe typing.
Build 26 adds immediate pressed-key highlighting and enlarged character previews for
letters, numbers and punctuation. Previews stay inside the extension's bounds, dismiss
on release/drag-out/cancel, and do not intercept touches. Text inserts on key release.
The extension uses a transparent background so iOS supplies the rounded keyboard
surface and bottom system controls. Keys and icons match that system keyboard window's
light/dark appearance, including refreshing the mic link when it changes. TapType's
companion app uses a dark theme; another host app can request a light keyboard.

## Text cleanup

The app has Original / Clean up / Rewrite controls. Clean up is the default, and the
selection is captured when each dictation starts. Original leaves the recognized
text unchanged. Clean up removes fillers/repetitions and requests grammar and
punctuation corrections. Rewrite requests clearer phrasing without changing intent.

Apple cleanup uses SystemLanguageModel.default through Apple Foundation Models, gated to
iOS 26+ and actual model availability. Apple Intelligence must be enabled and ready;
iOS manages its model assets. There is no automatic cloud fallback. Cloud writing is an explicit separate selection.
Unavailable models, failures/refusals, and the bounded cleanup deadline preserve
confirmed raw phrases and display a short explanation.

Generation streams text with instructions to treat the transcript as data. Numeric-literal, negation-count, and word-retention checks reject obvious
changes and answers. These are conservative heuristics, not a guarantee of semantic
equivalence. Original transcripts now persist in the app's private history, one file
per completed dictation. The history screen shows newest first with device-local date,
time (including seconds), word count, full original text and a gray copy icon aligned
with each timestamp. A centered summary shows total words and dictations. Transcript deletion is not available in the app.
Identical text from separate dictations produces separate entries. Files are protected
until the device's first unlock and excluded from device backups. No raw audio is saved.
History starts with build 26; previously overwritten originals cannot be recovered.
A completed transcript may be saved before insertion if recognition finishes early;
cancelling while recording or cleanup is still pending does not save that unfinished text.
Cancel invalidates both recognition and cleanup so late results cannot be inserted.

## Model and microphone behavior

- Apple Speech remains on-device English (US), with separate downloaded and cloud
  choices. Selecting a local model never uploads dictated audio. Model downloads
  require the internet; Apple Intelligence readiness is managed by iOS.
- Opening the app does not start microphone input. The keyboard’s TapType action
  starts it. With Keep ready enabled, ✓ and cancel detach transcription while
  retaining input for the selected idle duration. Errors, interruptions, expiry and selecting Off between dictations
  release the engine and deactivate the audio session.
- After ✓, a bounded background task finishes recognition and optional cleanup
  using captured audio. Completed text remains insertable after the app suspends.
- Dictation is capped at 30 minutes or 100,000 raw characters. Audio queues are bounded;
  overflow stops gracefully and preserves confirmed speech. Speech finalization gets
  up to 18 seconds; cleanup drains for up to 12 seconds, subject to iOS background time.
  On overload/critical thermal pressure or timeout, pending phrases retain raw words.
  Explicit adjacent self-corrections are reconciled during phrase cleanup; Stop does
  not routinely launch another whole-recording LLM request.
- Downloads use foreground URLSession tasks: keep TapType open. This version does
  not promise background model downloads or byte-level resumption within a file.
- Calls or audio interruptions stop dictation. Tap TapType on the keyboard to retry.
- Microphone audio is not saved to disk. A pending transcript is stored in the shared
  App Group. Successful insertion clears the result when the microphone is off;
  cancelling an active dictation or starting another clears/replaces it. Pending
  delivery expires after 35 minutes; expiry alone does not erase the stored file.
- The small waveform in Dynamic Island is a Live Activity showing readiness or
  listening state, not a high-frequency audio meter. The keyboard waveform is driven
  by actual microphone RMS levels. Live Activities can be disabled in iOS settings.
- Mic taps play a short rising tone with a medium haptic; checkmark taps play a
  distinct finish chime with a success haptic. The reconnecting mic link also provides
  tap feedback. Audio-session settings explicitly allow system sounds and haptics
  during recording. The cues play in Silent Mode and respect media volume; haptics
  depend on device settings.
- On iOS 17.5+, haptic generators attach to the keyboard's visible action controls.
  The reconnecting microphone requests feedback at press-down, before opening the
  companion app. Older iOS versions use the original generators. Letter keys do not
  currently request haptics. Build 9's cancel haptic did not vibrate on the user's
  iPhone. Build 11 tries a haptics-only Core Haptics pattern, with UIKit fallback on
  error. The user confirmed cancel vibration on the iPhone in build 11; this does
  not establish behavior on all devices or settings. DEBUG diagnostics store only the event,
  acceptance flag, and error domain/code in haptic-status.json.

## Delivery safeguards

Checkmark intent and result share a unique request ID. Delivery requires a final,
nonempty, successful result, the original text-field identifier, and a fresh pending
request. A persisted receipt prevents replay after keyboard reload. If the user
changes fields while recognition finishes, a second explicit checkmark is required
to insert into the newly selected field. Cancel clears pending delivery.

## Build and rename

Open TapType.xcodeproj, select the TapType scheme, and run on your iPhone. The scheme
builds/embeds TapTypeKeyboard and TapTypeActivity. Signing uses the existing developer
team configured in this workspace. App and keyboard share the registered App Group.

Change TAPTYPE_DISPLAY_NAME in Debug and Release project settings to rename the app
and keyboard. Internal bundle/App Group identifiers can remain unchanged. Some setup
copy and accessibility labels still say TapType and can be renamed separately.

For another developer team, update DEVELOPMENT_TEAM and TAPTYPE_BUNDLE_ID, register
a matching App Group for the app and keyboard, and update its literal identifier
in TapType/Shared.entitlements to match TAPTYPE_APP_GROUP. The Live Activity extension
uses the .activity bundle suffix and does not access the shared container.

The AppIcon asset contains the white waveform on an opaque dark background.
The app uses a compact 260-point keyboard, 22-point letter labels, and matching
20-point toolbar icons with 44-point tap targets. The Build 53 top-toolbar layout is
restored: a circular gear on the far left opens the TapType home screen without starting
dictation, while the compact TapType dictation button remains on the far right. The
dictation action becomes ✓ and the gear hides while a request is active; × takes its
place on the left. Letters open uppercase, then return
to lowercase after the first letter. iOS owns the separate globe/microphone footer and
does not provide an API for a custom keyboard to replace or receive taps from its
microphone button.

## Verification

See TEST-STATUS.md in the deliverable for the latest verified results and limitations.
Run `swift test` for the committed handoff-authorization and bounded-cache tests.
Use a physical iPhone for real speech/model verification. DEBUG --pipeline-tests
runs deterministic pipeline and cost checks. --apple-benchmark runs the controller
with the real microphone engine and paced synthetic speech; --file-benchmark tests
real speech/cleanup services without microphone capture. --long-recording selects
the 60-second fixture. These do not substitute for a live human keyboard test.

References: [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models),
[Handy](https://github.com/cjpais/Handy),
[Apple custom keyboards](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard),
[Apple Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities),
[Wispr iPhone setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone).

TapType is a separate development prototype and is not affiliated with Handy or Wispr.
