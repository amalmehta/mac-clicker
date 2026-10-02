import Foundation

/// A mini-task that runs against what the cursor has highlighted, what's on screen,
/// or both.
///
/// Adding a skill is the whole extension point: append one to `Skill.all` and it
/// appears in the picker. The flags decide what gets gathered before the model runs,
/// so a skill never pays for context it doesn't need — a text explanation costs a few
/// hundred tokens, and only the skills that need pixels send an image.
struct Skill: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String

    /// Fail with "nothing highlighted" rather than running without a selection.
    let requiresSelection: Bool
    /// Capture the frontmost window as an image.
    let wantsScreenshot: Bool
    /// Enumerate on-screen accessibility elements so the model can point at them.
    let wantsElements: Bool
    /// Offer the `point_at` tool.
    let canPoint: Bool
    /// Offer whatever tools the user's MCP servers expose. Does nothing until they
    /// configure one, so this costs no tokens by default.
    let usesConnectors: Bool

    /// Stable instructions, free of per-request text.
    let system: String
    /// Builds the user turn.
    let prompt: (SkillContext) -> String

    static func == (lhs: Skill, rhs: Skill) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SkillContext {
    var selection: String?
    var sourceApp: String?
    var audience: String
    /// What the user said, when the skill was started by voice.
    var question: String?
    /// The `AXInventory` listing, when `wantsElements` is set.
    var elements: String?
}

extension Skill {
    static let all: [Skill] = [.explain, .onScreen, .teach, .ask]

    /// Appended to a skill's instructions only when connector tools are actually
    /// present, so the prompt never describes tools that do not exist.
    static let connectorGuidance = """

    You also have tools from services the user has connected themselves. Use one only
    when the answer genuinely depends on something you cannot see in front of you: their
    own notes, files, or records. Do not go looking out of curiosity, do not announce
    that you are searching, and if a lookup comes back empty just answer without it.

    A tool that changes anything is shown to the user for approval before it runs, and
    some servers are limited to reading only. Work with the tools you are actually given
    rather than describing one that is not there.
    """

    // MARK: - Explain highlighted text

    static let explain = Skill(
        id: "explain",
        title: "Explain this",
        subtitle: "Unpack dense prose, jargon, and notation",
        symbol: "text.magnifyingglass",
        requiresSelection: true,
        wantsScreenshot: false,
        wantsElements: false,
        canPoint: false,
        usesConnectors: true,
        system: """
        You explain a passage that someone has highlighted on their screen and is \
        reading right now. They want to keep reading in a few seconds, so your job \
        is to remove the specific obstacle in front of them — not to summarize \
        everything or to teach the whole field.

        Latency-sensitive: begin your visible answer immediately.

        Scale the answer to the selection:
        - A term, symbol, or single sentence: 2–4 sentences of plain prose. No headers.
        - A paragraph or more: lead with 2–3 sentences in plain language, then only \
        the sections below that actually earn their place.

        Sections you may use, in this order, each only if it helps:
        **The claim** — what is being asserted, in one or two bullets, stated the way \
        the authors would state it if they were being blunt.
        **Jargon** — term — definition. Only terms a reader would plausibly stumble on; \
        skip anything the passage itself defines.
        **Notation** — for equations: name each symbol, then say what the whole \
        expression computes and why that form was chosen.
        **Worth noticing** — at most two bullets: a hidden assumption, a scope limit, a \
        hedge that is doing real work, or what would have to be true for this to hold.

        Rules:
        - Plain language over field vocabulary. When you must use a technical term, \
        define it inline the first time.
        - Explain what the text says, not what you assume the surrounding paper says. \
        The selection may start or end mid-sentence, and PDF copying may have mangled \
        ligatures, hyphenation, and math — read through that damage silently rather \
        than commenting on it.
        - If the passage is genuinely ambiguous out of context, give the most likely \
        reading and say in one clause what the other reading would be.
        - No preamble, no restating the passage back, no closing offer to help further.
        - Narrow rendering: short lines, no tables, no headings beyond the bold labels \
        above. Use a fenced code block only when the selection is itself code.
        """,
        prompt: { context in
            var parts: [String] = []
            if let app = context.sourceApp { parts.append("The reader highlighted this in \(app).") }
            parts.append("Explain it for \(context.audience).")
            parts.append("\n<selection>\n\(context.selection ?? "")\n</selection>")
            return parts.joined(separator: "\n")
        }
    )

    // MARK: - Explain what's on screen (the figure a selection can't reach)

    static let onScreen = Skill(
        id: "screen",
        title: "What's on screen",
        subtitle: "Read a figure, chart, diagram, or scanned page",
        symbol: "rectangle.dashed.badge.record",
        requiresSelection: false,
        wantsScreenshot: true,
        wantsElements: false,
        canPoint: false,
        usesConnectors: true,
        system: """
        You are looking at a screenshot of what someone is reading. Usually they \
        pressed the hotkey because the thing confusing them is not selectable text — \
        a figure, a plot, an architecture diagram, an equation rendered as an image, a \
        scanned page, a table.

        Latency-sensitive: begin your visible answer immediately.

        Lead with what the thing *is* and what it's telling them, in 2–3 plain \
        sentences. Then, only where it helps:
        - For a plot: what's on each axis, what the trend is, and what claim the plot is \
        being used to support.
        - For a diagram: the flow — what enters, what transforms it, what comes out.
        - For a table: which comparison it exists to make, and which number is the point.
        - For an equation: name each symbol, then what the whole thing computes.

        Then, if anything deserves it: one or two bullets under **Worth noticing** — a \
        misleading axis, a cherry-picked baseline, a missing error bar, a scope limit.

        Rules:
        - Describe what is actually visible. If the image is too low-resolution or cut \
        off to read a label, say so plainly instead of guessing at it.
        - Ignore the surrounding window chrome, menus, and toolbars unless they *are* \
        the subject.
        - No preamble. No "this screenshot shows". Narrow rendering: short lines, no tables.
        """,
        prompt: { context in
            var parts = ["Explain what's on screen for \(context.audience)."]
            if let app = context.sourceApp { parts.append("The app is \(app).") }
            if let question = context.question, !question.isEmpty {
                parts.append("They asked: \"\(question)\"")
            }
            if let selection = context.selection, !selection.isEmpty {
                parts.append("They also have this text highlighted:\n<selection>\n\(selection)\n</selection>")
            }
            return parts.joined(separator: "\n")
        }
    )

    // MARK: - Teach a tool by pointing at it

    static let teach = Skill(
        id: "teach",
        title: "Show me how",
        subtitle: "Point at the next step in this app",
        symbol: "hand.point.up.left",
        requiresSelection: false,
        wantsScreenshot: true,
        wantsElements: true,
        canPoint: true,
        // Pointing accurately is the whole job here; a pile of unrelated tools
        // only gives it something else to do.
        usesConnectors: false,
        system: """
        You are teaching someone to use the app they're currently looking at. You can \
        see a screenshot of it, and you have a list of the app's real on-screen \
        elements with ids.

        You have one tool: `point_at`. It draws a numbered ring around an element on \
        the user's actual screen. **This is how you teach** — the rings carry the \
        instruction, and your text is just the connective tissue around them.

        How to answer:
        1. Work out the shortest real path to what they want.
        2. Call `point_at` once per step, in order, with a very short imperative label \
        ("Open the Mixer", "Set this to 1/16"). Two to five steps is the useful range.
        3. Alongside the rings, write one short line per step explaining *why*, not \
        where — the ring already shows where.

        Hard rules:
        - **Only use element ids that appear in the ELEMENTS list.** Never invent an id, \
        and never guess screen coordinates. If the element for a step is not in the \
        list — it's behind a menu, in a different window, or not open yet — do not \
        call the tool for that step. Describe it in words instead and say what to open \
        to reveal it.
        - If the list is empty or unusable, just explain in words. This happens in apps \
        that expose no accessibility information, and it is not worth remarking on.
        - Never point at something destructive as a step without saying what it does first.
        - Be honest when you are unsure which of two controls is the right one; say so \
        and point at the more likely one.
        - No preamble, no "great question". Narrow rendering: short lines, no tables.
        """,
        prompt: { context in
            var parts: [String] = []
            if let app = context.sourceApp { parts.append("App: \(app)") }
            if let question = context.question, !question.isEmpty {
                parts.append("They asked: \"\(question)\"")
            } else if let selection = context.selection, !selection.isEmpty {
                parts.append("They highlighted this, which is probably what they're after:\n\(selection)")
            } else {
                parts.append("They pressed the hotkey without saying anything. Work out what they are most likely stuck on from the screenshot, name your assumption in one short clause, and show that.")
            }
            parts.append("Background: \(context.audience).")
            parts.append("\nELEMENTS (the only ids you may point at):\n\(context.elements ?? "(none available)")")
            return parts.joined(separator: "\n")
        }
    )

    // MARK: - Free-form, usually spoken

    static let ask = Skill(
        id: "ask",
        title: "Ask about this",
        subtitle: "A question about the selection or the screen",
        symbol: "bubble.left.and.text.bubble.right",
        requiresSelection: false,
        wantsScreenshot: true,
        wantsElements: false,
        canPoint: false,
        usesConnectors: true,
        system: """
        Answer the question about what the person is looking at. You may be given \
        their highlighted text, a screenshot, or both.

        Latency-sensitive: begin your visible answer immediately.

        Answer the question that was asked, at the length it deserves — a factual \
        question gets a sentence, an explanation gets a few. Do not pad, do not \
        restate the question, do not offer follow-up help.

        The question may have been dictated, so transcription slips are likely: read \
        through obvious mis-hearings using the selection and screenshot as context, and \
        answer what they clearly meant. Ask for clarification only if you genuinely \
        cannot tell what was meant.

        Narrow rendering: short lines, no tables.
        """,
        prompt: { context in
            var parts: [String] = []
            parts.append("Question: \"\(context.question ?? "What is this?")\"")
            if let app = context.sourceApp { parts.append("App: \(app)") }
            parts.append("Background: \(context.audience).")
            if let selection = context.selection, !selection.isEmpty {
                parts.append("Highlighted text:\n<selection>\n\(selection)\n</selection>")
            }
            return parts.joined(separator: "\n")
        }
    )
}
