PROJECT NAME: personalized_mac_clicker

meta-instructions:

<run the prompt below, if unclear, or you have ideas that make it more streamlined, ask away and then modify the project instructions below>

<show deliverable components at the end of build>

instructions:

create a mac_widget that enables one to use their cursor and do mini-tasks with it.

for an example, a starter skill could be:

high-light a research-paper and explain it &&&

---

RESOLVED (2026-09-03) — answers to the open questions, now the spec:

- FORM: native macOS menu bar app, Swift + SwiftUI, built with SPM (no Xcode project).
  No Dock icon (LSUIElement). Ships as MacClicker.app via ./build.sh.
- TRIGGER: global hotkey, ⌥Space by default, six presets selectable in Settings.
  Highlight text in any app, press the hotkey, a panel opens at the cursor.
  Pressing it again (or esc, or clicking away) dismisses.
- BRAINS: Anthropic API called directly with the user's own key, stored in the login
  keychain. claude-opus-5, streamed, adaptive thinking, effort configurable
  (low by default), server-side refusal fallbacks on.
- SKILLS IN V1: one — "Explain this", tuned for dense research-paper prose, jargon,
  and notation. Skills are a registry (Sources/MacClicker/Skills/Skill.swift): append
  to Skill.all and it appears automatically. With one skill the hotkey runs it
  directly; with two or more the panel shows a picker first.

Deliberately out of scope for v1 (all cheap to add later on the same skeleton):
summarize, rewrite-and-paste-back, translate, free-form follow-up questions.
