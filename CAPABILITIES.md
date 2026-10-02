# What got built, and what Claude can't easily do

Two logs. First what shipped in this version, then — the more useful half — an honest
account of which Hey Clicky capabilities are *not* readily replicable on Claude, sorted by
whether the limit is the model, the platform, or a choice we made.

---

## Part 1 — Shipped

Four skills, reachable from the picker, the menu bar, or a hotkey.

| Skill | Their equivalent | Input it gathers | Cost per run |
|---|---|---|---|
| **Explain this** | — (our original spec) | highlighted text only | a few hundred text tokens |
| **What's on screen** | "use your screen as context" | screenshot of the frontmost window | ~1 image + prompt |
| **Show me how** | "draws on your screen and teaches you" | screenshot + AX element list | image + element list, 2–6 rounds |
| **Ask about this** | "spawn agents with your voice" (the asking half) | on-device transcript + screenshot + selection | image + prompt |

Supporting subsystems:

- `Capture/ScreenCapture.swift` — `SCScreenshotManager`, prefers the frontmost *window*
  over the whole display (tighter crop, fewer vision tokens), excludes our own windows.
- `Capture/AXInventory.swift` — enumerates on-screen elements with roles, labels, and live
  frames. The AX→Cocoa coordinate flip lives in exactly one function, because that
  conversion is the classic reason overlays land in the wrong place.
- `Overlay/AnnotationOverlay.swift` — per-screen transparent windows, `sharingType = .none`
  so rings never appear in screenshots or screen shares, `ignoresMouseEvents` so clicks
  pass through, and a 10 Hz tracker so rings follow a window that moves or scrolls.
- `Support/Presence.swift` — `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default
  input device: true whenever anything holds the mic, which is the reliable public proxy for
  "on a call." Gates all unprompted output.
- `Voice/Dictation.swift` — `SFSpeechRecognizer` with `requiresOnDeviceRecognition`.
- `Anthropic/AnthropicClient.swift` — now a real tool-use loop (up to 6 rounds) with image
  blocks, and thinking blocks replayed verbatim across rounds as the API requires.

**The `point_at` design is the point.** The model never returns coordinates. It gets a list
of real elements with ids and must name one; `strict: true` on the tool schema guarantees
the argument shape, and the handler rejects any id not in the list. Geometry always comes
from the accessibility tree. That is why this should be more accurate than the version Hey
Clicky withdrew — and it is also the source of its main limitation, below.

### Verified on a real run

Confirmed working on a two-display setup (built-in Retina 2×, external 1080p 1×): rings
land on their targets, gaps equal on both screens.

Getting there took two fixes that had nothing to do with the coordinate math, which was
right from the start:

- **`constrainFrameRect(_:to:)`** — AppKit runs every window frame through it and nudges
  the window down so it cannot cover the menu bar. For an overlay sized to the whole
  screen, that shifts the canvas and every ring in it. Borderless windows are not exempt.
- **`NSHostingView.safeAreaRegions = []`** — the hosting view otherwise insets its content
  for the safe area (the notch on built-in displays), moving everything drawn inside.

Both are invisible until something is drawn at absolute screen coordinates, and neither
produces an error. Settings → Troubleshooting → **Check ring alignment** draws a ring 100pt
inside each screen edge, which turns "slightly off" into a number.

Connectors are confirmed working too: a read-only filesystem server over a real Obsidian
vault, two lookups on one answer, and the answer visibly drew on the notes. The footer's
lookup count is what made that legible — a silent read-only lookup is otherwise
indistinguishable from no lookup at all.

Still unmeasured:

- How reliably Claude picks valid element ids from the list. Invalid ids get a corrective
  tool result so it can recover, but the rate is unknown.
- Whether it leaves connectors alone on topics the vault has nothing on. The eager
  direction is the one that costs tokens and latency for nothing, and only shows up on
  subjects the user has never written about.
All four skills are now confirmed end to end against the live API: Explain this, What's on
screen, Show me how, and Ask about this by voice. Voice also confirms the strict
on-device rule in the passing direction — it listened rather than refusing, so this Mac has
the offline model that rule requires.

What remains unmeasured is rate, not function, and single tests cannot settle it:

- How often Claude names an element id that is not in the list. Invalid ids get a
  corrective tool result so it recovers, but the frequency is unknown.
- Whether connectors are left alone on subjects the vault has nothing on. The eager
  direction costs tokens and latency for nothing and only shows up over ordinary use.

---

## Part 2 — What isn't easily replicable with Claude

### A. Genuine model/API gaps

**A1. There is no speech modality, in or out.** This is the largest real gap. The Messages
API takes text, images, and PDFs — no audio in, no audio out. Hey Clicky uses OpenAI's
realtime speech-to-speech model (their own landing page quotes @gdb on "gpt realtime 2"),
which is one socket carrying audio both ways. On Claude the path is necessarily
STT → text → TTS, and four things are lost:

- **Barge-in.** You cannot interrupt mid-sentence and have the model react to the
  interruption, because the model never hears you; the recognizer does.
- **Prosody.** Tone, hesitation, irritation, urgency, and sarcasm die at the STT boundary.
  The model receives flat text and cannot hear that you asked the same question twice.
- **Non-lexical signal.** Sighs, laughter, trailing "uh…", a half-finished thought.
- **Turn latency.** Three serialized legs instead of one.

*Mitigated, not solved:* transcription is on-device (free, private, no network leg), and TTS
can start on the first streamed sentence. A rapid spoken back-and-forth will still feel
slower and flatter than theirs. If conversational voice becomes the product's core, this is
an argument for a different model provider, not a prompting problem.

**A2. Time-to-first-token is tuned for quality, not conversation.** Opus 5 with adaptive
thinking thinks before it speaks. A realtime-optimized small model starts talking in a few
hundred milliseconds. Mitigations in place: `effort: low` by default, and every system
prompt here opens with "Latency-sensitive: begin your visible answer immediately." That
helps and does not close the gap. Prompting cannot make a deliberate model snappy.

**A3. Precise pixel grounding is unreliable — which is why the design avoids needing it.**
Ask any current vision model for the exact coordinates of a control in a screenshot and you
get plausible, frequently wrong numbers. This is almost certainly why their floating cursor
drew "in the wrong place."

Our AX grounding sidesteps it, but that is a **trade, not a win**: it works wherever an
accessibility tree exists, and not at all where one doesn't —

- canvas-rendered UIs (Figma, Miro, most web whiteboards)
- games and video frames
- Electron apps that ship with accessibility disabled
- remote desktop and VM windows
- pointing at a *region of an image*, e.g. a spot inside a figure in a scanned PDF

Their version points anywhere, badly. Ours points precisely, in fewer places. The `teach`
skill is instructed to fall back to words when the element isn't in the list, so the failure
is graceful — but "point at that part of the diagram" is a capability we do not have and
cannot reliably get from the model.

**A4. No always-on understanding at a price that works.** Not a capability limit so much as
an economic one, but it lands the same way: you cannot stream the screen to a frontier model
continuously. Their suggestion engine reads your connected apps on their servers, on their
margin. The route for us is a hybrid — `FoundationModels.framework` (`SystemLanguageModel`,
on this machine, free, local) for the ambient tier, escalating to Claude only when something
looks worth a real answer. That's more architecture than Hey Clicky needed.

### B. Platform limits — no model helps

**B1. Wake words.** macOS exposes no public always-on keyword-spotting API. "Hey Clicky" as
a spoken trigger requires embedding a local KWS model and holding the microphone open
permanently: battery cost, a permanent orange indicator, and a privacy story that contradicts
the rest of this app. Push-to-talk is the honest substitute, and is better at a keyboard anyway.

**B2. Detecting screen sharing reliably.** Mic-in-use is a clean public signal. "Is another
app currently capturing the screen" has no equivalent, so the quiet-mode heuristic is
imperfect — it will catch calls and huddles, and can miss a silent screen recording.

**B3. TCC grant churn on ad-hoc signed builds.** Every rebuild changes the signature, so
macOS treats the app as new and the Accessibility grant goes stale. A one-time self-signed
certificate fixes it; unsigned distribution cannot.

**B4. Anthropic's computer-use tool doesn't fit native macOS.** It's built around a
screenshot-and-coordinate loop in a VM. Driving real Mac apps means writing AX actuation
yourself (`kAXPressAction`, `kAXValueAttribute`). Replicable — just not given to you. Moot
here in any case: acting inside apps was dropped rather than deferred.

### C. Consequences of our own architecture

**C1. No server means no cross-device anything.** Claude's memory tool needs a store you
provide. Ours would be local, so a Clicky-style agent would not follow you to another Mac.
Their memory is server-side and does.

**C2. Every request spends the user's own money.** BYO key is why we can offer no caps — and
also why "unlimited talk" doesn't feel unlimited the way a $20 subscription does. Their free
tier eats voice cost to build the habit. We can't buy a habit; we can only remove friction.

**C3. No usage telemetry.** No server means no aggregate view of which skills get used. The
single most valuable thing Hey Clicky learned — *we barely used agents ourselves* — came
from 1.2 million messages passing through their infrastructure. We'd have to notice it by
introspection, which is much weaker.

### D. Replicable with Claude, deliberately not built

None of these are blocked by the model. Tool use is where Claude is strongest; these are
scope calls, with the estimates from `replication-plan.md`.

| Capability | Days | Why deferred |
|---|---|---|
| Persistent agent personas with memory and files | 15–25 | Turns this into a different product; their own finding is that it's a UI problem, not a capability one |
| ~~Computer use — acting inside apps~~ | — | **Dropped.** Highest liability on the list, and a weak payoff beside the four skills. Its safety layer (`ActionRisk.swift`, with tests) is kept |
| Scheduled routines | 3–5 | Needs the agent loop first |
| ~~MCP connectors~~ | — | **Built.** stdio client, server registry, approval gate on anything that writes |
| The notch UI | 8–15 + permanent tail | Brand, not capability. A panel at the cursor is better for reading help |
| Proactive morning suggestions | 5–8 | Needs C1 and A4 first; the etiquette backoff it depends on *is* built |

---

## The short version

Claude does the hard parts of this well: the tool loop that drives multi-step annotation
came out clean, `strict: true` made element ids safe by construction, and server-side
fallbacks removed refusal handling entirely.

What it cannot do is **hear you** — no audio in or out, so barge-in, tone, and conversational
latency are out of reach — and it cannot **point at arbitrary pixels**, which we work around
with accessibility grounding at the cost of only working where that grounding exists.

Everything else on Hey Clicky's list is a question of engineering days, not of model
capability.
