# TapType vs Wispr Flow vs Granola: iPhone dictation

Compared November 21, 2026. TapType details come from its source. Wispr Flow and
Granola details come from their own docs and App Store listings, not hands-on
testing.

## Summary

TapType is the only one of the three that works offline and keeps your audio on
the phone. Wispr Flow is ahead on features: languages, a dictionary, snippets and
app-aware styles. Granola's iPhone keyboard is a free beta added to its
meeting-notes app, with features close to Flow's.

| | TapType | Wispr Flow | Granola |
|---|---|---|---|
| Where speech is processed | On the iPhone by default (Apple's speech engine). Whisper Base/Small also on the phone. OpenAI or Groq only if you choose them | Always in the cloud. Needs a network and a sign-in, or shows "No Network" | Not stated in its docs |
| Text while you speak | Yes, about 1.2–1.4 s after you start | Not documented for iOS | Optional "Live typing", off by default |
| Stop → text inserted | 0.5–1.5 s measured on an iPhone 15 Pro | Not published | Not published |
| Cleanup | Original, Clean up or Rewrite, done on the phone. Falls back to your exact words if numbers, negations or most words change | Styles (Formal, Casual, very casual, Excited!). On iOS one default style for everything, English only | Per-app capitalization and punctuation styles |
| Custom words | No (on the roadmap) | Dictionary plus misspelling fixes, synced across devices | Dictionary |
| Snippets / voice commands | No | Snippets on iOS. Command Mode mainly desktop, editing broken on iOS | No |
| Languages | English (US) only | 100+, auto-detects 23 | 32, with auto-detect |
| Longest recording | 30 minutes | 5 minutes on iOS. Calls and headset changes stop it | Not stated |
| Return to the app you were in | Only an experimental debug build; normally you swipe back yourself | Opens Flow, then sends you back once it can tell which app you came from, with a one-time alert | Opens Granola on first use, then returns you to your app |
| Mic stays ready | Keep ready for 1–10 minutes or until you end it | Style choice sticks for 15 minutes; mic readiness not documented | Not documented |
| Privacy | Audio never saved, history only on the phone, nothing sent to the cloud unless you pick a cloud model | Audio sent to its servers. Its zero-retention Privacy Mode is off by default | Meeting audio deleted after transcription. Voice typing not specified |
| Price | Free; cloud models bill your own API key | Weekly free word limit, then Pro | Free beta |

## Where TapType wins

- It works offline and keeps audio on the phone.
- You choose the speech model.
- Rewrites can't silently change your numbers or negations.
- Its recording limit is six times Flow's on iOS.
- It has measured speed numbers, which neither competitor publishes
  ([STREAMING-PERFORMANCE.md](STREAMING-PERFORMANCE.md)).

## Where TapType is behind

- **Custom vocabulary.** Both competitors have it. It's the biggest gap for names
  and jargon.
- **Languages.** TapType is English-only.
- **Getting back to your app.** Both competitors return you automatically on
  recent iOS. TapType still has you swipe back
  ([RETURN-INVESTIGATION.md](RETURN-INVESTIGATION.md)).
- **Per-app styles.** Flow offers several styles but uses one default on iOS;
  Granola sets formatting per type of app.

## Caveats

- Granola doesn't say whether voice typing runs in the cloud or on the phone.
- Flow's Command Mode article lists only Mac and Windows but has an iOS section,
  so treat iOS support as partial.
- The lldb logs in `work/` only attach to TapType's own processes, so they hold
  no evidence about either competitor.

## Sources

- [Wispr Flow iPhone keyboard setup](https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone)
- [Adapting to iOS 26.4](https://docs.wisprflow.ai/articles/6269634092-adapting-to-ios-26-4?lang=en)
- [Flow Dictionary](https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary)
- [Flow Snippets](https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets)
- [Flow Styles](https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles)
- [Flow Command Mode](https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode)
- [Flow languages](https://docs.wisprflow.ai/articles/3191899797-use-flow-with-multiple-languages)
- [Flow privacy](https://wisprflow.ai/privacy)
- [Flow security overview](https://docs.wisprflow.ai/articles/3147443438-security-overview)
- [Wispr Flow on the App Store](https://apps.apple.com/app/id6497229487)
- [TechCrunch on Flow for iOS](https://techcrunch.com/2025/06/03/wispr-flow-releases-ios-app-in-a-bid-to-make-dictation-feel-effortless)
- [Granola voice typing on iPhone](https://docs.granola.ai/help-center/voice-typing/iphone)
- [Granola iPhone transcription](https://docs.granola.ai/help-center/ios/transcription)
