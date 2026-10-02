import Foundation

/// How an offered suggestion ended.
public enum SuggestionOutcome: String, Codable, Sendable {
    /// The user acted on it. Clears every streak.
    case accepted
    /// The user actively said no.
    case dismissed
    /// Offered, and never answered either way before the next one came due.
    case ignored
}

/// Persisted state of the backoff. Codable so it can live in `UserDefaults` as JSON
/// rather than as a scatter of individual keys.
public struct SuggestionState: Codable, Equatable, Sendable {
    public var lastOfferedAt: Date?
    /// An offer that has been shown but not yet accepted or dismissed.
    public var pendingSince: Date?
    public var consecutiveDismissals: Int = 0
    public var consecutiveIgnored: Int = 0
    /// Nothing may be offered until this moment.
    public var restingUntil: Date?
    /// Length of the current ignore-driven rest, which doubles each time.
    public var ignoreRestDays: Int = 0

    public init() {}
}

/// Decides whether an unprompted suggestion may appear right now.
///
/// The rules and their numbers are taken from what Hey Clicky arrived at after
/// twenty weeks of user complaints, which is cheaper than rediscovering them:
///
///  * At most one suggestion a day.
///  * Dismissed three days running → rest five days.
///  * Three offers ignored in a row → rest one day, doubling each time it happens
///    again, never longer than a week.
///  * Acting on one suggestion clears every streak, because the user just told you
///    the suggestions are worth something.
///
/// The type is deliberately free of AppKit, clocks, and storage so the behaviour can
/// be tested at speed rather than inferred. Anything the user explicitly asked for
/// must never be routed through this — it governs unprompted output only.
public struct SuggestionPolicy: Sendable {

    public enum Limits {
        public static let dismissalsBeforeRest = 3
        public static let dismissalRestDays = 5
        public static let ignoresBeforeRest = 3
        public static let firstIgnoreRestDays = 1
        public static let maximumRestDays = 7
    }

    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: - Asking

    /// Whether an unprompted suggestion may be shown at `now`.
    ///
    /// Callers must still check anything situational — whether the microphone is
    /// live, whether the user turned suggestions off — which is not this type's job.
    public func mayOffer(_ state: SuggestionState, at now: Date) -> Bool {
        if let restingUntil = state.restingUntil, now < restingUntil { return false }
        if let lastOfferedAt = state.lastOfferedAt,
           calendar.isDate(lastOfferedAt, inSameDayAs: now) { return false }
        return true
    }

    /// When the next offer becomes possible, for showing in settings.
    public func nextOfferAllowed(_ state: SuggestionState, at now: Date) -> Date? {
        if let restingUntil = state.restingUntil, now < restingUntil { return restingUntil }
        if let lastOfferedAt = state.lastOfferedAt,
           calendar.isDate(lastOfferedAt, inSameDayAs: now) {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        }
        return nil
    }

    // MARK: - Recording

    /// Records that a suggestion was shown.
    ///
    /// An offer still pending from last time was evidently never answered, so it is
    /// retired as `ignored` first — that is what makes the ignore streak accumulate
    /// without the UI having to track anything.
    public func offered(_ state: SuggestionState, at now: Date) -> SuggestionState {
        var next = state
        if next.pendingSince != nil {
            next = resolve(next, outcome: .ignored, at: now)
        }
        next.lastOfferedAt = now
        next.pendingSince = now
        return next
    }

    public func resolve(
        _ state: SuggestionState, outcome: SuggestionOutcome, at now: Date
    ) -> SuggestionState {
        var next = state
        next.pendingSince = nil

        switch outcome {
        case .accepted:
            // The user found one useful, so none of the prior reluctance counts.
            next.consecutiveDismissals = 0
            next.consecutiveIgnored = 0
            next.ignoreRestDays = 0
            next.restingUntil = nil

        case .dismissed:
            next.consecutiveIgnored = 0
            next.consecutiveDismissals += 1
            if next.consecutiveDismissals >= Limits.dismissalsBeforeRest {
                next.consecutiveDismissals = 0
                next.restingUntil = calendar.date(
                    byAdding: .day, value: Limits.dismissalRestDays, to: now
                )
            }

        case .ignored:
            next.consecutiveDismissals = 0
            next.consecutiveIgnored += 1
            if next.consecutiveIgnored >= Limits.ignoresBeforeRest {
                next.consecutiveIgnored = 0
                let days = next.ignoreRestDays == 0
                    ? Limits.firstIgnoreRestDays
                    : min(next.ignoreRestDays * 2, Limits.maximumRestDays)
                next.ignoreRestDays = days
                next.restingUntil = calendar.date(byAdding: .day, value: days, to: now)
            }
        }
        return next
    }
}
