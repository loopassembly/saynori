<p align="center">
  <img src="docs/app-icon.png" width="132" alt="Saynori">
</p>

<h1 align="center">Saynori</h1>

<p align="center">
  <b>Talk. It types.</b><br>
  Voice typing for macOS that's faster than your keyboard and works in every app.
</p>

<p align="center">
  macOS 14+ &nbsp;·&nbsp; Apple Silicon &nbsp;·&nbsp; native Swift &nbsp;·&nbsp; 17 MB &nbsp;·&nbsp; on-device or any cloud
</p>

---

Hold **fn**, say it the way you'd say it out loud, let go. Clean, formatted text lands at your cursor in Slack, Mail, Zed, Cursor, Terminal, the browser, anywhere you can type.

Speech runs **on your Mac** (NVIDIA Parakeet in about 0.1 s) or on **the cloud engine of your choice**. Formatting runs on your Mac in about 2 ms, so the fastest setup never sends a word anywhere.

## You say it messy. It comes out clean.

These are real outputs from Saynori's on-device formatter. No AI model was involved.

**Self-corrections, lists, emails and times:**

```text
you say   Um so for the launch, first fix the login bug, second ship the new onboarding,
          no wait, the new pricing page, and third email priya at gmail dot com before
          three thirty pm.

you get   So for the launch:

          1. Fix the login bug
          2. Ship the new pricing page
          3. Email priya@gmail.com before 3:30 PM
```

**Developer terms, spelled the way you'd type them (in Zed, Cursor, VS Code, Terminal and AI chats):**

```text
you say   Bro, add a use effect hook in the next js app and put the super base key in
          dot env. Then push it to git hub.

you get   Add a useEffect hook in the Next.js app and put the Supabase key in .env.
          Then push it to GitHub.
```

**Numbers, money and percentages:**

```text
you say   We're at twenty k users and the API costs about five hundred dollars a month,
          uh, roughly fifty percent of the budget.

you get   We're at 20k users and the API costs about $500 a month, roughly 50% of the budget.
```

**Spoken lists and changes of mind:**

```text
you say   Hey can you make a list for my groceries? Eggs, milk, bread and coffee

you get   Hey can you make a list for my groceries?

          • Eggs
          • Milk
          • Bread
          • Coffee
```

```text
you say   The demo is on Tuesday. Scratch that. The demo is on Thursday at ten am.

you get   The demo is on Thursday at 10 AM.
```

## Pick your engines

Choose a speech engine and a formatter separately, and switch any time in Settings. Cloud engines use your own API key.

### Speech

| Engine | Where it runs | Speed | Download | Best for |
|---|---|---|---|---|
| **Parakeet v3** (NVIDIA) | Your Mac, Neural Engine | ≈ 0.1 s | 469 MB | English + 24 European languages |
| **Whistle** (Cactus) | Your Mac, CPU | ≈ 0.05 s | 17 MB | English + 6, the smallest footprint |
| **Gemma 4 E4B** (Google, via Ollama) | Your Mac | ≈ 2 s | 6.1 GB | Many languages, fully offline |
| **OpenAI** `gpt-4o-mini-transcribe` | Cloud | | | Accuracy |
| **Google Gemini** Flash | Cloud | | | Accuracy, long dictations |
| **Groq** Whisper large v3 turbo | Cloud | | | Raw speed |
| **Deepgram** Nova-3 | Cloud | | | English, jargon |
| **ElevenLabs** Scribe | Cloud | | | 99 languages |
| **Cartesia** Ink-Whisper | Cloud | | | Low latency |
| **Sarvam** Saaras v4 | Cloud | | | Hindi, Indian languages, Hinglish |

Speeds are for a 7.5-second dictation on an M4 MacBook, with the model loaded.

### Formatting

| Formatter | Where it runs | Speed | What it does |
|---|---|---|---|
| **Instant** | Your Mac | ≈ 2 ms | Everything in the examples above. It only edits your own words, so it can't answer, invent or reinterpret anything. |
| **Gemma 4** | Your Mac | ≈ 1 s | Rewrites into polished prose. Adds Prompt mode and command mode. |
| **OpenAI, Gemini, Groq, Sarvam** | Cloud | ≈ 0.5 s with Sarvam | Same as Gemma, in the cloud. |

### Setups

On first launch, Saynori compares these side by side on one time scale. You can change your setup any time.

| Setup | Speech + formatting | Time per dictation | Privacy |
|---|---|---|---|
| **Fastest** | Parakeet + Instant | ≈ 0.1 s | Nothing leaves your Mac |
| **Tiny** | Whistle + Instant | ≈ 0.05 s | Nothing leaves your Mac |
| **Smart and private** | Parakeet + Gemma 4 | ≈ 1 s | Nothing leaves your Mac |
| **Cloud** | Any provider for each | ≈ 1 s with Sarvam | Audio and text go to the providers you pick |

## What makes it feel right

**It writes like you'd type it**
- Removes "um", "uh" and stutters, and keeps the repeats you meant ("very, very good").
- Follows "no wait", "sorry, I mean", "scratch that", "new line", "new paragraph", "question mark" and "full stop".
- Turns "first…, second…, third…" into numbered lists, whether in one sentence or across several.
- Turns spoken items after a cue ("make a list…", "groceries:") into bullet points. Bullets are "-" in Markdown apps and "•" in Mail, Slack and Notes.
- Writes numbers, money, times, dates, emails and web addresses the way people type them.
- Reads the text before your cursor, so a dictation continues your sentence with the right spacing and capitals.

**It knows your words**
- Add names and jargon to the Dictionary. They're passed to every engine that accepts vocabulary hints (OpenAI, Groq, Gemini, Deepgram, Sarvam, Whistle), and the formatter always spells them right.
- In coding tools and AI chats, 150+ developer terms are fixed automatically: useEffect, Next.js, Supabase, kubectl, .env, GitHub CLI and more.
- URLs, file paths, `code`, snake_case names and function calls pass through exactly as written.

**It's built for talking to AI**
- **Prompt mode:** in Claude Code, Codex, Cursor, Zed, VS Code, ChatGPT and Claude, a rambling thought becomes a clear prompt. Questions stay questions, and nothing you said is dropped.
- **Command mode:** hold `fn` + `⌃` and say "make this more formal" to rewrite the selected text, or "write a polite decline" to write something new.

**You never lose a word**
- If nothing is focused to type into, the text waits on your clipboard on a small card with a Copy button.
- `⌃⌘V` pastes your last dictation again, anywhere, any time.
- Your clipboard is put back right after each paste.

**It feels native**
- A thin pixel bar on the bottom edge. Your voice shows as a live waveform, then a coral cursor types your words as they land. Drag it to dock left, centre or right, and it moves out of your text's way on its own.
- fn stops opening the emoji picker as soon as you choose it as your key, with no logout. Or use any key or shortcut you like.
- A dashboard with words dictated, words per minute, time saved, streak, searchable history (with the original transcript one click away), Dictionary, snippets and styles.
- Idles at 0% CPU. The mic is only on while you're talking.

## Controls

| | |
|---|---|
| Hold `fn`, talk, let go | Push-to-talk |
| Double-press `fn` | Hands-free. Press once more to insert. |
| Hold `fn` + `⌃` | Command mode |
| `esc` | Cancel |
| `⌃⌘V` | Paste your last dictation again |

A single quick press of `fn` does nothing, so a stray press never leaves the mic on. Prefer another key? Settings → Dictation key → **Record…** accepts right ⌥, F5, ⌥Space or anything else that doesn't get in the way of typing.

## Install

Saynori builds from source in one command. You need macOS 14 or later on Apple Silicon and Xcode's command-line tools.

```bash
git clone https://github.com/loopassembly/saynori.git
cd saynori
./scripts/build-app.sh        # tests, builds, signs, installs to /Applications and opens Saynori
```

The first launch walks you through it:
1. Pick an engine.
2. Get it ready (on-device models download automatically).
3. Allow the Microphone and Accessibility.
4. Choose your key.
5. Try it out in a practice box.

## Privacy and keys

- With an on-device setup, no audio or text ever leaves your Mac.
- With a cloud setup, audio and text go only to the providers you choose, using your own keys.
- Keys are stored in `~/Library/Application Support/Saynori/config.json` (readable only by you). They're never compiled into the app.
- History, stats and your Dictionary stay on your Mac.

## Development

```bash
swift build -c release
.build/release/Saynori --test-formatter                 # 87 formatter test cases (the build runs these too)
.build/release/Saynori --test-formatter --history       # also replays every saved dictation: no crash, no dropped word
.build/release/Saynori --format-local "um so first clone it, second build it and third ship it" dev.zed.Zed
.build/release/Saynori --score-local                    # compare the instant formatter with past AI-formatted output
TLM_SPEECH=parakeet .build/release/Saynori --selftest clip.wav   # headless pipeline test with any engine
SAYNORI_PILL_DEMO=1 .build/release/Saynori              # loop the bar animation (no mic, never pastes)
SAYNORI_DEMO=1 .build/release/Saynori                   # dashboard with sample data
```

For local work, API keys can also come from `<PROVIDER>_API_KEY` environment variables (see `.env.example`). The diagnostics log is `~/Library/Logs/Saynori.log`, and it never contains keys or dictated text.

```
Sources/Saynori/
  Core/
    DictationController   hold / double-press / command / cancel, and the speech → format → paste pipeline
    Engines               every speech and formatting provider, per-provider keys
    ParakeetEngine        NVIDIA Parakeet on the Neural Engine (FluidAudio)
    WhistleEngine         Cactus Whistle on the CPU (Needle)
    LocalLLM              Gemma 4 and other local models via Ollama or OpenAI-compatible servers
    LocalFormatter        the instant formatter: commands, lists, terms, web addresses, protected spans
    SpokenNumbers         numbers, money, times and dates
    HotkeyMonitor         the dictation key, on its own event-tap thread
    CursorContext         text before the cursor, caret position, text-field detection
    TextInserter          paste at the cursor and restore the clipboard
    SarvamClient          formatting, Prompt mode and command mode (routes to whichever provider you pick)
    AudioRecorder, Settings, Store, Permissions, Migration, Log
  UI/                     pixel bar (Metal), pixel font, copy card, theme, icons
  Dashboard/              onboarding, home, history, dictionary, style, settings, engine pickers
Tests/formatter-cases.json
Resources/Brand/          app icon and character artwork (icons are generated from these at build time)
```

## Credits

Saynori is built by [Ashutosh Anand](https://github.com/loopassembly), with engine, onboarding and Whistle work by [Ayush Tripathi](https://github.com/Ayush-pbh).

On-device speech uses NVIDIA's [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) through [FluidAudio](https://github.com/FluidInference/FluidAudio), and [Whistle](https://cactuscompute.com/blog/whistle) by Cactus Compute.
