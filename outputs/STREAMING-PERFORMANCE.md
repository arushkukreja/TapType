# TapType build 34 — measured performance

**Live Notes test passed:** the user confirmed a preview while speaking and one
insertion. From ✓, speech finalized in 0.269 s, cleanup finished in 1.445 s, and the
keyboard inserted at **1.509 s**. The roughly 15-second recording showed its first
preview 3.021 s after capture began. App footprint was 28.7 MiB; thermal stayed nominal.

Tested November 8, 2026, on the connected iPhone 15 Pro. These are observed samples,
not speed guarantees. Synthetic speech was paced in real time through the actual
model services. The short Apple controller tests also ran AVAudioEngine; they fed
known audio instead of ambient microphone samples for repeatability.

| Pipeline | First visible text | Stop → cleaned text |
| --- | --- | --- |
| Apple SpeechAnalyzer + Foundation Models, three short trials | 1.16–1.41 s after capture | 0.69–1.38 s |
| Apple, one-minute/165-word recording | About 1.15 s after audio starts | 0.55–0.57 s |
| Whisper Base, one-minute recording | 20.90 s (12-second first clip plus cold load) | 2.02 s |
| Configured OpenAI gpt-transcribe + streamed cloud writing, short trial | After the phrase was committed | 2.10 s |

Whisper is currently a phrase adapter; Apple Speech gives much earlier visible text.

The one-minute Apple workload made 14 phrase-cleanup requests during recording.
It used 30.6–34.0 MiB app physical footprint and 4.4–5.2% mean CPU of one core.
These app-only figures exclude separate iOS speech/model processes.

A 93.18-second Power Profiler capture covered the Apple workload and surrounding idle
time. Thermal stayed nominal; TapType’s mean relative CPU/GPU impact was 0.365/0.064,
with no networking impact. These are Instruments units, not watts. Whole-device
estimated discharge averaged 15.75%/hour in this short, screen-on profiling window;
that includes system activity and profiling and cannot predict app battery life.
MetricKit collection is enabled for later aggregates. No joule measurement is claimed.

The OpenAI test ledger recorded 2.83325 seconds of submitted speech and a cleanup
response of 109 input / 10 output tokens, both confirmed. Idle audio is discarded;
submitted cloud audio can still cost money after cancellation. Historical expensive
live-model entries remain in the ledger, but that model is no longer selectable.

Groq has no key saved on this device, so live service timing and billing are unverified.
No new fully offline test or 30-minute soak was completed. Fixture timings exclude host insertion. The separate live Notes measurement above
includes the keyboard’s insertText call.
