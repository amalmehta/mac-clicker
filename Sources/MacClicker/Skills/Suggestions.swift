import Foundation
import MacClickerKit

/// Picks a skill worth mentioning, and decides whether now is a reasonable moment
/// to mention it.
///
/// The decision is `SuggestionPolicy`'s; this adds the two things that need the app:
/// what there is to suggest, and the situational checks the policy deliberately
/// knows nothing about — whether the user turned suggestions off, and whether they
/// are on a call.
@MainActor
enum Suggestions {
    private static let policy = SuggestionPolicy()

    /// Returns a skill to offer, or nil if nothing should be offered now.
    ///
    /// Calling this *records* the offer, so call it only when the result will
    /// actually be shown.
    static func offer(now: Date = Date()) -> Skill? {
        guard Settings.suggestionsEnabled else { return nil }
        guard !Presence.shouldStayQuiet else { return nil }

        var state = Settings.suggestionState
        guard policy.mayOffer(state, at: now) else { return nil }
        guard let skill = unusedSkill() else { return nil }

        state = policy.offered(state, at: now)
        Settings.suggestionState = state
        return skill
    }

    static func resolve(_ outcome: SuggestionOutcome, now: Date = Date()) {
        Settings.suggestionState = policy.resolve(
            Settings.suggestionState, outcome: outcome, at: now
        )
    }

    static func recordUse(of skill: Skill) {
        var usage = Settings.skillUsage
        usage[skill.id, default: 0] += 1
        Settings.skillUsage = usage
    }

    /// When the next suggestion could appear, for showing in Settings.
    static func nextAllowed(now: Date = Date()) -> Date? {
        policy.nextOfferAllowed(Settings.suggestionState, at: now)
    }

    /// The least-used skill, as long as it has never been used. Once every skill has
    /// been tried there is nothing honest left to suggest, so it goes quiet for good.
    private static func unusedSkill() -> Skill? {
        let usage = Settings.skillUsage
        return Skill.all
            .filter { usage[$0.id, default: 0] == 0 }
            .min { lhs, rhs in lhs.id < rhs.id }
    }
}
