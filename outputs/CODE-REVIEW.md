# Build 57 — Ponytail review

The recommendation is confirmed by device evidence. A 16.63-second dictation created
only one 1.083-second OpenAI speech turn, matching the old code path that discarded
all active-dictation buffers until a fixed RMS threshold was crossed. History stores
the finalized original, so the writing cleanup did not shorten a longer transcript.

The root fix is limited to `OpenAIStreamingSpeech`: every nonempty encoded chunk now
opens or continues the current turn and is sent to OpenAI. The same RMS calculation
can end a phrase only after voice has been detected; otherwise the existing 12-second
cap or Finish commits the quiet turn. This prevents destructive gating without the
silent 0.65-second commit churn that a naive guard removal would create. The usage-ID
creation path also rechecks cancellation after its actor hop so it cannot leave an
unlabelled entry.

Idle readiness remains detached from the streaming sink, so it is still discarded
locally. Apple Speech, Whisper, Groq, cleanup, ordering, keyboard layout, sounds,
haptics, history, Keychain credentials, and saved settings are untouched. The intended
tradeoff is that OpenAI usage now reflects all explicit-dictation audio, including
pauses and cancelled audio already sent.

Review found no remaining issue in the changed production path. The physical quiet
fixture verified 20.0 seconds uploaded as two confirmed turns and recovered 50 words.
Residual verification is one ordinary quiet microphone dictation and insertion; the
fixture cannot validate acoustic capture or automatic return. The unrelated DEBUG
cost-test body-capture assertion remains test-harness cleanup, not a production failure.

# Build 56 — Ponytail review

This changes only the idle gear's stack position and background. With the inactive
cancel control hidden, the gear is the first visible arranged subview and therefore
sits at the far left. When dictation becomes active, the gear hides and × becomes the
first visible control. The trailing TapType/✓ action and flexible status label retain
their existing behavior.

The UIKit gear remains decorative and noninteractive beneath the same 44-point SwiftUI
home-link overlay, so there is one VoiceOver element and no new launch or dictation
path. Its dynamic `UIColor.label` background adapts to light and dark appearances.
Review found no actionable concerns; Debug/Release compilation and six focused tests pass.

# Build 55 — Ponytail review

The Build 54 bottom rail is reverted. Build 55 restores the Build 53 toolbar order,
spacing and branded TapType capsule, then adds one isolated gear slot immediately to
its left. UIKit draws the gear; a transparent SwiftUI `openURL` layer performs the
extension-compatible `taptype://home` launch. That layer has no access to the dictation
prepare/start callbacks and writes nothing to the shared bridge.

The gear hides whenever preparing or a ticket is active, preserving the original
× / status / ✓ active layout. The app validates the custom scheme and resets all
subpage/sheet navigation before revealing home. Dictation markers, sounds, haptics,
speech, cleanup, delivery and exactly-once insertion branches are unchanged. The short-
height clamp retained from Build 54 is inert at the normal 260-point height and prevents
transition-time clipping.

Debug/Release compilation, six focused tests, signed installation and launch pass.
Physical layout and gear behavior remain the only checks needed for this UI change.

# Build 54 — Ponytail review

This is a layout-only reuse of the existing dictation action, not a second dictation
path. The same `actionSlot` moved below the key panel and changed from a 124-point
labelled capsule to a 44-point waveform icon. Its invisible SwiftUI URL layer still
handles the asleep-app case; the UIKit action still handles ready/start and ✓/commit.
Cancel, sounds, haptics, processing presentation and persisted exactly-once insertion
remain on their existing branches.

The final layout review found one transition-height risk after moving the control to
the bottom. The root content height now clamps to the actual extension bounds, keeping
the bottom rail within the hit-testable view. Top-row key previews stay within bounds,
are noninteractive and retain the separate pressed-key highlight. Debug and Release
builds and the six focused shared tests pass.

Residual risk is physical presentation: iOS owns the footer below the extension, so
TapType cannot literally replace Apple's microphone glyph with a public API. Build 54
puts the TapType action immediately above that footer. Its position and a complete
cold-open/start/finish/cancel cycle still require confirmation on the iPhone. No
equivalent iOS 27.2 Simulator verification is claimed.

# Build 53 — GitHub readiness fixes

The eight upload-review findings are addressed with a source-only, user-data-preserving
change. Repository ignores now exclude the 21 GB `work/` tree and generated source
ZIPs. URL-triggered recording requires a fresh request-bound keyboard marker. The
return resolver's PID cache is monotonic and expires after eight seconds. All three
products derive build 53 from one project setting, and generated Debug/Release plists
were checked. Focused tests are committed outside `work/`. Unused shared preview fields
were removed without changing the internal provisional/finalized pipeline. README and
current reports now distinguish historical simulator/device evidence. New OpenAI setups
default to `gpt-6-luna`; saved model names, Keychain items and priced history are kept.

Residual review risk is narrow but important: automatic return still uses private APIs
in DEBUG and can break on any iOS update. Build 53 compiles in Debug and Release and its
six core tests pass. The signed Debug build was installed in place and launched;
dictation and return behavior have not yet been exercised on that build.
The equivalent iOS 27.2 Simulator remains unavailable because startup stalls. Earlier
reviews below are historical and superseded where they conflict.

# Build 50 — Ponytail review

Moved the existing SwiftUI totals section from TranscriptHistoryView to ContentView, which already observes TranscriptHistory.shared. This preserves updates and formatting without introducing state or changing stored transcripts. No new tests for this presentation-only move; the signed iPhone build passed. Physical visual verification remains unchecked.

# November 8 return investigation — unresolved on iOS 27.2

Physical no-audio handoff tests still fail. The keyboard's host process ID is present, but all tested bundle/scene destination fields are empty; main-app process resolution also fails. Failed experimental hooks were removed and build-44 source restored. See [RETURN-INVESTIGATION.md](RETURN-INVESTIGATION.md) for actual phone evidence and limits.

The general iOS 27.2 Simulator runtime is installed, matching the phone's major/minor OS version. It stalls during system startup before TapType runs, so equivalent-version simulator validation is not complete. Older iOS 26.5 simulator success is not a physical-device pass.

# Build 44 — Ponytail review

Removed the unwanted presentation paths instead of modifying transcription services.
The home is settings-only; original history remains a separate screen. A single UIKit
button draws both connection states, eliminating SwiftUI/UIKit visual differences.
All visible keyboard controls and logos now use UIKit. Only an invisible URL action
uses SwiftUI, preserving the working extension-opening mechanism.

Short mixing playback cues use a process-retained player so insertion-triggered view
recreation cannot stop the finish cue. Playback ends/deactivates after completion or
error; callbacks from a superseded player cannot stop a newer cue. The keyboard never
claims microphone input. Completion is tied to final insertion, not provisional text
or the early checkmark. The existing exactly-once insertion guard also guards the cue.

The user confirmed repeated start/completion sounds and consistent keyboard spacing.
After rejecting the replacement tone design, build 44 restores original WAV samples
with uniform gain only. The gain test checks unchanged sample count, exact proportional
scaling within quantization tolerance, and no clipping. Phone output volume is not changed.
Automatic-return failure remains documented; this pass makes no claim to fix it.

Earlier reviews below are historical and superseded where they conflict.

# Build 41 — Ponytail review

Removed home presentation rather than changing recognition: word counter, completed
text card and editing sheet are gone; existing recording UI was already removed.
Dedicated transcript history remains. Keyboard preview rendering is replaced by
its listening waveform and a pulsing SF Symbol during processing; transcript state
and exactly-once insertion logic remain unchanged.

Sound playback is owned by the visible keyboard, with .playback/.mixWithOthers and
no input category. Its short session is released after completion/error, and stale
player callbacks cannot stop a replacement player. The completion cue follows actual
text insertion, so cleanup latency cannot produce a premature success sound. Media
volume/output route still apply. Simulator visual/insertion/playback checks passed;
physical Silent Mode and microphone coexistence need device confirmation.

Earlier reviews below are historical and superseded where they conflict.

# Build 40 — Ponytail review

The requested companion UI removal and keyboard button alignment are implemented.
The two button implementations now share the same bounds without host safe-area offsets.
No speech, cleanup, cloud, pricing, model or history logic changed.

The physical return regression remains unresolved: UIKit supplies no source bundle,
so TapType cannot select the originating app. Timing, connection, system-navigation
and keyboard-host experiments were tested; unsupported fallback experiments were
removed after failure. The final code retains initial KVO observation, a fresh
request timestamp, self-target rejection and useful failure diagnostics. It does
not treat a cached currentState as a newly observed destination.

Shared tests cover stale/mismatched/future handoff timestamps, host identity and
exactly-once delivery. Simulator return success is explicitly not physical-device
validation. The older and newer original return implementations are identical;
the phone OS differs from early device-build records. OS compatibility is a
hypothesis, not a proven cause. No claim of a fixed physical return is warranted.

Earlier reviews below are historical and superseded where they conflict.

# Build 34 — Ponytail review

Replaced the whole-utterance recognition path with isolated speech/cleanup actors and
one testable text-state value. The controller owns microphone lifecycle, bridge delivery,
history, readiness, and UI. No new dependency or backend. iOS 26 is now required.

Finalized audio ranges alone become cleanup work. Volatile updates remain visible but
cannot replace stable output. Phrase IDs invalidate edits after revised/corrected speech;
a serial worker and Foundation Models busy guard prevent overlapping model operations.
Explicit adjacent self-corrections requeue a bounded pair, avoiding whole-document LLM
passes at Stop. The fallback always preserves confirmed words. Numeric correction
checks reject invented or superseded values, but are not a semantic proof.

OpenAI's cheaper configured transcription model streams PCM with client VAD commits;
commit IDs order results even if acknowledgments arrive out of order. Groq and local
Whisper process bounded completed audio phrases during capture. Cloud writing consumes
SSE progressively and accounts for token usage. Unused paid cloud warmup code was removed. Standby input is discarded before audio copying/encoding/networking; active
cloud audio may already be billed when cancelled. Credentials remain in Keychain.

Audio/result queues are bounded, late events are generation-gated, and cleanup runs
serially. Cancellation while awaiting teardown or microphone activation cannot start
another capture. Background completion is bounded; on timeout only finalized words
survive. Thirty-minute recording and 35-minute delivery limits replace the earlier
55-second/10-minute limits. Existing field-bound, exactly-once insertion remains.

Signposts, CPU/footprint/thermal/battery samples and MetricKit are instrumented. A
physical Power Profiler trace was captured; app-only metrics do not include model
services. Verification details and unresolved test limits are in TEST-STATUS.md.

Real Whisper testing caught per-phrase reload latency and generated transcript tags.
Whisper now retains one model during a dictation, releases it on finish/cancel, and
waits for cancelled decoding before another start. Cleanup removes only its known
outer transcript wrapper, including partial streamed tags; raw history is unchanged. Five-word context windows are rejected if introduced by
cleanup but absent from the current raw phrase, preventing the duplicated context
observed in the long Whisper test while allowing intentional spoken repetition.

Earlier reviews below are historical and superseded where they conflict.

# Build 33 — Ponytail review

Implemented live transcription as one bounded WebSocket session per explicit dictation,
using the current OpenAI transcription configuration and 24 kHz PCM. No new dependencies.
Standby remains at the microphone sink and never feeds a stream. ✓ commits once, and
completion must match the committed item. Cancel/error closes the socket, discards queued
audio, cancels preparation, and invalidates pending recognition/cleanup callbacks.
A new request also closes any previous turn awaiting confirmation after its time limit.

Apple Foundation Models prewarms and reuses a fresh session for each dictation. Cloud
writing preparation uses static text and a one-token cap, with its own cost entry.
Original bypasses both. Cloud preparation is best effort; no cache-hit guarantee.

Cost estimates snapshot the duration price and count submitted streaming PCM including
cancelled/interrupted and last in-flight chunks. Unsent/idle audio is excluded. Backward
ledger decoding, exact final persistence, and cleanup preparation tokens are tested.
Credentials stay in device Keychain; both HTTP and WebSocket transports deny redirects.
No user transcript or key is logged. Timing diagnostics store only an ID and uptime.

Validation and actual latency are in TEST-STATUS.md. Scope excluded new providers,
retry uploads, changing readiness semantics, and a new timing dashboard. No claim of
production App Store readiness: existing private DEBUG host-return code remains.

Earlier reviews below are historical and are superseded where they conflict.

# Build 32 — Ponytail review

Moved cloud-sheet ownership from the dynamic Form section to ContentView's stable
root. The model row receives a binding and refreshes credential availability after
dismissal. No timing workaround or forced re-presentation was added.

New CloudUsage.swift stores only usage metadata and rate snapshots. Requests are logged
before sending, and 2xx responses are accounted for before cancellation, parsing or
cleanup plausibility checks. HTTP/network failures remain unconfirmed with no estimate;
missing rates/tokens do not become zero. Local/Original/connection tests do not log a
billable request. Audio encoding stays off the main actor; ledger writes serialize on it.
Custom rates are validated and persisted, filling only entries with no earlier rate.
Historical priced entries never change when settings change. Corrupt files are kept
and not overwritten; storage failures display a notice without blocking dictation.

Published rates are dated and linked; unknown/enterprise models require a custom rate.
Speech uses provider duration-based estimates rather than pretending audio minutes
are exact billed tokens. Costs are USD estimates, not synced provider invoices. Credits,
taxes, unknown request outcomes and other apps' usage are explicitly outside totals.
All 22 mocked cost checks passed in Simulator and on the iPhone. Visual first-tap
regression checks passed twice in Simulator; live API billing was not exercised.

# Build 31 — Ponytail review

Small SwiftUI layout update: compact scroll margins, consistent primary-color chevrons,
plain home history row, centered history totals and icon-only copy buttons. History
navigation uses a button plus native navigationDestination to allow a white chevron;
copy retains its original pasteboard action and an accessible name with a 44-point target.
No new dependencies or state outside the history navigation flag. Builds and Simulator
visual inspection cover this UI-only change; no audio/provider retesting.

# Build 30 — Ponytail review

Native pickers expose only installed/configured models and show their names without
status labels. Removing the selected local model uses the existing loader's Apple
fallback. Cloud settings retain per-provider drafts; Done validates all drafts before
saving keys to Keychain and models to preferences. Key/model validation has executable
coverage. Cloud persistence across multiple providers is not an atomic transaction;
any write failure keeps the sheet open for retry.

A native DisclosureGroup replaces the model sheet. Uninstall uses the existing guarded
removal path. Cloud providers has a full-row tap target and chevron. Transcript deletion
is removed from the UI and FAQ. Word counts derive from saved original text with Apple's
word tokenizer; no history schema migration. Home total and label are centered.

Device/Simulator builds, Simulator visual checks and physical count/draft/history
assertions passed. No paid API calls or destructive model removal were tested.

# Build 29 — Ponytail review

Five existing native Labels share a compact inline LabelStyle, placing each icon eight
points from its text instead of using the Form icon column. Actions, menu/disclosure
behavior, readiness and history are unchanged. Build and visual checks are appropriate
for this small reversible layout change; no new logic tests.

# TapType build 28 — Ponytail review

Replaced two switches with a single native readiness-duration menu and automatic
Live Activity presentation. Off combines zero minutes and Stay off; default is five
minutes. Unlimited removes the idle deadline (infinity internally) and supplies no
invalid infinite Date to ActivityKit. Manual End session and forced release paths
remain. Saved choices are validated, and diagnostics restore the exact duration.

Idle audio still exits the sink before storage or transcription. The chosen duration
applies at stop; processing cannot extend it. Changing a setting while idle resets
its timer; changing it never starts input. Startup guards remain intact. No model,
credential, original-history or keyboard feedback behavior was replaced.

Home uses a centered inline title, compact native pickers, fewer footers and no
ornamental toolbar action. Model search filters the verified local catalog. Installed
model removal stays explicit in a menu; downloading/cancelling still uses the existing
verified loader. One-line model labels do not truncate the cloud disclosure.

53 policy checks and all physical option assertions passed. Simulator home/menu/search
were inspected. Expiry was accelerated in the new device option test; the previous
full-duration five-minute test remains documented. Rapid diagnostic activity requests
hit the system rate limit; normal ready sessions reuse one activity.

Not checked: long unattended unlimited sessions, extreme Dynamic Type sizes, fresh
model downloads or live cloud calls. Existing Notes cold-return animation and private
DEBUG return limitations remain. Unlimited input consumes battery and is subject to
iOS interruption/termination; Live Activity display remains system-controlled.
