# Hey Clicky — capability analysis

Sources: heyclicky.com homepage + FAQ + pricing, and the v1.0.49–v1.0.52 changelog
(Sep 12–24, 2026). `/features` redirects to the homepage; the changelog is the only place
they document mechanics, and it's unusually candid. Read 2026-09-30.

Company: Humansongs, Inc. Founder: Farza. 25,000+ users, Mac-only (Sonoma 14.2+),
Windows waitlist. Runs on OpenAI models (GPT-6 Luna for Clickys, GPT-6 Sol for deep
answers, GPT realtime for voice) — explicitly *not* a model play.

Their stated thesis, verbatim from the site: *"we all have access to the same ai models,
yet very few of us unlock their full power... we just believe it's an interface problem."*
Everything below follows from that. They are betting the whole company on interface.

---

## The capabilities that are actually distinctive

Ranked by how hard they'd be to copy.

### 1. Drawing on your screen to teach you a tool
The genuine standout. You're stuck in FL Studio or DaVinci Resolve, you ask out loud, and
it **annotates your live screen** to point at the next control. Nobody else ships this.
It converts "explain this" into "show me, here, on my thing."

But the changelog shows the cost: *"The agent's floating cursor is gone for now, since it
could draw over the app you were using or in the wrong place. That same cursor layer is why
a window screenshot, or sharing a single window in Loom or a call, could come out black."*
A persistent overlay window above other apps breaks `CGWindowListCreateImage`-based capture
and window sharing. They shipped it, it broke screenshots and Zoom/Loom for users, they
pulled the cursor layer. **This is the hardest capability they have and it is still
unstable.**

### 2. The notch as the primary UI surface
Not a menu bar item, not a window — the MacBook notch. Hover → peek (suggestions, pins,
every Clicky, recent files as a draggable pile). Click → "Home" sheet grows down out of the
notch, resizable by dragging its edges, poppable into a real window, remembers which mode
you left it in. Unread count as a badge on the notch itself.

This is a real interface invention and a real maintenance tax: four consecutive releases
contain notch bugs (stuck open, stale state, other apps' floating bars stealing Escape,
first-hover-after-launch folding up). Copying the *idea* is easy; the polish is ~20 weeks
of bug reports.

### 3. "Clickys" — persistent agent personas with memory, files, and a face
Each Clicky has a name, character art, its own conversation, its own memory, and its own
folder for output files. You create them by talking ("make me three Clickys: inbox,
competitor research, newsletter" — up to five at a time). Auto-named with two words that
describe the job (PDF Desk, … Scout, … Lab, … Keeper).

The *why* is the most valuable thing in the entire changelog:

> "HeyClicky is 20 weeks old, and after 1.2 million messages we noticed **we barely used
> agents ourselves**. So we spent the last three weeks building a home for them that we'd
> actually want to open every day."

They had working agents and nobody used them. The fix wasn't capability — it was identity
and a place to return to. That is a product finding, not a feature.

### 4. Screen-as-context, gated on a hotkey, with a clean privacy story
Press the hotkey → it sees what you see. No plugins, no per-app integrations: *"if you can
see it, heyclicky can see it."* The privacy posture is specific and repeated in the footer:
screen is read **only** on hotkey press, screenshots are **never stored**, but they do keep
**text summaries** server-side for context, and account deletion wipes it.

Note the asymmetry — the image is ephemeral, the derived text is not. That's the honest
version of "private," and it's still a server-side dependency.

### 5. Etiquette / presence engineering ("quiet when you're busy")
Underrated and genuinely hard. Spoken updates, text beside your cursor, a done chime, a
morning hello, tip cards — all auto-silenced while you're on a call or sharing your screen.
Separate switches for voice vs. cursor text. Do Not Disturb silences only scheduled
routines, not things you asked for.

Plus proactivity backoff with real numbers: dismiss the morning card 3 days running → it
rests 5 days. Three mornings of unopened suggestions → a break starting at 1 day, capped at
a week. Routines pause after 3 consecutive failures instead of retrying every 5 minutes and
burning your credits.

Very few AI products model their own annoyingness as a system. This is the part I'd steal.

### 6. Voice as the spawn mechanism, not just the input
"heyclicky agent" as a wake phrase, spoken directly at your work, is the launcher. Their
pitch is explicitly *"no terminal needed."* Dictation is a separate, near-unlimited feature
on every tier — they treat transcription as table stakes and charge for action.

### 7. Background computer use with per-conversation consent
Agents act inside your apps *"without moving your real pointer or jumping into another
app's address bar"* — synthetic input, not cursor puppetry. And the permission scope is
sharp: *"your yes covers one conversation, not every Clicky that happens to be working."*
Per-conversation authorization is the right granularity and almost nobody does it.

### 8. Scheduled routines + connectors + the suggestion engine
Clickys run on a schedule, wait for the Mac to be fully awake and the network to be usable,
and say "I'll run it when the internet is back" in-chat rather than failing. Suggestions are
built from what happened *in your connected apps in the last two days* (Gmail, Notion,
Google Sheets, Meta Ads, custom connectors with real token validation). Self-knowledge is a
feature too: ask "stop announcing yourself" and it walks you to the exact setting; it can
report how much of your plan you've used.

---

## What's table stakes, not a moat

Vision-on-screenshot, chat UI, markdown/table rendering, dictation, connectors, a model
picker. Any of these ships in a weekend. Their moat is the notch + overlay + persona
scaffolding + etiquette, none of which is about the model.

---

## What the pricing reveals

| | Free | Pro $20/mo | Max $100/mo |
|---|---|---|---|
| Talk (conversation) | 25/mo | **unlimited** | **unlimited** |
| Dictation | "plenty" | unlimited | unlimited |
| Agent messages (doing) | 25/mo | 150/mo | 1,000/mo |

**Talking is free, doing is metered.** They eat unbounded realtime-voice cost to make the
habit free, and charge for agent runs — the expensive, multi-turn, tool-calling part. That
is a deliberate bet that habit beats margin, and it only works because voice inference is
cheap relative to a 30-step agent loop.

Growth machinery: referral usernames (`heyclicky.com/@you`), friend gets 25% off month one,
you get **25% of their plan in cash, monthly, for up to 12 months**. 50% student discount.
Development runs through a WhatsApp community, and the changelog credits individual
requesters and bug reporters **by name, with avatars, next to each fix** — including the
founder. That's a retention mechanism disguised as release notes.

---

## What this means for Mac Clicker

We are not competing with them, and it's worth being deliberate about why.

**Orthogonal by construction:**

| | Hey Clicky | Mac Clicker |
|---|---|---|
| Input | screenshot of your whole screen | the exact text you highlighted (AX API) |
| Precision | infers what you meant | knows, character-exact |
| Cost per ask | vision tokens on a full screen | a few hundred text tokens |
| Model | OpenAI GPT-6 | Claude Opus 5 |
| Account | required, subscription | none |
| Server | theirs; keeps text summaries | none; key in your keychain, request goes straight to the API |
| Limits | 25/150/1,000 agent runs per month | whatever your API bill tolerates |
| Surface | the notch | a panel at your cursor |

Their weakness is our whole premise: a screenshot cannot tell you *which clause* confused
you. For a research paper — equations, a hedged sentence, one bit of notation — the
selection *is* the question. Reading it precisely and cheaply beats reading the screen
vaguely and expensively.

**Worth borrowing, in order:**

1. **Their agents-went-unused finding.** Our Skill registry is stateless by design. If we
   ever add long-running or scheduled skills, the lesson is that capability alone won't get
   them opened — they need a place to live and something to come back to.
2. **The etiquette system.** If Mac Clicker ever becomes proactive, copy the backoff
   numbers wholesale, and copy "silent while screen sharing or on a call."
3. **Per-conversation consent.** If we add anything that acts (rewrite-and-paste-back,
   computer use), scope approval to that one invocation. Never a global yes.
4. **Crediting requesters by name in release notes.** Nearly free, disproportionate loyalty.
5. **Their own fix "only the screenshot that matters"** — they were resending old
   screenshots on every turn and it bloated context. Our single-turn, no-history design
   already avoids the class of bug; keep it that way on purpose.

**Worth avoiding:**

- **Do not build a screen-drawing overlay.** They shipped it, it blacked out window
  screenshots and broke Loom/call sharing, and they removed it. A plain `NSPanel` — what we
  have — sidesteps the entire failure mode.
- **Do not colonize the notch.** Four releases of bug fixes for one hover interaction.
- **Do not meter anything.** BYO key means "unlimited" is free for us to offer, and it is a
  direct answer to their 25-runs-a-month free tier.

**The gap neither product fills:** Hey Clicky teaches you *tools* (where to click in FL
Studio). Mac Clicker explains *text* (what this paragraph claims). Nobody is doing precise,
selection-scoped reading help for dense material — papers, contracts, specs, legal prose —
at zero marginal friction. That's the lane.
