# Replicating Hey Clicky's unique features

Engineering plan, scoped to Mac Clicker's existing Swift/AppKit skeleton. Every API named
here was verified present in the macOS 26.5 SDK on this machine (`xcrun --show-sdk-path`),
not recalled — the grep results are noted inline.

Effort figures are rough person-days for one competent Swift developer who already knows
AppKit, and assume the plumbing this project already has (hotkey, AX selection capture,
floating panel, streaming client, keychain).

---

## Three findings that change the difficulty estimate

**1. Their hardest feature was pulled over a one-line bug.**
Hey Clicky removed their screen-drawing cursor in v1.0.52 because the overlay layer made
window screenshots and Loom/call sharing come out black. macOS has a property for exactly
this:

```
NSWindow.h:520  /*! ... If you set your window sharing type to NSWindowSharingNone,
                 so that the content cannot be captured ... */
NSWindow.h:522  @property NSWindowSharingType sharingType API_AVAILABLE(macos(10.5));
```

`overlay.sharingType = .none` excludes the window from all screen capture. Their crown-jewel
feature is *more* replicable than their own changelog implies.

**2. Annotation should be grounded in the accessibility tree, not in predicted pixels.**
The naive build asks the model for coordinates on a screenshot. Vision models are mediocre
at precise pixel grounding, which is very likely why their cursor landed "in the wrong
place." The reliable design: enumerate the focused app's AX tree, hand the model a list of
labelled elements, let it name one, then read that element's real frame from AX and draw
there. Confirmed available:

```
HIServices/AXActionConstants.h:40  #define kAXPressAction  CFSTR("AXPress")
```

Same walk gives you actuation *and* geometry. Pixel-perfect by construction.

**3. There is a free on-device LLM sitting on this machine.**

```
/System/Library/Frameworks/FoundationModels.framework  → class SystemLanguageModel
                                                       → class LanguageModelSession
```

Hey Clicky pays OpenAI for every ambient decision (is this suggestion worth firing? what
app is this?). Those can run locally at zero marginal cost. This is a structural cost
advantage over their model, and it's the difference between "proactive features are
expensive" and "proactive features are free."

---

## Workstream 1 — Screen as context (2–3 days)

**What it is:** hotkey → it sees what you see → ask about it.

**Mechanism:** `SCScreenshotManager` (verified at
`ScreenCaptureKit.framework/Headers/SCScreenshotManager.h`).

**Steps**
1. `SCShareableContent.current` → pick the display, or the frontmost window via
   `NSWorkspace.frontmostApplication` matched against `SCWindow.owningApplication`.
2. Build an `SCContentFilter`; exclude our own windows so the panel isn't in the shot.
3. `SCScreenshotManager.captureImage(contentFilter:configuration:)`, downscale to ~1400px
   wide, PNG-encode, base64.
4. Send as an image content block alongside the text:
   `{"type":"image","source":{"type":"base64","media_type":"image/png","data":"…"}}`.
5. Second TCC grant needed: Screen Recording. Preflight with
   `CGPreflightScreenCaptureAccess()`, request with `CGRequestScreenCaptureAccess()`.
   (Evidence this is a real gate: `screencapture` failed from this session earlier with
   "could not create image from display" — that is the missing grant.)

**Hard part:** none, really. This is the easy one.

**For Mac Clicker:** worth building as a *fallback*, not the primary path. When
`SelectionCapture.capture()` returns nil — a diagram, a chart, a video frame, an image-only
PDF — offer "explain what's on screen" instead of the current "Nothing highlighted" dead
end. Keeps our cheap, precise text path as the default and removes our only failure state.

---

## Workstream 2 — Drawing on the screen to teach a tool (8–12 days)

Their signature capability, and the one worth beating.

**Mechanism:** transparent borderless `NSWindow` + AX-tree grounding.

**Steps**
1. **Overlay window.** Borderless `NSWindow`, `isOpaque = false`,
   `backgroundColor = .clear`, `ignoresMouseEvents = true`, `hasShadow = false`,
   `level = .screenSaver` (above normal windows, below the true system UI),
   `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`, and
   **`sharingType = .none`** — the fix for their bug. Host a `CAShapeLayer`/SwiftUI `Canvas`
   for arrows, rings, and callout labels.
2. **Element inventory.** Walk the frontmost app's AX tree from
   `AXUIElementCreateApplication(pid)` via `kAXChildrenAttribute`, collecting each element's
   `kAXRoleAttribute`, `kAXTitleAttribute` / `kAXDescriptionAttribute` /
   `kAXHelpAttribute`, and `kAXFrameAttribute`. Prune to visible, on-screen, interactive
   roles. Assign each a short id.
3. **Model turn.** Send the screenshot *plus* the element list (`e17: button "Quantize",
   frame …`). Define a tool `highlight(element_id, label, shape)` so the model *names* a
   real element rather than guessing coordinates.
4. **Draw.** Read the named element's live frame from AX, convert AX coordinates (top-left
   origin, y-down) to Cocoa screen coordinates (bottom-left origin, y-up) — this conversion
   is the classic bug source — and animate a ring plus a short label.
5. **Track.** Poll the element frame at ~10 Hz, or subscribe to
   `AXObserverAddNotification` for `kAXMovedNotification` / `kAXWindowMovedNotification`, so
   the annotation follows a scrolling or resizing window. Tear down on app switch
   (`NSWorkspace.didActivateApplicationNotification`).

**Hard parts**
- Coordinate-space conversion between AX and Cocoa, across multiple displays with different
  backing scale factors. *Measured result: this was not the bug.* The flip was right first
  time; the rings were offset because AppKit silently constrains any window frame through
  `constrainFrameRect(_:to:)` so it cannot cover the menu bar, and `NSHostingView` insets
  its content for the safe area. Override the first, set `safeAreaRegions = []` for the
  second. Both are invisible until something is drawn at absolute screen coordinates.
- Apps with a useless AX tree (Electron without accessibility enabled, canvas-rendered UIs
  like Figma, most games). Fall back to model-predicted normalized coordinates there and
  accept lower accuracy — or just decline to draw and describe instead.
- Multi-step teaching ("now click here, then here") needs a step controller with its own
  state, not one-shot annotation.

**For Mac Clicker:** this is the one capability I'd actually chase. It's their moat, it's
currently *withdrawn* from their product, and the AX-grounded version is strictly more
accurate than what they shipped. It also composes naturally with what we already do: explain
the highlighted text, then point at what the text is talking about.

---

## Workstream 3 — The notch UI (8–15 days, plus a permanent tail)

**Mechanism:** verified notch geometry —

```
NSScreen.h:64  @property (readonly) NSRect auxiliaryTopLeftArea  API_AVAILABLE(macos(12.0));
NSScreen.h:65  @property (readonly) NSRect auxiliaryTopRightArea API_AVAILABLE(macos(12.0));
```

**Steps**
1. Detect a notch: `screen.safeAreaInsets.top > 0`. Derive the notch rect as the gap between
   `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`.
2. Borderless window pinned over that rect at
   `CGWindowLevelForKey(.mainMenuWindow) + 1`, `canJoinAllSpaces`, `sharingType = .none`.
3. Hover detection with `NSTrackingArea` plus a global
   `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` (the pointer is usually over
   *another* app when it enters the notch, so a local tracking area alone won't fire).
4. Grow/shrink animation, resizable edges, pop-out-to-real-window mode, persisted size.
5. No-notch Macs (external displays, Airs before 2022, Minis) need a menu-bar-anchored
   fallback — so you build and maintain two surfaces.

**Hard parts:** the hover state machine. Four consecutive Hey Clicky releases fix notch
bugs: stuck open, stale state, other apps' floating bars stealing Escape, first-hover-after-
launch folding up. That's ~20 weeks of user bug reports buying polish you'd have to buy too.

**For Mac Clicker: skip.** It is brand, not capability. A panel at the cursor is *better* for
our use case — it appears where your eyes already are, next to the text you highlighted,
instead of 400px away at the top of the screen.

---

## Workstream 4 — Persistent agent personas ("Clickys") (15–25 days)

**Mechanism:** local agent loop over the Messages API + a local store.

**Steps**
1. **Loop.** Extend `AnthropicClient` from single-turn to a tool-use loop: send `tools`, on
   `stop_reason == "tool_use"` execute locally, append **all** `tool_result` blocks in one
   user message, repeat. Keep streaming for the text.
2. **Tools.** Local Swift implementations: read/write files in the agent's folder, run a
   shell command (sandboxed, allowlisted), AX actuation (workstream 7), MCP toolsets
   (workstream 8).
3. **Store.** SwiftData or plain SQLite: one row per agent (name, symbol, system prompt,
   created date), one per turn, one per produced file. A real directory per agent under
   `~/Library/Application Support/MacClicker/<agent-id>/`.
4. **Memory.** Either the API's memory tool (`{"type":"memory_20250818","name":"memory"}`,
   backed by that folder) or a hand-rolled `NOTES.md` the system prompt always includes.
5. **Long threads.** Context editing (`context_management.edits` with
   `clear_tool_uses_20250919`, beta `context-management-2025-06-27`) or compaction
   (beta `compact-2026-01-12`) so a months-old agent doesn't blow the window. Hey Clicky hit
   exactly this: *"one history pass on a 297-turn chat went from 2.14s to 0.15s."*
6. **Creation by conversation** — a meta-skill that interviews you and writes the new agent's
   system prompt.

**Hard part:** not the loop. It's that **agents built without a home go unused** — their own
finding, after 1.2 million messages. The UI to return to is the feature; the loop is a week.

**For Mac Clicker:** only if the product's identity changes from "instant answer about the
thing I highlighted" to "a team that does work for me." Those are different products. Don't
drift into it by accident.

---

## Workstream 5 — Voice (5–8 days for push-to-talk; wake word: don't)

**Mechanism, verified on this machine:**

```
Speech.framework  → actor SpeechAnalyzer      @available(macOS 26.0)
                  → class SpeechTranscriber
                  → class SpeechDetector
AVFAudio.framework/Headers/AVSpeechSynthesis.h → AVSpeechSynthesizer
```

**Steps**
1. Hold the hotkey (or double-tap ⌃) → `AVAudioEngine` tap → `SpeechAnalyzer` +
   `SpeechTranscriber` for on-device streaming transcription. Free, private, no network.
2. Release → send the transcript (plus selection and/or screenshot) to Claude.
3. Speak the reply with `AVSpeechSynthesizer`, or a cloud TTS if you want better voices.

**The honest constraint:** Hey Clicky uses OpenAI's realtime speech-to-speech model — one
socket, sub-second, barge-in supported. Claude has no speech-to-speech API, so the path is
STT → text model → TTS, with three serialized legs. Expect noticeably higher turn latency.
You can hide much of it by starting TTS on the first streamed sentence rather than waiting
for the full response.

**Wake word ("hey clicky"):** there is no public always-on keyword-spotting API. You'd embed
a local KWS model (openWakeWord, Porcupine) and hold the mic open permanently — battery
cost, a permanent orange mic dot, and a privacy story that undoes our main advantage. Use
push-to-talk instead; it's better UX anyway for a tool used at a keyboard.

---

## Workstream 6 — Etiquette / presence (2–4 days) ← best return on the list

**Mechanism, verified:**

```
CoreAudio/AudioHardware.h:1000  kAudioDevicePropertyDeviceIsRunningSomewhere = 'gone',
```

**Steps**
1. **Am I on a call?** Query `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default
   input device — true whenever any process holds the mic. Add a listener block for changes.
   Camera-in-use is a useful second signal.
2. **Am I screen sharing?** Cheap heuristic: any other process holding a
   `ScreenCaptureKit`/`CGDisplayStream` session, or the presence of known screen-share
   helpers. Imperfect; mic-in-use covers most of the real cases.
3. **Suppress when either is true:** spoken updates, chimes, cursor-side text, proactive
   cards. Separate user switches for voice vs. visual, like theirs.
4. **Backoff, with their numbers as the starting point:** dismissed three days running → rest
   five days; three unopened mornings → rest starting at one day, capped at a week; any
   scheduled job that fails three times consecutively → pause and say why, don't retry.
5. Never suppress something the user explicitly asked for — only unprompted output.

**For Mac Clicker:** build this *before* anything proactive, not after. It's 3 days and it's
the difference between a tool people keep and one they uninstall in week two.

---

## Workstream 7 — Computer use on the local Mac — DROPPED

**Mechanism:** AX actuation rather than synthetic input — that's how they act "without
moving your real pointer."

**Steps**
1. `AXUIElementPerformAction(element, kAXPressAction)` to press without moving the cursor;
   `AXUIElementSetAttributeValue(element, kAXValueAttribute, text)` to fill a field;
   `kAXConfirmAction` / `kAXShowMenuAction` for the rest. CGEvent posting stays the last
   resort, since it genuinely takes over the user's input.
2. Apple Events / `osascript` for scriptable apps (Mail, Finder, Notes, OmniFocus…) — far
   more reliable than clicking, and needs its own TCC grant per target app
   (`NSAppleEventsUsageDescription`).
3. **Consent, scoped correctly.** Copy their fix verbatim: one approval covers *one
   conversation*, not the app globally and not every agent. Show the exact action before it
   runs. Keep an undo log.
4. Preflight: verify the element still exists and still has the expected role/title
   immediately before acting — AX trees change under you.

**Dropped, deliberately.** The estimate was 10–15 days and it was the highest-liability
item here: an agent that mis-presses in Mail or a banking tab is a different class of bug
from a wrong explanation. Two things settled it — the cost/benefit never looked good next
to the four skills that make up the actual product, and the actuator is genuinely dual-use
code whose source reads the same whether it drives an accessibility assistant or a UI
automation trojan.

What survives is the safety layer, `MacClickerKit/ActionRisk.swift`: the consequential-vs-
routine classification and the hard application blocklist, with tests. It costs nothing to
keep and encodes the judgment that would otherwise have to be rebuilt from scratch.

---

## Workstream 8 — Connectors and scheduled routines (5–8 days combined)

**Connectors: don't hand-build them.** Hey Clicky wrote Gmail, Notion, Sheets, and Meta Ads
integrations one at a time, plus a custom-token system with real validation. Use MCP instead
and inherit an ecosystem:
- Local MCP servers spawned as child processes, tools surfaced into the agent loop; or
- The API's MCP connector — `mcp_servers: [{type:"url", url, name}]` **plus**
  `tools: [{type:"mcp_toolset", mcp_server_name: "<same name>"}]`, beta
  `mcp-client-2025-11-20`. Both halves are required; the server list alone is rejected.

**Routines, verified:**

```
Foundation.framework/Headers/NSBackgroundActivityScheduler.h:29  @interface NSBackgroundActivityScheduler
Network.framework/Headers/path_monitor.h                         nw_path_monitor_create
```

1. `NSBackgroundActivityScheduler` with an interval and tolerance — the system picks a good
   moment (on AC power, not thermally throttled).
2. Gate each run on `NSWorkspace.didWakeNotification` having settled *and*
   `NWPathMonitor` reporting `.satisfied`. Their exact behaviour: hold the run and post
   "I'll run it when the internet is back" rather than failing it, and don't count an
   offline skip toward the failure limit.
3. Pause after three consecutive real failures; surface why.

---

## Sequencing

```
  Etiquette (6) ────────────────┐
                                ├──▶ anything proactive
  Screen capture (1) ──┬────────┘
                       │
                       └──▶ Annotation (2) ──▶ multi-step teaching
                                  ▲
  AX element inventory ───────────┘──▶ Computer use (7) ──▶ Agent loop (4) ──▶ Routines (8)
                                                                  ▲
                                                     MCP connectors (8) ──┘
  Voice (5) ── independent
  Notch (3) ── independent, and skippable
```

Full parity is roughly **three months of one developer**, and about a third of that is notch
polish and voice latency work that buys Mac Clicker nothing.

## What I'd actually build, in order

| # | Workstream | Days | Why |
|---|---|---|---|
| 1 | Etiquette + backoff (6) | 2–4 | Cheapest, and a prerequisite for everything unprompted |
| 2 | Screenshot fallback (1) | 2–3 | Removes our only dead end — no selection, no answer |
| 3 | AX element inventory | 3–5 | Shared foundation for annotation *and* actuation |
| 4 | AX-grounded annotation (2) | 8–12 | Their moat, currently withdrawn, and we can do it more accurately |
| 5 | Push-to-talk voice (5) | 5–8 | On-device STT is free and private; skip the wake word |
| 6 | MCP connectors (8) | 2–4 | Inherit an ecosystem instead of writing integrations |
| — | Notch, wake word, speech-to-speech parity | — | Skip; brand and latency, not capability |
| — | Computer use | — | **Dropped.** Highest liability on the list, weakest payoff next to the four skills |
| — | Agent loop, routines | 25–40 | Only if this becomes an agent product, which is a different product |

**Steps 1–4 are about three weeks** and produce something Hey Clicky does not currently
ship: precise text explanation *plus* accurate on-screen pointing, with no account, no
subscription, no server, and no monthly cap.
