<p align="center"><img src="docs/app-icon.png" width="128" alt="TypeLikeMe icon"></p>

# TypeLikeMe

Voice typing for macOS, powered by [Sarvam AI](https://sarvam.ai). Hold **fn**, talk, let go, and clean, well-formatted text appears wherever your cursor is: Slack, Mail, Zed, Cursor, Terminal, the browser, anywhere.

- **Native and small.** Swift, SwiftUI and Metal, with one dependency (FluidAudio, for Parakeet). The app is about 15 MB and idles at 0% CPU. The mic is only on while you're dictating.
- **Fast, and private if you want it.** Speech can run on your Mac with NVIDIA Parakeet (about 0.1 s) or in the cloud with Sarvam. Formatting can run on your Mac with Google's Gemma 4 or in the cloud with Sarvam.
- **Indian languages and code-mixing.** Auto-detects English, Hindi, Tamil, Telugu, Bengali and more. Output can be native script, English translation, Hinglish or romanized.

## Controls

| Action | Keys |
|---|---|
| Push-to-talk | hold `fn`, speak, release |
| Hands-free | double-press `fn`, press once more to insert (or click the red stop square) |
| Command mode | hold `fn` + `⌃` and say "make this more formal" to rewrite the selection, or "write a polite decline" to write new text |
| Cancel | `esc` |
| Paste last dictation again | `⌃⌘V` |

A single quick press of `fn` does nothing, so a stray press never leaves the mic on. Right ⌥, right ⌘ or right ⌃ can be used as the trigger instead of `fn`.

## Setups

On first launch, Home shows **Choose your setup**: the four setups below compared on one time scale. You can open the comparison again any time under Settings → Compare setups and speeds.

| Setup | Speech | Formatting | Time per dictation* | Disk | Memory | Privacy |
|---|---|---|---|---|---|---|
| **Fastest** | Parakeet (this Mac) | off | ≈ 0.1 s | 485 MB | ≈ 60 MB | private |
| **Smart and private** (recommended) | Parakeet (this Mac) | Gemma 4 E4B (this Mac) | ≈ 1.0 s | ≈ 7.2 GB | ≈ 5 GB | private |
| **All Gemma** | Gemma 4 E4B (this Mac) | Gemma 4 E4B (this Mac) | ≈ 3.5 s | ≈ 6.7 GB | ≈ 5 GB | private |
| **Cloud** | Sarvam `saaras:v4` | Sarvam `sarvam-105b-conversations` | ≈ 0.9 s | 15 MB | ≈ 50 MB | cloud |

\*For a 7.5-second dictation on a MacBook with Apple M4 (24 GB), with models already loaded.

- **Parakeet** (NVIDIA `parakeet-tdt-0.6b-v3`, run through [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Neural Engine) downloads automatically on first use (469 MB). It covers English and 24 European languages. For Hindi and other Indian languages, use Sarvam for speech.
- **Gemma 4 E4B** runs through [Ollama](https://ollama.com). Install Ollama (0.31 or later), then run `ollama pull gemma4:e4b-it-qat` (6.1 GB). The QAT build is about twice as fast on Apple Silicon as the default `gemma4:e4b`. Any OpenAI-compatible server (LM Studio, mlx_lm, llama.cpp) also works: set it under Settings → Intelligence.
- **Sarvam** needs an API key (see below).

## Features

- **Pixel bar.** A thin bar on the bottom edge built from crisp square pixels. Pixels stream in from both sides of the screen as you start. Your voice shows as a dithered waveform whose newest sound glows red-hot in the centre, with sparks breaking off on loud moments. A scanner sweeps while Sarvam works. Then a red block cursor types your words in a hand-drawn pixel font, and the letters lift off as the real text pastes. Drag the bar to dock it bottom-left, centre or bottom-right. It moves aside on its own if your text cursor is underneath it. Settings → Particle effects (or macOS Reduce Motion) switches to plain level bars.
- **Prompt mode for AI tools.** In Claude Code, Codex, Cursor, Zed, VS Code, ChatGPT and Claude, dictation is cleaned into a clear prompt. Grammar is fixed, misheard tech terms are corrected (`useEffect`, Supabase, `gh`), and code terms go in backticks. Three or more asks become a numbered list. It edits rather than reinterprets: questions stay questions, replies stay replies, and nothing you said is dropped.
- **Instant formatting, no AI needed.** With formatting set to Instant (the default for on-device speech), a rule-based formatter runs on your Mac in a few milliseconds. It removes fillers and stutters, applies "no wait" / "sorry, I mean" / "scratch that" corrections, follows "new line", "new paragraph" and "question mark", turns "first…, second…, third…" and spoken lists ("make a list for my groceries… apples, bananas, milk") into lists, writes numbers, money, times, dates, emails and domains the way you'd type them ("fifty percent" → 50%, "three thirty pm" → 3:30 PM), and spells developer terms correctly in coding tools ("super base" → Supabase, "dot env" → .env). It only edits your own words, so it can't answer or invent anything. URLs, paths and code are left exactly as said. `Tests/formatter-cases.json` holds its test cases; the build won't install if one fails.
- **Smart formatting everywhere else.** Lists you speak become bullet points, and steps become numbered lists. Long thoughts are split into paragraphs, and emails get a greeting, body and sign-off. Bullets are "-" in Markdown apps and "•" in Mail, Slack and WhatsApp.
- **Writes like you'd type it.** It reads the text before your cursor, so a dictation continues the sentence with the right spacing and capitalization. It also applies self-corrections ("tomorrow, no wait, Friday" becomes "Friday") and writes numbers, times, money and emails the way people type them.
- **Hears your jargon.** Your Dictionary words, plus common coding terms when you're in an AI tool, are sent to Sarvam as keyterms so they're transcribed correctly.
- **Nothing gets lost.** If no text field is focused, the text isn't pasted into nowhere. It stays on your clipboard and a card shows it with a Copy button. `⌃⌘V` pastes your last dictation anywhere, any time.
- **No emoji popup.** fn is freed from the 🌐 emoji picker using the same system call System Settings uses, so it applies without logging out.
- **Dashboard.** A Raycast-style window showing words dictated, words per minute, time saved, streak, a 14-day chart and searchable history (with the original transcript one click away), plus Dictionary, Style and Settings. Everything stays on your Mac.
- **Your clipboard is safe.** It's restored right after each paste.

## Build and install

Requires macOS 14 or later on Apple Silicon and Xcode command-line tools. A [Sarvam API key](https://dashboard.sarvam.ai) is needed only for the Cloud setup, or if you use Sarvam for speech or formatting.

```bash
cp .env.example .env          # optional: put your Sarvam key in .env
./scripts/build-app.sh        # builds, signs, installs to /Applications, launches
```

The build script signs with your Apple Development identity if you have one, so macOS keeps the Microphone and Accessibility permissions across rebuilds. Without one, it signs ad-hoc.

On first launch the dashboard shows a short checklist: API key, Microphone, Accessibility, and freeing the fn key.

Your key is copied to `~/Library/Application Support/TypeLikeMe/config.json` (mode 600). It is never compiled into the app, and `.env` is git-ignored.

### Dev helpers

```bash
swift build -c release
.build/release/TypeLikeMe --selftest some16kmono.wav                          # headless Sarvam pipeline test
.build/release/TypeLikeMe --format "um so we ship friday" - Slack com.tinyspeck.slackmacgap   # formatting check
TYPELIKEME_PILL_DEMO=1 .build/release/TypeLikeMe                              # loop the bar animation (no mic, never pastes)
TLM_SPEECH=parakeet .build/release/TypeLikeMe --selftest clip.wav             # speech engine: parakeet | local (Gemma) | default Sarvam
TLM_ENGINE=local .build/release/TypeLikeMe --format "..." - Zed dev.zed.Zed   # format with local Gemma instead of Sarvam
.build/release/TypeLikeMe --parakeet-bench clip.wav 20                        # Parakeet load time and speed
TYPELIKEME_DEMO=1 .build/release/TypeLikeMe                                   # dashboard with sample data
.build/release/TypeLikeMe --test-formatter [--history]                        # instant formatter tests (+ audit of your saved dictations)
.build/release/TypeLikeMe --format-local "um so first clone it, second build it and third ship it" dev.zed.Zed
# diagnostics log: ~/Library/Logs/TypeLikeMe.log (never contains your key)
```

## Layout

```
Sources/TypeLikeMe/
  main.swift                   app entry, menu bar, windows, CLI helpers
  Core/
    AudioRecorder              16 kHz capture, live levels, WAV encoding, chunking at pauses
    SarvamClient               speech-to-text (keyterms), formatting, Prompt mode, command mode
    ParakeetEngine             on-device speech recognition (Parakeet via FluidAudio)
    LocalLLM                   local models via Ollama or OpenAI-compatible servers (Gemma 4)
    DictationController        hold / double-press / command / cancel state machine and pipeline
    HotkeyMonitor              event tap for fn and modifiers on its own thread
    CursorContext              text before the cursor, caret position, text-field detection
    TextInserter               paste at the cursor and restore the clipboard
    Settings, Store, Permissions, Log
  UI/
    PixelField                 Metal pixel-grid renderer (wave, scanner, typed words)
    PixelFont                  hand-drawn proportional pixel font
    PillOverlay                the dictation bar
    CopyCard, FlightPanel, Theme
  Dashboard/                   Home, setup chooser, History, Dictionary, Style, Settings
```
