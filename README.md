# Mac Clicker

A menu bar widget that turns whatever your cursor is pointing at into a mini-task.

Highlight a paragraph anywhere on your Mac — Preview, Chrome, Xcode, Mail — press
**⌥Space**, and a panel appears at your cursor and streams an explanation. Or hold
**⌃⌥Space** and ask out loud. Or ask it to show you how to do something in the app you're
in, and it draws numbered rings on your actual screen.

```
   highlight  ──▶  ⌥Space   ──▶  panel at the cursor  ──▶  streamed answer
   speak      ──▶  ⌃⌥Space  ──▶  on-device transcript ──▶  answer
   stuck      ──▶  Show me how  ──▶  rings drawn on the real UI
```

Four skills:

| Skill | What it needs | What it does |
|---|---|---|
| **Explain this** | highlighted text | Unpacks dense prose, jargon, notation |
| **What's on screen** | a look at your screen | Reads a figure, chart, diagram, or scanned page |
| **Show me how** | screen + accessibility tree | Points at the next step with numbered rings |
| **Ask about this** | your voice | Answers a spoken question about the selection or screen |

---

## Quick start

```bash
./build.sh --install
```

That compiles, bundles, ad-hoc signs, installs to `/Applications`, and launches it. Then:

1. **Grant three permissions** as prompted — Accessibility (to read highlighted text and
   locate UI elements), Screen Recording (for the skills that look at your screen), and
   Microphone + Speech (only if you want to ask by voice). Settings → Permissions shows all
   three with live status.

   Accessibility in detail: grant it when macOS asks (or System Settings → Privacy &
   Security → Accessibility → enable *MacClicker*). This is what lets the app
   read text you've highlighted in *other* apps — macOS gives no other route to it.
2. **Paste an Anthropic API key** in the Settings window that opens on first run
   ([console.anthropic.com](https://console.anthropic.com/settings/keys)). It goes into
   your login keychain, never to disk.
3. Highlight something and press **⌥Space**.

The menu bar icon (⌖) has *Explain Selection*, *Settings…*, and *Quit*.

---

## How it works

| Piece | File | Notes |
|---|---|---|
| Hotkey | `Hotkey/HotKeyManager.swift` | Carbon `RegisterEventHotKey` — no Accessibility permission needed for the key itself, and it can't swallow other apps' keystrokes the way an event tap can. |
| Selection capture | `Capture/SelectionCapture.swift` | Tries `kAXSelectedTextAttribute` on the focused element first (clean, no clipboard involvement). Falls back to a synthesized ⌘C and restores your clipboard afterwards — needed for Chrome and most Electron apps, which expose no AX selection. |
| Panel | `UI/PanelController.swift` | Borderless `NSPanel` at the cursor, floats over full-screen apps, `esc` or a click elsewhere dismisses. Capture happens *before* the panel appears, while your app is still frontmost. |
| Model call | `Anthropic/AnthropicClient.swift` | `POST /v1/messages` with `stream: true`, parsed as SSE. Deltas are coalesced to ~20 fps so SwiftUI isn't re-laying out the answer on every token. |
| Skills | `Skills/Skill.swift` | The extension point — see below. |
| Screen capture | `Capture/ScreenCapture.swift` | `SCScreenshotManager`, prefers the frontmost window over the whole display so fewer vision tokens are spent. Excludes our own windows. |
| Element grounding | `Capture/AXInventory.swift` | Enumerates real on-screen elements with ids, labels, and live frames. The model names one; geometry never comes from the model. |
| Annotation overlay | `Overlay/AnnotationOverlay.swift` | Transparent per-screen windows. `sharingType = .none` keeps rings out of screenshots and screen shares; `ignoresMouseEvents` lets clicks through; a 10 Hz tracker follows moving windows. |
| Presence | `Support/Presence.swift` | Mic-in-use via CoreAudio, as a proxy for "on a call". Gates every unprompted output. |
| Voice | `Voice/Dictation.swift` | `SFSpeechRecognizer` with on-device recognition — speech never leaves the Mac, only the text. |
| Suggestion backoff | `Sources/MacClickerKit/SuggestionPolicy.swift` | Decides whether an unprompted suggestion may appear. Kept free of AppKit so it is directly testable; 14 tests cover the rules. |
| Connectors | `MCP/MCPClient.swift`, `MCP/MCPRegistry.swift` | Speaks MCP over stdio to servers you configure, and offers their tools to the model. |
| Action risk | `Sources/MacClickerKit/ActionRisk.swift` | Decides which tool calls need your approval. |

**Model configuration:** `claude-opus-5`, adaptive thinking, effort `low` by default
(fast and strong for explain-style work; raise it in Settings). `fallbacks: "default"` is
enabled, so if Opus 5's safety classifiers decline a selection, Anthropic re-runs it
server-side on a suitable model instead of handing back a refusal.

**Cost:** a paragraph-sized explanation is on the order of a fraction of a cent. Every
request is one turn with no history, so nothing accumulates.

---

## Adding a skill

A skill is a title, a system prompt, and a function that builds the user turn out of the
selection. Append one to `Skill.all` in `Sources/MacClicker/Skills/Skill.swift`:

```swift
static let summarize = Skill(
    id: "summarize",
    title: "Summarize",
    subtitle: "Condense a long passage to its point",
    symbol: "text.append",
    system: """
    Condense the highlighted passage to its load-bearing points. \
    Three bullets at most. No preamble.
    """,
    user: { input in
        """
        <selection>
        \(input.selection)
        </selection>
        """
    }
)

static let all: [Skill] = [.explain, .summarize]
```

With one skill registered the hotkey runs it directly. Register a second and the panel
shows a picker instead — no other code changes.

---

## Settings

- **Hotkey** — six presets (⌥Space, ⌃⌥Space, ⇧⌘Space, ⌥E, ⌃⌥E, ⇧⌘E). If another app has
  claimed one, the app says so rather than failing silently.
- **Depth** — `low` / `medium` / `high` thinking effort.
- **Explain things for…** — free text describing your background, e.g. *"an ML engineer
  who doesn't do statistics"*. Steers the reading level of every explanation.
- **Behaviour** — whether to draw on screen, speak status, stay quiet while the microphone
  is live, and whether to suggest skills you haven't tried.

### Suggestions, and not being annoying

The app can mention a skill you have never used. It does so at most once a day, only
*after* an answer has arrived rather than instead of one, never while your microphone is
live, and never once you have tried everything. If you keep saying no it stops asking:

| Behaviour | Response |
|---|---|
| Dismissed three days running | Rests five days |
| Three offers ignored in a row | Rests one day, doubling each time, capped at a week |
| You act on one | Every streak clears |

The numbers come from what Hey Clicky settled on after twenty weeks of complaints — see
[heyclicky-analysis.md](heyclicky-analysis.md) — which is cheaper than rediscovering them.
The logic lives in `MacClickerKit` with no AppKit dependency, so `swift test` exercises it
directly rather than leaving it to be found in the wild.

---

## Connectors (MCP)

Rather than hand-building a Gmail integration and a Notion integration and a Sheets
integration, Mac Clicker speaks [MCP](https://modelcontextprotocol.io) and borrows the
ecosystem. Settings → Connectors → **Create config…** writes
`~/Library/Application Support/MacClicker/mcp.json` in the same shape Claude Desktop uses,
so an existing config can be pasted straight in:

```json
{
  "mcpServers": {
    "notes": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/Notes"]
    }
  }
}
```

Those tools are offered to **Explain this**, **What's on screen**, and **Ask about this** —
not to **Show me how**, where pointing accurately is the whole job and a pile of unrelated
tools only gives it something else to do. With no config there are no tools, so this costs
nothing until you set it up.

**Approval.** Tools that only read run as part of an answer; being asked three times to
approve a note lookup is how people learn to click Allow without reading. Anything that
would change something is shown to you first, with the arguments it was actually called
with, every time. The split is decided by `ActionRisk.swift` and is pinned by a test
against the real tool list from `server-filesystem`: its ten readers run free, its
`write_file`, `edit_file`, `create_directory` and `move_file` always ask.

**Read-only servers.** Approval is a prompt you could click through at two in the morning;
`"readOnly": true` on a server is a guarantee instead. Its writing tools are dropped before
the model is told they exist, so there is nothing to approve by mistake:

```json
{ "mcpServers": { "notes": { "command": "npx", "args": ["…"], "readOnly": true } } }
```

Settings shows that server with a *read-only* badge and how many tools were withheld.

A GUI app inherits a bare `PATH`, not your shell's, so the client adds the usual Homebrew,
`/usr/local/bin` and `~/.local/bin` locations before launching a server — otherwise `npx`
is simply not found and the failure looks like nothing at all.

## Troubleshooting

**Nothing happens on the hotkey.** Check the menu bar icon is there and Accessibility is
granted (Settings → Permissions shows the live status). Then check the shortcut isn't
taken by Alfred/Raycast/Spotlight.

**"Nothing highlighted" in a browser.** The ⌘C fallback needs Accessibility access too —
without it there's no way to reach the selection at all.

**macOS keeps asking for the login keychain password.** The app is ad-hoc signed, so its
signature changes every build, and the keychain's default access list ("only the exact
binary that created this item") stops matching. Two fixes are in place: the key is read
once per launch rather than once per request, and it is stored with an access list any
application can read — which is what stops the prompt. The tradeoff is that any process
running as you can read the key without a dialog, the same exposure as a config file in
your home directory. Settings has a **Stop asking for the keychain password** button that
re-applies this if an older build stored the key.

For the stricter version, sign with a stable identity instead: create a self-signed Code
Signing certificate named `Mac Clicker Dev` (Keychain Access → Certificate Assistant), mark
it trusted for code signing, and `build.sh` picks it up automatically. That also fixes the
next item.

**It stopped working after a rebuild.** Same root cause: a changed signature makes macOS
treat it as a different app, so the Accessibility grant goes stale. Remove and re-add it
under System Settings → Privacy & Security → Accessibility, or use the stable signing
identity above.

---

## Not yet verified

The build compiles clean and the app launches, but nothing here has made a live request —
there was no API key available in this environment. Two things specifically need a real run:

1. Whether rings land exactly on their targets (the AX→Cocoa coordinate flip, on your
   display layout).
2. Whether Claude reliably picks valid element ids. Invalid ones get a corrective tool
   result so it can recover, but the rate is unmeasured.

Any request problem surfaces as a readable error card in the panel rather than a silent
failure.

See [CAPABILITIES.md](CAPABILITIES.md) for what Hey Clicky can do that this can't, and why —
including the two genuine Claude-side gaps (no audio modality, unreliable pixel grounding).
