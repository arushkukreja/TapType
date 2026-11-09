# Build 57 — OpenAI quiet-speech upload fix (November 9, 2026)

- The latest three-word history entry came from a 16.63-second completed dictation,
  but its cloud ledger showed only 1.083 seconds sent to `gpt-transcribe`. Cleanup
  received only those three finalized words. This isolated the loss to TapType's
  pre-upload RMS gate, not the microphone duration, cleanup, or finish timeout.
- OpenAI streaming now sends every nonempty PCM chunk during an explicit dictation.
  RMS is retained only as a phrase-boundary hint. A turn without locally detected
  voice commits at the 12-second cap or ✓, avoiding both quiet-speech loss and
  repeated 0.65-second silent commits. Keep ready audio is still discarded before
  encoding or networking.
- Six shared package tests pass. Unsigned generic-iPhone Debug and Release builds
  pass. The signed app, keyboard, and Live Activity all report build 57.
- Build 57 was installed over the existing bundle and launched normally on the
  connected iPhone 15 Pro. CoreDevice reports installed bundle version 57.
- A physical-device OpenAI regression fed 20.0 seconds of fixture audio with every
  50 ms packet held below the former `0.008` RMS gate. TapType produced two confirmed
  completed turns totaling 20.0 seconds and finalized 50 words, including the known
  “purple bicycle” phrase. The test added two legitimate speech-usage rows totaling
  about $0.0015 at the saved published rate; it did not add transcript history.
- All 29 focused in-app pipeline checks passed. The separate cost-check sequence then
  stopped at the historical `luna_cleanup_disables_reasoning` DEBUG assertion because
  its URLProtocol stub reads `httpBody` after URLSession has moved it to
  `httpBodyStream`. The production request still includes `reasoning_effort: none`;
  both involved files are byte-identical to build 56 and unrelated to this change.

Pending physical confirmation: one normal 20-second microphone dictation at the user's
usual distance, followed by ✓ insertion. The fixture validates full cloud forwarding
on the actual phone but not the microphone, keyboard handoff, or originating-app return.
No iOS 27.2 Simulator pass is claimed.

# Build 56 — far-left circular home gear (November 9, 2026)

- Moved the existing 44-point home gear from beside TapType to the far-left edge of
  the idle toolbar. The TapType capsule remains at the far right.
- Gave the gear a 44-point circular background using the same dynamic label color at
  eight-percent opacity and 22-point radius as the TapType capsule.
- During an active request the gear still hides and × occupies the leading position;
  status, ✓, app-opening, recording and insertion behavior are unchanged.
- Six focused tests and generic-iPhone Debug/Release builds pass. The signed app,
  keyboard and Live Activity all report build 56. Build 56 was installed and launched
  on the connected iPhone 15 Pro; CoreDevice reports bundle version 56.

Pending physical confirmation: the exact spacing/background appearance and one gear tap
opening home without recording. No equivalent iOS 27.2 Simulator pass is claimed.

# Build 55 — Build 53 toolbar restored with home gear (November 9, 2026)

- Restored the Build 53 keyboard geometry: the 44-point toolbar is above the unchanged
  key panel, and the idle dictation action is again the 124-point TapType capsule.
- Added a 44-point UIKit gear immediately to the capsule's left. Its separate transparent
  SwiftUI hit target opens `taptype://home`; it does not create dictation/preparing markers,
  tickets, commands, sounds or haptics. The gear hides for every active dictation state.
- The home URL validates the TapType scheme, clears any history/cloud/usage presentation,
  dismisses the transition shield and reveals the root home screen. The existing
  `taptype://dictate` branch and recording flow are unchanged.
- Six focused shared tests pass. Generic-iPhone Debug and Release builds pass. The signed
  app, keyboard and Live Activity all report build 55. Build 55 was installed over the
  existing bundle on the iPhone 15 Pro and launched; CoreDevice reports bundle version 55.

Pending physical confirmation: gear placement, cold and warm gear taps opening the home
screen without a start cue or recording, and the unchanged TapType → ✓/× flow. No iOS
27.2 Simulator claim is made; that runtime still stalls before TapType runs. Build 54
below is historical and superseded by this restored layout.

# Build 54 — bottom-right TapType dictation control (November 9, 2026)

- Moved the existing dictation control rail below the unchanged key grid. The idle
  action is now a 44-point waveform-only TapType button at the bottom-right of the
  custom keyboard. The same slot still shows ✓, retry and progress states; × remains
  on the left while a request is active.
- Reused the original action container, including the transparent SwiftUI app-opening
  hit target, UIKit ready-state action, attached haptic generators and spinner. Start,
  commit, cancel and exactly-once insertion code was not replaced.
- The rail now clamps to the keyboard view's actual height so UIKit transition-time
  bounds changes cannot place start/finish/cancel controls outside the hit-testable view.
- Six shared handoff/cache tests pass. Unsigned generic-iPhone Debug and Release builds
  pass. The signed Debug app, keyboard and Live Activity plists all report build 54.
- Build 54 was installed over the existing `com.arushkukreja.TapTypeDev` bundle on the
  iPhone 15 Pro and launched successfully; CoreDevice reports bundle version 54.

Physical-device layout and interaction are still pending: confirm the logo position,
one cold TapType tap that opens/starts dictation, ✓ insertion exactly once, and × cancel.
iOS owns the separate footer containing its globe/microphone controls; public custom-
keyboard APIs cannot replace that microphone glyph or receive its taps. No iOS 27.2
Simulator claim is made; that runtime still stalls before TapType runs.

# Build 53 — GitHub readiness and handoff hardening (November 8, 2026)

- `taptype://dictate` starts no microphone work unless its request and document IDs
  match a preparing marker created by the keyboard less than eight seconds earlier.
- The DEBUG host resolver prefers a fresh PID/bundle pair and keeps fallback PID
  mappings for less than eight seconds instead of the keyboard process lifetime.
- Six committed Swift tests pass for fresh, wrong, future and expired markers plus
  cache reuse, overwrite, pruning and exact eight-second expiry.
- Unsigned generic-iPhone Debug and Release builds pass with Xcode 26.6. Generated
  app, keyboard and Live Activity plists all report build 53 in both configurations.
- `work/`, Swift build products and source-package ZIPs are ignored for GitHub; the
  existing local diagnostics and archives were not deleted.
- OpenAI's new unsaved writing default is `gpt-6-luna`, with its published Standard
  token rates and `reasoning_effort: none`. Saved model names, keys, history and
  previously captured rates remain unchanged.

Physical-device scope: the signed Debug app was installed over the existing bundle on
the iPhone 15 Pro, CoreDevice reports bundle version 53, and a normal launch succeeded.
Dictation, insertion and automatic return have not yet been physically rechecked. Build
51 previously completed one return-only Notes round trip on iPhone 15 Pro/iOS 27.2;
that diagnostic deliberately skipped recording, and the immediate next attempt failed.
After Build 52 added process-local reuse, the user called the result “great,” but did
not separately report microphone start, speech, insertion and a second return step by
step. No equivalent iOS 27.2 Simulator pass exists; that simulator still stalls before
TapType runs. Earlier entries below remain historical.

# Build 50 — totals moved to home

- Moved the existing centered word and dictation totals above Keep ready on home.
- Removed the aggregate totals section from Original transcripts; per-entry word counts, timestamps and copy actions remain.
- Uses the same observed history store; no changes to counting, storage, deletion, recording or return behavior.
- Signed iPhone build passed and installed. On-device visual inspection has not been repeated.

Earlier reports below are historical and superseded where they conflict.

# November 8 return investigation — unresolved on iOS 27.2

Physical no-audio handoff tests still fail. The keyboard's host process ID is present, but all tested bundle/scene destination fields are empty; main-app process resolution also fails. Failed experimental hooks were removed and build-44 source restored. See [RETURN-INVESTIGATION.md](RETURN-INVESTIGATION.md) for actual phone evidence and limits.

The general iOS 27.2 Simulator runtime is installed, matching the phone's major/minor OS version. It stalls during system startup before TapType runs, so equivalent-version simulator validation is not complete. Older iOS 26.5 simulator success is not a physical-device pass.

# Build 44 — clean home, consistent UIKit keyboard, original louder sounds

- Home starts at Keep ready. No word-total card, listening/recording information,
  live transcript, completed transcript, Copy/Edit card or editing sheet on home.
  Dedicated original-transcript history remains available.
- No live transcript preview in the keyboard. It shows the listening waveform and
  then the centered animated TapType logo during recognition/cleanup.
- Every visible keyboard control and transition logo is UIKit-drawn. One UIKit
  TapType button stays visible in disconnected and ready states; a transparent
  SwiftUI hit target only routes the extension-compatible app-opening action.
- User confirmed build 43 keyboard spacing is consistent before/after dictation.
  Simulator also visually matched both states; cold opening and ready-state starts
  both responded correctly, and a synthetic final sentence inserted once.
- Build 42 user confirmed start and completion sounds worked in Silent Mode but
  were quiet. Phone diagnostics confirmed Complete played to the end through Speaker,
  media volume 0.25. Build 43 tested clearer replacement tones; user requested the old tones.
- Build 44 restores the original tone waveforms, lengths and envelopes with amplitude
  gain only (+15.15 dB Start, +14.13 dB Complete relative to the original assets).
  Sample-by-sample checks confirmed uniform scaling, unchanged length and no clipping.
  Normal media-volume/output-route controls still apply; the app does not change volume.
- Playback is retained across keyboard-controller replacement. Start plays on each
  TapType tap; Complete plays in the final insertion branch, not on the checkmark tap.
  Simulator actual Start and Complete playback both reached their delegate completion.
- Build 43 Debug device, signed Simulator and unsigned Release builds passed.
  Build 44 changes only sound assets and build numbers; its signed device build passed
  and was installed. No new speech, cleanup, cloud or automatic-return logic changed.

Known limit: automatic app return remains unresolved on the physical phone. This
update fixes presentation/audio, not the return mechanism. Final build-44 loudness
preference has not been re-confirmed by the user; original tone identity is verified.

Earlier reports below are historical and superseded where they conflict.

# Build 41 — settings-only home, logo processing, audio cues (November 8, 2026)

- Signed Debug iPhone build installed; signed Simulator and unsigned Release builds
  passed without compiler warnings/errors.
- Simulator home verified with a completed transcript deliberately in memory: starts
  at Keep ready; no word-total, Your text, Copy/Edit or active transcription section.
- A synthetic keyboard host supplied a nonempty provisional preview. The keyboard
  showed the listening waveform without that text, then the centered pulsing TapType
  logo during a four-second simulated processing delay. Its final nine-word sentence
  inserted exactly once into an unsent Messages draft, and the typing keys returned.
- Actual AVAudioPlayer play() returned true for Start and Complete in the Simulator
  (output volume 0.6). Complete is called only in the successful insertion branch;
  the checkmark retains its haptic but no longer plays the completion sound early.
- Keyboard playback uses a short .playback/.mixWithOthers session, released on finish
  or error. It never opens microphone input or changes the companion's session category.
- Physical Silent Mode audibility and simultaneous microphone compatibility are pending
  the user device check. Simulator acceptance does not establish audible phone output.
- No speech-provider, cleanup, history, cost or automatic-return changes. The known
  physical automatic-return issue remains unresolved; manual return is still required.

Earlier reports below are historical and superseded where they conflict.

# Build 40 — normal home, button alignment, unresolved phone return (November 8, 2026)

- Companion home no longer shows active live text, recording controls or End session.
  Keyboard live preview, finish/cancel, readiness menu and completed-text Copy/Edit remain.
- The reconnect SwiftUI button is pinned to the same 44-point slot as the ready UIKit
  button, with inherited safe-area regions disabled. Both states were visually compared
  in Simulator Messages and occupy the same position. Host footer/accessory bars remain
  controlled by iOS and the hosting app.
- Physical auto-return is NOT fixed. The user confirmed failures in builds 35–39.
  Diagnostics show no source bundle from the keyboard observer; an explicit service
  connection produced events but their source remained nil. The keyboard-side host
  lookup and system-navigation fallback also failed. Those experiments were removed.
- Device reports iOS 27.2 (24B119); Nov 6 device-build records show iOS 26.6.2.
  The original DevKeyboardReturn.swift is byte-identical in the build-33 and build-34
  snapshots. This supports investigating OS compatibility; it does not prove causation.
  An old complete app has not been A/B tested on the current phone.
- Simulator iOS 26.5 returned to the same Messages conversation and unchanged synthetic
  draft. This was a return-only test, not a microphone/recognition test. It does not
  override the physical failure. Build 40 retains that observer/resume mechanism.
- No speech/model pipeline changes in this pass. Build-34 speech and latency evidence
  below remains historical validation. No paid API calls were made for these checks.
- Build 40: Debug iPhone, signed Debug Simulator and unsigned Release build checks,
  plus 64 shared delivery/readiness/return-identity assertions (results recorded locally).

Limit: return uses DEBUG-only undocumented APIs and is excluded from Release.
The current phone requires manual return. Notes' host keyboard animation remains unresolved.

Earlier reports below are historical and superseded where they conflict.

# Build 34 — streaming phrases (November 8, 2026)

- Final live Notes test: the user confirmed visible preview while speaking and
  exactly one insertion. Numeric timing measured from ✓: speech finalized 0.268874 s,
  cleanup completed 1.444995 s, keyboard insertText returned 1.509432 s. The actual
  recording lasted about 15 seconds; first preview appeared 3.021 seconds after
  capture began. App footprint 28.7 MiB, mean CPU 23.45% of one core, thermal nominal.
  No transcript content was read for these measurements.
- Debug physical-device and Simulator builds and unsigned Release device build pass.
- 29 pipeline checks pass on iPhone and Simulator: provisional revisions, finalized
  protection, VAD boundaries, duplicate/order handling, explicit correction invalidation,
  corrected numeric values, stale callbacks, serial LLM execution, cancellation, and
  idle/post-stop audio discard, cleanup wrapper stripping, and prevention of copied context. All 26 cost regressions pass on both; 54 shared
  delivery/readiness assertions pass, including delivery during a long recording.
- The expensive gpt-live-transcribe choice is removed. Apple remains local/default;
  OpenAI and Groq configuration, downloaded Whisper models, history and keys remain.
- Real Apple SpeechAnalyzer/Foundation Models tests on iPhone 15 Pro:
  three paced 2.83-second synthetic samples, with AVAudioEngine microphone input
  running, all produce the expected nine-word phrase. First visible word after capture:
  1.406 / 1.212 / 1.159 seconds; Stop-to-clean: 0.689 / 1.317 / 1.378 seconds.
  App peak physical footprint 29.7–31.6 MiB; average CPU 16.8–24.8% of one core.
  The fixture replaces microphone samples for repeatability; this is not a human voice test.
- Real 60.16-second file-fed Apple workload: 165 words, 14 cleanup requests while
  audio continues, first visible word about 1.15 seconds after audio starts, first
  refinement before six seconds, Stop-to-clean 0.55–0.57 seconds. App footprint
  30.6–34.0 MiB, mean app CPU 4.4–5.2% of one core; thermal state stayed nominal.
  One phrase safely retained raw text after cleanup validation failed.
- Real configured OpenAI gpt-transcribe plus streamed gpt-4.1-mini cleanup passed
  a nine-word fixture: Stop-to-clean 2.097 seconds, one cleanup request, no fallback.
  Audio is sent while recording; cheaper transcription emits after phrase commits.
  This is not the removed expensive live model. Cloud test charges remain in usage.
- Downloaded Whisper Base passed a one-minute phrase-streaming run: 166 recognized
  words, five audio clips, 12 cleanup requests, Stop-to-clean 2.023 seconds, 91.7 MiB
  peak app footprint, 6.45% mean app CPU, nominal thermal. First text took 20.90 seconds
  because continuous speech hit the 12-second clip limit before cold model loading.
  It is a phrase-streaming adapter, not word-by-word Whisper decoding. This test caught
  a silent-chunk abort and per-phrase reload; both were fixed. A cleanup output repeated
  read-only context; the final guard rejects that edit, with direct regression coverage.
  Final guard verification is deterministic; the long timing run precedes that guard.
- Groq configuration was exercised, but a real request was blocked because no Groq
  key is saved. No key was invented or substituted. The SSE format follows the official
  [Groq API reference](https://console.groq.com/docs/api-reference). Live Groq service
  latency/usage is therefore unverified in this build.
- Simulator: Copy copied the exact synthetic result; Edit → Done updated the home
  result. Cloud providers stayed open on the first tap. No credentials were exposed.
- A 93.18-second physical-device Power Profiler trace covers the one-minute Apple
  file workload and its surrounding idle time. Thermal remained nominal throughout.
  TapType relative subsystem impact: CPU mean 0.365, peak 6.0; GPU mean 0.064, peak 1.0;
  networking 0. These are Instruments impact units, not watts. Whole-device estimated
  discharge averaged 15.75%/hour over this short profiling window, including display,
  system model services, profiling and other activity; it is not an app battery-life
  forecast or a controlled energy comparison. App battery samples are only coarse.
- iOS initially denied all three standard recording categories with insufficient
  priority despite an active app and no reported call. Restarting the iPhone cleared
  it; the three capture-session tests then passed. Foreground activation is now awaited
  and start/cancel generation guards prevent duplicate or resurrected starts.

Limits: timings exclude host insertion unless explicitly identified as keyboard timing.
No 30-minute soak, forced system-call interruption, device reboot during a download,
or new fully offline run has been completed. The real tests use downloaded Apple
assets; Simulator assertions do not establish speech support there. Model meaning
checks are conservative heuristics, not guarantees. Existing Notes resize animation
and DEBUG-only private host-return behavior are unchanged in this pipeline update.

Earlier build reports below are historical and superseded where they conflict.

# Build 33 — live OpenAI transcription (November 8, 2026)

- Real physical iPhone 15 Pro Notes test: user confirmed successful insertion.
  Numeric timestamps measured ✓ to final transcript **0.466970 s**, cleanup complete
  **0.971481 s**, actual keyboard `insertText` return **1.034420 s**.
- Three real OpenAI live requests using the bundled 2.833 s synthetic speech fixture:
  final transcript 0.391056 / 0.436214 / 0.655024 s after commit;
  prewarmed Apple cleanup complete 1.043211 / 0.975542 / 1.191798 s.
  Each yielded ten partial events during streaming and nine final words; cleanup used
  the real on-device model. These synthetic figures exclude host insertion time.
- 29 streaming checks passed on Simulator and physical iPhone: resampling at
  24/44.1/48 kHz; configuration gate; queued commit; matching item IDs including
  out-of-order completion; close/cancel/send failure; idle no-cost; bounded queue;
  streamed/cancelled costs; old ledger compatibility; warmup costs and Original bypass.
  A fixed 100 ms test wait initially raced in Simulator; replaced with a bounded
  condition wait. The production streaming implementation did not fail that check.
- 26 provider checks plus clip privacy checks passed on iPhone. Privacy checks cover
  idle discard, successive stream drains, tail capture, post-stop discard, cancellation
  and the automatic-stop confirmation gate. Fake provider responses are explicitly used.
- All 22 existing cost regressions passed in Simulator; 53 delivery/readiness checks
  passed against the shared production bridge. No tests send idle microphone audio.
- Device usage ledger verified: four completed live entries, three 2.83325 s fixture
  requests ($0.00080275 each) and the 14.376 s Notes request ($0.0040732 estimate).
  No transcript/audio/API key is included in the usage ledger or this report.
- Debug device and Simulator builds and unsigned Release device build passed.
  Build 33 installed; user's live speech selection retained. Apple writing prewarm is
  tested on device; cloud writing preparation is verified with mocked provider usage.

Limits: timings vary by network, utterance and model. Cloud preparation does not
promise model residency. Submitted streaming audio may be billed even on cancel.
The pre-existing Notes resize animation and DEBUG-only private host return remain.

Earlier build reports below are historical and are superseded where they conflict.

# Build 32 — cloud costs and stable provider sheet (November 8, 2026)

- Signed iPhone Debug, Simulator Debug and Simulator Release builds passed.
- All 22 cost assertions passed in Simulator and on the physical iPhone, using an
  isolated temporary ledger and intercepted URLSession responses. No paid API call,
  real API key, original transcript or production usage record was used/modified.
- Checks cover minute rates, Groq's ten-second minimum, cached tokens, duplicate
  response completion, unknown/enterprise rates, custom-rate persistence and filling
  unpriced history, immutable priced history, invalid rates/tokens, missing usage,
  saved totals, absence of transcript/key content, cleanup rejected after billing,
  Original/connection-test exclusion, HTTP-failure uncertainty, speech duration,
  pre-send cancellation and corrupt-file preservation.
- Simulator: first cloud-sheet tap stayed open across two fresh launches. API-field
  focus and provider switching remained inside the sheet; Back returned home. Sheet
  presentation now belongs to ContentView's stable root, outside Form sections.
- Simulator visually checked Cloud usage totals, monthly/request rows, model prices,
  Rate needed, source links and the native writing-rate editor.
- Build 32 installed and launched normally on the physical iPhone. Physical first-tap
  visual confirmation and live provider invoice comparison remain unverified. Billing
  estimates start with this build, exclude unknown costs, and are not invoice totals.
- No microphone, keyboard handoff or model-download behavior changed in this pass.

# Build 31 — compact home and transcript history (November 7, 2026)

Signed iPhone and Simulator Debug builds passed. Simulator inspection with two synthetic
transcripts verified white Cloud providers/history chevrons, removal of the home history
word count, reduced top scroll margin, centered history words/dictations summary, and
trailing icon-only copy buttons beside local timestamps and word counts. Copy buttons
retain a 44-point target and an accessibility label. Explicit gray tint overrides the
native button's blue. No transcription, storage, microphone or provider logic changed;
no additional behavioral tests were needed. User transcripts were not modified.

# Build 30 — model controls and word counts (November 7, 2026)

Signed iPhone and Simulator Debug builds passed. The centered Words dictated card,
inline model list, native Uninstall action, Cloud providers chevron and plain model
names were visually checked in Simulator. Speech showed only Apple Speech and the
installed Base model; absent Small and unconfigured cloud providers were excluded.
Cloud Done returned home successfully; Back and Done are native toolbar controls.
The entire Cloud providers row is tappable. Transcript swipe-to-delete and its FAQ
instruction were removed; existing records remain intact.

Physical-device assertions passed for word counting (including punctuation/emoji),
totals across persistence/reload, cloud-draft model/key validation, and existing
history/controller storage behavior. No real API keys, fresh downloads or model
uninstalls were performed. These tests do not verify paid cloud-model access.
The source's internal history-remove helper remains for isolated storage diagnostics;
there is no deletion control in the user interface. Totals count saved originals.

# Build 29 — inline settings icons (November 7, 2026)

The five requested rows use an inline SwiftUI label with eight-point icon/text spacing:
On-device models, Cloud providers, Set up your keyboard, Common questions and Original
transcripts. Signed iPhone and Simulator Debug builds passed; all five rows were
visually checked in Simulator (TapType-v29-home.png). Their actions and accessibility labels are unchanged. No speech/session,
model, credential or history logic changed; no new behavioral tests were needed.

# Build 28 — ready-duration menu and simpler home (November 7, 2026)

- User confirmed build 27's physical logo and ready session work after enabling Live
  Activities. Build 28 removes the app-level logo toggle and displays it automatically.
- Added Off, 1/2/3/5/10 minutes and Until I end it, default five. Off combines the
  requested zero-minute/Stay off synonyms. Selecting an option never starts input.
- 53 policy/delivery checks passed, including all durations, exact expiry, manual reset,
  invalid saved-value fallback and unlimited readiness.
- Physical iPhone assertions passed for all seven options: real engine startup, idle
  discard/capture detached, chosen deadline, Off releases immediately and unlimited
  releases on End session. Expiry in this pass uses an advanced monotonic test clock;
  the prior build 27 full 300.20-second physical timeout remains the elapsed-time test.
- The rapid seven-start diagnostic hit iOS's Live Activity creation limit on the last
  two iterations; microphone policy assertions still passed. This diagnostic is not
  claimed as a display test. Normal warm dictations retain one Live Activity.
- Simulator visual check: centered title, no nonfunctional toolbar icon, no readiness
  or logo switches, compact model selectors, all seven native picker choices.
- Searching “small” leaves only Whisper Small. Model name, size and action fit one
  row at the inspected default text size. Screenshot: TapType-v28-home.png.
- Build checks: signed iPhone Debug, Simulator Debug and Simulator Release passed. No model downloads or paid API calls repeated.
- Until I end it increases microphone/battery use and remains subject to iOS interruption
  and termination. Extreme accessibility text sizes and long unattended use not tested.

# Build 27 — five-minute ready session and TapType logo (November 7, 2026)

- User explicitly authorized active microphone input between dictations, idle audio
  discard, the visible iOS orange dot, and a branded Live Activity. This supersedes
  build 26's always-release default. Both requested options default on for this build.
- Signed iPhone Debug and Simulator Debug/Release configurations built successfully.
- All 38 executable delivery, transition, host-identity and readiness-policy checks
  pass. The timer uses monotonic uptime; processing cannot extend its five minutes.
- Physical iPhone: initial input off, explicit start, idle engine running with an
  increasing discarded-buffer count, nil recognition task/request and empty transcript
  all passed. No idle clip is buffered, metered, saved or sent to a provider.
- A command through the real KeyboardBridge channel started another recording while
  Notes stayed foreground. The local Apple recognizer then transcribed the known PCM
  fixture correctly and returned to ready, with no active recognition/buffering.
  This is a hardware/session test using known PCM, not a fresh acoustic/UI insertion test.
- Full-duration physical timeout passed after 300.20 seconds, with TapType behind
  Notes for most of the run: engine stopped, session disabled, capture detached.
- Manual End session stopped input. Toggling readiness off released input; toggling
  it back on did not start capture. Simulated engine-stop/route failure and interruption
  shutdown passed. These are state/notification simulations, not a real incoming call.
- Final physical microphone-off regression passed with readiness disabled and logo
  display both on/off. History storage and controller checks passed: two completed
  originals persisted and cancelled cleanup created no entry.
- Simulator settings visibly show both options enabled. The real WidgetKit extension
  renders the waveform logo in compact and expanded Dynamic Island views. Preview
  screenshots use synthetic Ready state without microphone input, so no orange-dot
  claim is made from those screenshots. No app-owned microphone glyph remains.
- At the physical authorization check, iOS reported Live Activities disabled. The
  user was asked to enable Settings → Apps → TapType → Live Activities. Until enabled,
  the physical logo cannot appear; audio readiness works independently of this setting.
- Existing Notes cold-return animation, DEBUG-only private host-return mechanism,
  cloud/live-account and true airplane-mode limitations remain. No provider, model
  download, key storage, history persistence or keyboard feedback code was reverted.

# Build 26 — microphone release, key feedback and transcript history (November 7, 2026)

- Signed Debug iPhone, Debug Simulator and Release Simulator builds succeeded.
- Physical iPhone lifecycle assertions passed with dictation status display both on
  and off, and with the obsolete stayReady preference saved as true. Opening the
  app did not start capture. Checkmark and cancel stopped the engine, removed its
  input tap, detached capture and disabled the session; background idle remained off.
- Five-minute idle input holding is removed. This supersedes the build 24/25 readiness
  behavior below. iOS may require reopening TapType for the next dictation.
- Physical history checks passed: append, distinct IDs with identical text, duplicate-ID
  rejection, empty-text rejection, persistence/reload, local timestamps, delete,
  preservation of corrupt files, and a friendly write-error result.
- The controller history pipeline saved two synthetic completed originals, reloaded
  them from disk, and did not save a cancelled cleanup. Tests use temporary history
  directories and do not add synthetic text to the phone's real history.
- All 32 remaining delivery/transition/host-identity checks passed; six obsolete
  idle-readiness assertions were removed with that feature.
- Simulator typing entered Qwerty correctly. Video frames show the enlarged Q and
  pressed-key highlight while held, then their removal after release. Evidence:
  TapType-v26-key-preview.png. Physical typing feel is not newly verified.
- Simulator history visually shows separate originals with local dates/times, newest
  first, and Copy original controls. Evidence: TapType-v26-history.png. The two
  explicitly labeled preview records were removed after inspection.
- History starts with this build. Earlier overwritten originals cannot be recovered.
  Only completed original text is stored, privately on this device; no audio history.
- Notes cold-return resizing remains unresolved. This pass does not claim to fix it.
  Existing cloud/live-account and airplane-mode limitations below still apply.

# Build 25 — local/cloud integrations (November 7, 2026)

- Signed Debug iPhone, Debug Simulator and Release Simulator builds succeeded.
- Real iPhone 15 Pro downloads completed with manifest/hash verification:
  Whisper Base English (149,114,698 bytes) and Small English (488,917,923 bytes).
- Both transcribed the bundled synthetic sentence correctly:
  “The purple bicycle is parked beside the yellow house.” First load + transcription:
  Base 7.92 seconds; Small 22.67 seconds. These are one-sample timings, not a benchmark.
- Both passed the full SpeechRecognizer clip pipeline: start → ✓ → final transcript,
  readiness still available, no active recognition/buffering while idle, repeat start
  followed by cancel clearing the clip/transcript. Hardware microphone capture was
  opened; known PCM was supplied for the transcription assertion.
- All 28 provider/integrity checks passed on the iPhone. They cover valid/corrupt/truncated
  download files and OpenAI/Groq URL/auth/multipart construction,
  parsed speech and cleanup responses, original-mode no-request behavior, meaning
  guard fallback, friendly 401/429/500 errors, and actual Keychain save/read/remove
  using a temporary fake key only when no saved key exists.
- Audio checks cover PCM/WAV encoding, sample-rate validation, real fixture
  resampling, idle discard, cancel discard, and no provider task/upload on the
  recording time limit without a checkmark.
- Original Apple Speech regression also passed with the same known sentence, final result
  true and no error. Its helper now explicitly selects Apple and restores user choices.
- All 38 existing request delivery/readiness/return-identity checks passed.
- Simulator UI inspected: native speech/writing settings, OpenAI and Groq key/model
  fields, download sizes/progress/cancel. Cancelled Base download resumed from verified
  files and completed. Screenshot: TapType-v25-model-downloads.png.
- The initial test-only URLProtocol attempt to block all networking did not intercept
  default URLSession traffic. Its self-check failed and the test was removed; no
  offline result is claimed from it. A real airplane-mode test disconnected the
  wireless debugger; user chose to test offline later and restore connectivity.
- No live paid API request was made. Real cloud account access/model availability
  remains unverified until a user enters a valid key in the app. API keys must not
  be pasted into chat. Apple remains the default; downloaded choices need installation.
- Notes cold-return resizing remains open. No new physical haptic/host-return claim
  is made beyond earlier user-confirmed builds. Ready-mode timeout was already tested
  at the actual 300-second duration in build 24 below.

# TapType build 24 — verification, November 7, 2026

## Build 24: five-minute microphone readiness

- Added a persisted Stay ready for 5 minutes toggle, enabled by default per the user's
  request. Enabling it or opening the app does not start input. After an explicit
  dictation finishes/cancels, the microphone may remain active for 300 idle seconds.
- The sink discards idle buffers before recognition, storage or metering. A physical
  iPhone diagnostic confirmed idle buffers arriving and being discarded, with no
  recognition request/task attached and an empty transcript. No pre-roll is kept.
- A physical background test accepted a start through the real KeyboardBridge command
  channel while Notes remained foreground. Known PCM through the real local recognizer
  produced “The purple bicycle is parked beside the yellow house”, finalized successfully,
  and left input ready with the capture sink detached. This is not a new acoustic test
  or a physical UI tap/insertion test; the existing delivery tests cover insertion guards.
- A full-duration iPhone test stopped input after 300.16 seconds, with capture false.
  The app was backgrounded in Notes for the latter part of this run. No accelerated
  timer or injected clock was used for this device test.
- Physical control checks passed: manual Stop microphone; switching readiness off;
  switching it on without starting input; simulated engine-stop/route recovery; and
  simulated interruption shutdown. These simulate the notification/state transitions,
  not a real incoming phone call or Bluetooth disconnect.
- With readiness disabled, physical diagnostics passed: initial mic off, explicit start,
  immediate hardware release after finish, restart, cancel release, background-idle off.
- Optional Show microphone status defaults off. No custom Live Activity is created in
  quiet mode. If enabled, it can show Listening/Ready until input stops, so it can update
  without creating a new Activity from the background. A friendly notice explains
  unavailable status. iOS reported Live Activities unauthorized for TapType on this
  phone; optional visible Island rendering could not be verified and is not claimed.
- Existing SwiftUI settings were inspected in Simulator; readiness toggled off/on and
  the normal screen remained microphone-off. A later final visual recheck was blocked
  when the Mac locked. Final Debug iPhone/Simulator and Release Simulator builds passed.
- All 38 executable delivery, transition, identifier and readiness-policy checks pass.
- Production speech remains local Apple Speech; cleanup remains Apple Foundation Models.
  Downloadable models and cloud/API-key adapters are planned in MODEL-PLAN.md only.
- Notes cold-return resize remains unresolved. Repeated dictations within the readiness
  window avoid the app switch; they do not prove the cold-return animation is fixed.
- See CODE-REVIEW.md for the direct code review. The requested “ponytail install” skill
  was not found; its exact name/link is still needed to apply that specific skill.

## Build 23: use the native keyboard background

- Removed the inset regular-material fill and border from the SwiftUI transition logo.
  The hosting view and cover are transparent; hidden keyboard controls do not bleed
  through. iOS supplies the background color and outer rounded shape directly.
- Signed Debug Simulator and iPhone builds passed. Build 23 installed and launched
  normally on the connected iPhone. No speech/session logic changed.
- Recorded navigation-only Simulator tests in light and dark appearance show the logo
  on one continuous keyboard surface, without the differently tinted inset card. Both
  return to the same seeded Messages conversation. This bypasses speech recognition
  and is not a new physical speech or haptics test.
- A transient light keyboard snapshot appeared after changing Simulator appearance
  from light to dark. The settled dark surface matches; cross-appearance snapshot
  behavior is not claimed resolved by the color change.
- User confirmed build 22 still moves top to bottom in Notes. The return recording
  still shows an oversized system keyboard frame before settling. No new animation
  fix is claimed; native host-window/backdrop motion remains unresolved.
- Microphone remains off between dictations and starts only from an explicit dictation
  action. Existing startup, checkmark, cancel, local recognition and cleanup are unchanged.

## Build 22: bottom-positioned contents and rounded transition

- Added a fixed-height UIInputView with 260-point sizing and a 248-point content area.
  The controls and temporary cover now use the final view bounds to stay at the bottom
  instead of stretching between top and bottom constraints during remote restoration.
- Traces reproduced temporary 874 / 488 / 716-point system frames before the 260-point
  settled frame. Final layout traces show content Y = frame height - 255 and a constant
  248-point content height, followed by Y=5 after settling. This verifies our content
  geometry; iOS still controls the surrounding keyboard surface and host toolbar.
- The logo cover is now a native SwiftUI regular-material panel with continuous rounded
  corners and transparent outer margins. It is prepared during view creation before
  the first restoration frame, then revealed after the existing return/activation gate.
- Recorded Simulator handoff retained the same conversation and showed the rounded
  panel. The earlier experimental constraint-only change still positioned contents at
  Y=5 in oversized frames; it was replaced by final-bounds positioning before installation.
- User explicitly retained microphone-off between dictations. A bounded real-device
  diagnostic kept the app executing in the background with input initially off and
  attempted restart. iOS rejected audio startup (AVFAudio 2003329396); recording stayed
  false and final input-off was confirmed. Merely remaining alive in the app switcher
  does not make foreground activation avoidable on this tested device.
- Production speech lifecycle and start routing are unchanged. Normal app open does
  not activate input. Only keyboard dictation starts it; check/cancel still shut it down.
- Debug Simulator/iPhone and Release Simulator builds passed. Build 22 installed and
  launched normally after diagnostics. Physical Notes visual check requested, pending.

## Build 21: return to invoking apps without URL navigation

- Removed the destination catalog gate that excluded WhatsApp, TikTok and other apps
  before attempting direct resume. Freshly observed external app identifiers now pass
  directly to the guarded development-only resume call; no app-list entry is needed.
- Removed all URL return fallbacks, including sms://, from both start and finish paths.
  A refused resume leaves the existing manual-return UI instead of opening a new chat.
  Each start clears the previous return target, preventing stale finish navigation.
- A physical test rejected lowercase com.apple.mobilesms and accepted com.apple.MobileSMS.
  Added casing corrections for the installed Messages and WhatsApp identifiers; all
  other identifiers pass through unchanged. A targeted proxy lookup was ineffective
  for a lowercase identifier and was removed before the final build.
- Actual iPhone direct-resume diagnostics accepted Messages, WhatsApp and TikTok.
  WhatsApp test verified lowercase input resolving to net.whatsapp.WhatsApp. These
  diagnostics start no microphone and do not type or send any content; acceptance
  alone does not prove each app's editor/cursor restoration.
- Actual Simulator Messages keyboard-start test returned to the same existing seeded
  conversation, with its keyboard visible. Recorded handoff inspected; no new composer.
  Speech was bypassed by the navigation diagnostic, not simulated as a speech success.
- All 32 delivery/preparation/transition/identifier checks passed. Final Debug device,
  Debug Simulator and Release Simulator builds passed. Release binary inspection found
  no private return class/selector strings. Existing AVAudioPCMBuffer Sendable warnings
  remain in a speech diagnostic; speech implementation was not changed here.
- Build 21 installed and launched normally after diagnostics. User answered “yes” to
  the same-conversation/page check; they did not identify which non-Messages app was
  tested, so this is not recorded as exhaustive per-app validation.
- Return diagnostics retain only the last eight app identifier/resolution/acceptance
  records and timestamps in the shared container. No transcript or message content.

## Build 20: resume the existing host instead of its URL handler

- Added a DEBUG-only LaunchServices resume attempt, retaining the existing scheme
  fallback if unavailable/refused. Only freshly observed, catalogued host apps qualify.
  Runtime class/selector, argument count/type, and BOOL return type are checked.
- The physical iPhone accepted a direct-resume diagnostic targeting Notes. That check
  starts no audio capture and changes no note text. App relaunched normally afterward.
- Simulator diagnostic accepted the direct resume. Recorded keyboard navigation
  returned to the Messages conversation list without opening a new composer. Messages
  dismissed its search field on backgrounding, so this does not establish preservation
  of every editor/field or reproduce the Notes keyboard animation.
- Debug Simulator/iPhone and Release Simulator builds passed. Release binary contains
  none of the private observer/resume class and selector strings. Build 20 installed.
- Physical Notes visual test requested; not yet confirmed. Speech engine unchanged.

## Builds 18–19: keyboard handoff investigation — unresolved visual issue

- User's screenshot and subsequent clarification identify the keyboard surface moving
  from top to bottom while Notes resumes; this is not a verified home-screen flash.
- Build 18 fixed the keys/listening content area to the same size, prepared the layout
  before opening TapType, and added a temporary logo cover. User still saw duplication.
- Verified the physical phone had loaded build 18's actual extension, not an older build.
- Build 19 hides the underlying controls as well as covering them, waits for a matching
  companion return timestamp / host reactivation, and retains coverage while the host
  is inactive. A cancelled-open fallback prevents a permanent cover.
- 28 checks passed: transcript delivery, request preparation, and cover timing including
  slow startup, stale return signals, host inactivity, manual return, and cancellation.
- Signed Debug Simulator/iPhone builds passed. Build 19 installed and launched normally.
- Recorded Simulator navigation confirms outgoing logo coverage and automatic return.
  Messages' URL opens a new compose field with Apple's keyboard, so this does not
  reproduce or validate the physical Notes restoration animation.
- Physical build 19 timing trace confirms coverage until about 0.8 seconds after Notes
  became active (1.27 seconds after the return request on the last recorded attempt).
  The user still reports the moving/doubled keyboard surface. This is NOT fixed.
- The extension's cover is inside the keyboard's moving surface; it cannot cover the
  entire Notes window or control iOS's app-switch/keyboard compositing animation.
- SpeechRecognizer.swift is unchanged from the previously verified microphone-off
  implementation. No idle microphone readiness was reintroduced.
- DEBUG transition diagnostics contain event times and visibility/coverage flags only;
  the return/cover report includes request IDs, not speech audio or transcript contents.

## Builds 15–17: microphone lifecycle, transition, native home

- The user confirmed in build 16 that text inserts and the microphone stops after ✓.
  All six physical microphone checks passed: idle off, active recording, checkmark off,
  restart recording, cancel off, and background idle off. Opening the app no longer
  enables the mic; this supersedes the earlier ten-minute readiness preference.
- Actual Apple Speech PCM fixture produced the known bicycle sentence with final=true
  and no error after the input engine stopped. One run was interrupted; the completed
  repeat was verified after foregrounding. A separate background cleanup test produced
  the cleaned Maya sentence, final=true, notice=none, with microphone-off confirmed.
  The successful diagnostic acquired background time before releasing audio, matching
  production stop(). An earlier diagnostic run terminated before completion.
- All 13 transcript-delivery safeguard checks passed.
- Added a synchronous native window cover for UIKit snapshots and a cold-launch URL
  latch before SwiftUI rendering. A real cold Simulator launch retained the black logo.
  Error/manual-return fallback and deliberate normal opening remain accessible.
- The user still reported a flash. Their supplied 2.93-second device video was inspected
  frame by frame: the logo stays visible while TapType is onscreen; the visible change
  is Notes/keyboard relayout during return. Build 17 holds the logo 0.65 seconds after
  activation before returning, separating the incoming and outgoing system animations.
  This timing improvement is not yet physically confirmed to eliminate the flash.
- Found a separate reproducible Simulator keyboard crash in UUID bridging while its
  host text field disappeared. Read the same public Objective-C documentIdentifier as
  nullable and skip updates when detached. The final replay retained the same keyboard
  process, with no new crash report.
- Replaced the home with a single native SwiftUI Form: Model and Your words menus,
  setup steps, FAQs, and clearly labeled future model options. Removed the test field.
  Verified Rewrite/Clean up selection updates, setup and FAQ expansion, and that the
  cloud placeholder cannot change the active local provider. Restored Clean up afterward.
- Debug iPhone and Simulator builds passed for build 17. Physical device installed and
  launched normally, without diagnostic arguments. Existing speech implementation from
  verified build 16 is unchanged in build 17; only home UI and return timing changed.
- Preview: TapType-v17-home.png. Source archive: TapType-keyboard-dev.zip.

## Builds 13–14: Apple Intelligence, transition, capitalization, spacing

- Added on-device Apple Foundation Models cleanup with Original / Clean up / Rewrite
  selection. Default is Clean up. Apple Intelligence reported ready on iPhone 15 Pro.
- Real model tests removed fillers, retained Maya / 3 / 250 and negations, and left
  questions as questions. An initial adversarial transcript was incorrectly answered;
  revised instructions/examples plus conservative numeric, negation and word-retention
  checks fixed the tested case. These tests do not prove general semantic fidelity.
- Real background test while Notes was foreground produced the cleaned sentence with
  final=true and no fallback notice. No user text was used in diagnostic logs.
- Real live-buffer Apple Speech fixture followed by cleanup produced the known bicycle
  sentence, final=true, with no error. This uses actual speech recognition on known PCM.
- Cancellation prevented later insertion. A deliberately slow processor exercised the
  actual eight-second fallback: final original text was retained, with no late overwrite.
  Empty output, changed digits, dropped negation, and answer-like replacement checks passed.
- All 13 delivery safeguard checks passed. Debug Simulator and iPhone builds passed;
  Release build passed for build 13's availability-gated implementation. Build 14 changes
  spacing and adds the timeout diagnostic. Build 14 installed and launched normally.
- Keyboard opens with uppercase labels; typing T inserted T and changed labels to
  lowercase. The temporary test character was cleared. Balanced toolbar spacing was
  visually verified in Messages; preview saved as TapType-v14-keyboard.png.
- Removed the timer that exposed home during handoff. A generation token rejects stale
  activation work. Only a normal subsequent activation or explicit user action reveals
  home. Recorded Simulator frames show only the logo during the app switch, then Messages.
- Speech error UI was inspected during Simulator model failure: plain-language recovery
  message, no error domains/codes. Technical codes remain only in DEBUG logs.
- User confirmed the final physical Notes test: “Cleanup works and no home-screen flash.”
  This verifies filler removal during live dictation and the force-closed-app transition
  on the connected iPhone, in addition to the diagnostics above.

## Build 12: warm microphone and logo handoff

- User explicitly changed microphone preference to a ten-minute ready session,
  discarding idle audio. This supersedes the build 6 stop-after-✓/cancel behavior.
- The ready period renews when readiness or a new dictation starts. Background
  polling and microphone input continue, but the audio sink has no recognition
  request between dictations. Expiry, interruption and manual stop release input.
- A shared timestamp identifies an incoming keyboard handoff before the home screen
  is displayed. The system launch screen and in-app transition are black with the
  waveform logo. The normal home/listening screen remains available on normal opening
  and as fallback when return fails. App snapshots also use the logo screen.
- Signed iPhone and Simulator builds passed. Build 12 installed on the iPhone.
- Seven physical-device lifecycle diagnostics passed: ready with no capture;
  background-handler readiness; live capture; ready without capture after check;
  ready without capture after cancel; forced expiry shuts input down; manual stop
  shuts input down. Expiry used the actual timer branch with an expired deadline,
  not a ten-minute wall-clock wait.
- User physically confirmed: second dictation stays in Notes, and starting after
  force-closing shows only the black logo before returning (“Both behaviors work”).
- Actual Simulator handoff recording inspected frame by frame: logo-only screen,
  then automatic return to Messages. Its sms:// URL opened an empty compose screen,
  so exact restoration of arbitrary host views is still not guaranteed. No message
  was sent. The Simulator diagnostic bypasses recognition only, not navigation.
- Local AI cleanup and model downloads are proposals, not implemented in this build.

## Builds 9–11: return, controls, and haptic follow-up

- OpenWhispr's official source uses an undocumented UIKit currentState observer
  plus a bundle-to-URL-scheme catalog. Added a bounded DEBUG-only adaptation with
  fresh host checks, no guessed destinations, and manual fallback. MIT credit included.
- Simulator return test did not expose a fresh host; fallback worked. The first
  test also caught an activation timing error, which was fixed before installation.
- User confirmed automatic return on iPhone build 9: “Returns automatically; no
  cancel vibration.” This confirms navigation on that device, not every host app.
- Build 11 adds a haptics-only Core Haptics playback attempt with UIKit fallback.
  User confirmed cancel vibration on the physical iPhone in build 11. Simulator
  itself cannot verify tactile output.
- Replaced the microphone control with a branded TapType button; removed connection
  hint and idle hide-keyboard button. Active × and ✓ remain matching 44-point targets.
- Corrected the ready button's layout from autoresizing to explicit edge constraints.
- Added ✓ and × to the companion listening screen. ✓ commits the pending request,
  releases input, waits for final recognition, and attempts return to the captured
  host. Cancel clears that request. User confirmed that the in-app checkmark
  inserts the sentence back into Notes, and that cancel vibrates (“Both work”).
- Build 11 iPhone and Simulator Debug builds and Simulator Release build passed.
  Build 11 installed and launched on the connected iPhone 15 Pro.
- Visually verified build 11 in Simulator Messages: idle toolbar has the branded
  button and no hide-keyboard button; active × and ✓ fit their compact slots.
  Synthetic UI fixture start/cancel returned to keys with an empty search field.
  The fixture was stopped and its state cleared afterward.
- Release binary inspection found no private observer class/selector/log strings.
- All 13 delivery safeguard checks passed. Recognition remains on-device Apple
  Speech with punctuation; no separate AI cleanup/rewriting pass exists.

## Build 8 keyboard haptic routing

- User reported haptics working in TapType but missing when its keyboard is used
  in Notes or Messages. Physical cause is not yet conclusively established.
- On iOS 17.5+, attached both feedback generators to the keyboard action slot
  with UIKit's view-based initializers; prepare after the keyboard appears.
- Replaced the reconnecting Link's tap-ended gesture with a press-aware button
  style, requesting feedback before navigation starts. Existing mic/check sounds remain.
- Signed iPhone and Simulator builds passed. Build 8 installed on iPhone 15 Pro.
- Simulator Safari checks logged start feedback for the reconnecting mic, start
  feedback for the active keyboard mic, and finish feedback for ✓. Each request
  reported visible=1, attached=1, fullAccess=1. These logs contain no typed content.
- Reconnecting mic still opened TapType. Synthetic host UI test completed start,
  commit, final-result insertion, and clear. The test text was not submitted as a search.
- Simulator cannot verify physical vibration. This is a candidate fix pending a
  physical Notes/Messages haptic check, not a claim that the hardware output passed.
- Letter-key haptics are not implemented. This update addresses the requested
  microphone and checkmark controls. No audio capture or recognition changes.


## Build 7 keyboard background and appearance

- Reproduced the reported layering in Safari: an opaque rectangular extension
  background covered part of iOS's rounded keyboard surface and differed from its footer.
- Removed that opaque background. The extension now draws its controls over the
  system-provided surface, leaving iOS's rounding and bottom controls intact.
- Matched control colors to the actual keyboard window's light/dark appearance.
  Diagnostics found the text proxy reporting dark while Safari's keyboard window
  was light. TapType's dark test screen correctly supplied a dark window.
- Recreate the microphone Link when its appearance changes, and include the
  required globe-key state in the layout cache when switching hosts.
- Signed iPhone and Simulator builds passed. Visually verified Safari light and
  TapType dark keyboards, rounded corners, matching toolbar icons, and number layout.
  Tapping letter keys entered “tap” into the companion scratchpad.
- Build 7 installed on the connected iPhone 15 Pro. Physical appearance in other
  apps has not yet been user-confirmed; the visual checks above used Simulator.
- Saved actual Simulator previews: TapType-v7-light-keyboard.png and
  TapType-v7-dark-keyboard.png. No synthetic host was used for these visual checks.
- Recognition and delivery logic is unchanged from build 6. This remains a custom
  key layout; it does not embed or augment Apple's system key grid.


## Build 6 local recognition and microphone lifetime

- Both live and audio-file recognition explicitly require on-device Apple Speech.
  Removed the online setting and online diagnostic override. Locale remains en-US.
- Opening TapType prepares microphone input. Leaving it idle releases input;
  only active dictation continues in the background. ✓ and cancel release input.
- After ✓, final recognition has a bounded background task and eight-second deadline.
  Final results can be inserted after the companion microphone stops or the app suspends.
- Signed iPhone and Simulator builds passed. Build 6 installed on iPhone 15 Pro.
- Physical iPhone engine diagnostics passed: input started; input off after stop;
  input restarted; input off after cancel; idle readiness started; input off after
  invoking the background lifecycle handler.
- Actual Simulator Home transition independently changed microphoneActive from true
  to false and heartbeat to zero. Settings showed local-only recognition and no Resume button.
- Physical iPhone on-device file recognition produced the complete known sentence:
  “The purple bicycle is parked beside the yellow house”.
- Physical iPhone live-buffer recognition also produced that sentence with a final
  result and no error after input was immediately released. This uses known PCM
  through the real live recognizer; it does not inject a transcript.
- The speaker-to-microphone sample did not produce text in this run. Microphone
  engine shutdown passed, but this run does not establish acoustic recognition.
- Thirteen executable delivery checks passed, including delivery after microphone
  shutdown and preserving the checkmark requirement after companion suspension.
- Simulator delivery-only replay passed with an explicitly synthetic final result,
  heartbeat zero, and microphoneActive false: Ready to insert appeared; ✓ inserted
  the complete sentence into the scratchpad and restored the keys. No transcript
  was inserted before ✓. This is a UI check, separate from the real recognition tests.

Build 6 replaces the previous idle background readiness behavior. The next mic tap
in another app can reopen TapType. Automatic switchback remains unimplemented;
return with the bottom-edge swipe or the system back-to-app link. The full physical
keyboard flow was user-confirmed on build 3; it has not yet been re-confirmed on build 6.

## Build 5 tap feedback

- Microphone taps play a 150ms rising tone and a medium impact haptic, including
  the reconnecting SwiftUI Link that opens the companion app.
- Checkmark taps play a distinct 250ms finish chime and success haptic immediately.
  Removed the previous delayed insertion chime to avoid two feedback events.
- Enabled AVAudioSession's allow-haptics-and-system-sounds-during-recording option.
- iPhone and Simulator builds passed. Both nonempty, unclipped PCM sound resources
  were verified in the signed keyboard bundle.
- Verified the reconnecting mic still opens TapType with the new simultaneous tap
  feedback gesture; the known Simulator model error followed as expected.
- Build 5 installed and launched on the connected iPhone.
- Audible volume and physical haptic sensation require device-side verification;
  Simulator cannot establish physical haptic behavior. Silent Mode/settings apply.

## Build 4 UI update

- Reduced the keyboard from 300 to 260 points and key labels from 25 to 22 points.
- Mic, checkmark, keyboard-dismiss, and cancel icons share a 20-point symbol configuration.
  Toolbar tap targets remain 44 × 44 points. Removed the large mic/checkmark disks.
- Removed Pause/Resume from the primary app screen. Optional Stop microphone lives
  inside the setup/settings disclosure. Automatic readiness still works on app open.
- App and both extensions built successfully for Simulator and physical iPhone.
- Simulator launch showed Ready when you are with no Resume button.
- Visually verified compact letter/number layouts and the matched mic/keyboard controls.
  Verified Stop microphone exists only in settings and does not reveal a Resume button.
- Build 4 installed and launched on the connected iPhone.

The behavior checks below were completed on build 3; build 4 changes presentation
and the location of the optional stop control, not the recognition/delivery pipeline.

## Delivered

- Native-style QWERTY and number/symbol layouts with one microphone icon.
- Listening screen with cancel, checkmark, and a waveform driven by microphone RMS levels.
- Checkmark finalizes speech and inserts the entire successful result once; no Insert button.
- Distinct bundled sounds and haptics on microphone/checkmark taps (build 5).
- Opening TapType automatically prepares the microphone; no Enable Session step.
- Inactive keyboard mic opens TapType and starts dictation using a public SwiftUI Link.
- Dynamic Island / Lock Screen Live Activity for readiness, listening, and finishing.
- Opaque 1024 × 1024 waveform app icon, verified on Simulator Home Screen.

## Verified

- Final signed app, keyboard, and Live Activity extension build for iPhone and Simulator.
- Final build installed and launched on the connected iPhone 15 Pro.
- App and keyboard signed entitlements contain the same approved App Group.
- Final build's real on-device Apple Speech recognized the bundled synthetic audio on iPhone:
  “The purple bicycle is parked beside the yellow house”.
- Live microphone capture and nonempty recognition were verified on the earlier build.
- User reports the build 3 mic opens TapType and dictation works inside the app.
- User confirmed the physical keyboard inserts the dictated text after tapping ✓
  following the manual return, and the next mic tap stays inside the keyboard.
- In Simulator, opening the app automatically showed readiness; the Live Activity
  appeared in Dynamic Island when switching to Safari.
- Pausing the microphone, returning to Safari, and tapping the keyboard mic opened
  TapType and started a real recognition attempt. The known Simulator model error followed.
- Synthetic UI test: mic → listening waveform → checkmark → Finishing → entire test
  sentence inserted in Safari → keyboard restored. The command log recorded
  start, commit, final-result delivery, and clear acknowledgment.
- Synthetic UI cancel test: mic → cancel restored the keys without adding text.
- Eleven executable delivery checks passed: successful final insertion; no insertion
  before checkmark; no partial/failed/processing/stale results; no replay; no automatic
  insertion into another field; expiry; cancellation; persistence across reload.
- Keyboard launch testing caught and fixed a layout-constraint crash before delivery.

The synthetic UI test supplied an explicit fake host/result and synthetic waveform
levels. It verifies the keyboard interaction and delivery, NOT speech recognition or
live audio sensitivity. The iPhone audio-file test uses the real recognizer. No ambient
speech transcripts are included in this report.

## Limits / remaining physical checks

- The iOS 26.5 Simulator's local speech model still fails with kLSRErrorDomain 300.
  It is not a passing environment for actual dictation.
- Automatic return to an arbitrary previous app is NOT implemented. Return with the
  bottom-edge swipe or system back-to-app link. With build 6, finishing/cancelling
  releases input, so the next dictation can require opening TapType again.
- The physical keyboard → dictation → checkmark → insertion flow is user-confirmed.
  Physical waveform responsiveness and the audible completion chime were not separately
  confirmed; the former uses actual microphone levels and the latter is bundled.
- Live Activity rendering was visually checked in Simulator; physical rendering can
  depend on device settings. The Island waveform is a status icon, not a live audio meter.
- There is no autocorrect, predictive text, or swipe typing in this development keyboard.

Model: on-device Apple Speech only, en-US. Build 6 removes online processing.
No Whisper or cloud AI model is used.

Apple's developer-support discussion of the missing public host-app return mechanism:
https://developer.apple.com/forums/thread/826851

Use the updated TapType-keyboard-dev.zip. Earlier prototype/in-progress archives and
build 1/2 screenshots are superseded. TapType-v3-listening-fixture.png is explicitly
a synthetic UI preview; TapType-v3-keyboard.png shows the actual rendered keyboard.
