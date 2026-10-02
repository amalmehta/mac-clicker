import Foundation
import Carbon.HIToolbox
import MacClickerKit

/// A hotkey the user can pick in Settings. Carbon hotkeys are used (rather than a
/// CGEvent tap) because they work without Accessibility permission and never
/// swallow keystrokes the app doesn't claim.
struct HotKeyPreset: Identifiable, Hashable {
    let id: String
    let label: String
    let keyCode: UInt32
    let modifiers: UInt32

    static let all: [HotKeyPreset] = [
        HotKeyPreset(id: "opt-space",       label: "⌥ Space",  keyCode: 49, modifiers: UInt32(optionKey)),
        HotKeyPreset(id: "ctrl-opt-space",  label: "⌃⌥ Space", keyCode: 49, modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(id: "cmd-shift-space", label: "⇧⌘ Space", keyCode: 49, modifiers: UInt32(cmdKey | shiftKey)),
        HotKeyPreset(id: "opt-e",           label: "⌥ E",      keyCode: 14, modifiers: UInt32(optionKey)),
        HotKeyPreset(id: "ctrl-opt-e",      label: "⌃⌥ E",     keyCode: 14, modifiers: UInt32(controlKey | optionKey)),
        HotKeyPreset(id: "cmd-shift-e",     label: "⇧⌘ E",     keyCode: 14, modifiers: UInt32(cmdKey | shiftKey))
    ]

    static let fallback = HotKeyPreset.all[0]
}

/// How hard Claude thinks before answering. Lower effort is noticeably faster and
/// cheaper; `low` is a strong default on Opus 5 for explain-style tasks.
enum Effort: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var label: String {
        switch self {
        case .low: return "Low — fastest"
        case .medium: return "Medium"
        case .high: return "High — most thorough"
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let hotKey = "hotKeyPresetID"
        static let effort = "effort"
        static let audience = "audience"
        static let voiceHotKey = "voiceHotKeyPresetID"
        static let speak = "speakAnnouncements"
        static let annotate = "showAnnotations"
        static let quietOnCalls = "quietOnCalls"
        static let keychainOwner = "keychainOwnedBySignature"
        static let suggestionsOn = "suggestionsEnabled"
        static let suggestionState = "suggestionState"
        static let skillUsage = "skillUsage"
    }

    /// Whether unprompted suggestions may appear at all.
    static var suggestionsEnabled: Bool {
        get { flag(Key.suggestionsOn, default: true) }
        set { defaults.set(newValue, forKey: Key.suggestionsOn) }
    }

    /// Backoff state, stored as one JSON blob rather than a scatter of keys.
    static var suggestionState: SuggestionState {
        get {
            guard let data = defaults.data(forKey: Key.suggestionState),
                  let state = try? JSONDecoder().decode(SuggestionState.self, from: data)
            else { return SuggestionState() }
            return state
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.suggestionState)
        }
    }

    /// How many times each skill has been run, so suggestions can name one the user
    /// has never tried.
    static var skillUsage: [String: Int] {
        get { defaults.dictionary(forKey: Key.skillUsage) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: Key.skillUsage) }
    }

    /// The code signature that last took ownership of the stored key. When this
    /// stops matching the running build, the keychain item needs reclaiming.
    static var keychainOwnerSignature: String {
        get { defaults.string(forKey: Key.keychainOwner) ?? "" }
        set { defaults.set(newValue, forKey: Key.keychainOwner) }
    }

    /// Registers a default so a missing key reads as `true` rather than `false`.
    private static func flag(_ key: String, default value: Bool) -> Bool {
        defaults.register(defaults: [key: value])
        return defaults.bool(forKey: key)
    }

    static var hotKey: HotKeyPreset {
        get {
            let id = defaults.string(forKey: Key.hotKey) ?? HotKeyPreset.fallback.id
            return HotKeyPreset.all.first { $0.id == id } ?? .fallback
        }
        set { defaults.set(newValue.id, forKey: Key.hotKey) }
    }

    static var effort: Effort {
        get { Effort(rawValue: defaults.string(forKey: Key.effort) ?? "") ?? .low }
        set { defaults.set(newValue.rawValue, forKey: Key.effort) }
    }

    /// Second hotkey: hold to ask by voice.
    static var voiceHotKey: HotKeyPreset {
        get {
            let id = defaults.string(forKey: Key.voiceHotKey) ?? "ctrl-opt-space"
            return HotKeyPreset.all.first { $0.id == id } ?? HotKeyPreset.all[1]
        }
        set { defaults.set(newValue.id, forKey: Key.voiceHotKey) }
    }

    /// Speak short status lines out loud.
    static var speakAnnouncements: Bool {
        get { flag(Key.speak, default: false) }
        set { defaults.set(newValue, forKey: Key.speak) }
    }

    /// Let a skill draw on the screen to point at things.
    static var showAnnotations: Bool {
        get { flag(Key.annotate, default: true) }
        set { defaults.set(newValue, forKey: Key.annotate) }
    }

    /// Suppress anything unprompted while the microphone is live.
    static var quietOnCalls: Bool {
        get { flag(Key.quietOnCalls, default: true) }
        set { defaults.set(newValue, forKey: Key.quietOnCalls) }
    }

    /// Free-text description of who the explanation is for. Steers reading level.
    static var audience: String {
        get { defaults.string(forKey: Key.audience) ?? "a technical reader outside this paper's subfield" }
        set { defaults.set(newValue, forKey: Key.audience) }
    }
}
