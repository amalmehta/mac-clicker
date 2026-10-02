import XCTest
@testable import MacClickerKit

final class SuggestionPolicyTests: XCTestCase {

    /// Fixed UTC calendar: a policy that rests for five "days" should not change
    /// behaviour because the test ran the weekend the clocks went back.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private lazy var policy = SuggestionPolicy(calendar: calendar)

    private func day(_ number: Int, hour: Int = 9) -> Date {
        DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 1, day: number, hour: hour
        ).date!
    }

    // MARK: - One a day

    func testOffersOnAFreshState() {
        XCTAssertTrue(policy.mayOffer(SuggestionState(), at: day(1)))
    }

    func testDoesNotOfferTwiceInOneDay() {
        let state = policy.offered(SuggestionState(), at: day(1, hour: 9))
        XCTAssertFalse(policy.mayOffer(state, at: day(1, hour: 23)))
    }

    func testOffersAgainTheNextDay() {
        let state = policy.offered(SuggestionState(), at: day(1, hour: 23))
        XCTAssertTrue(policy.mayOffer(state, at: day(2, hour: 1)))
    }

    // MARK: - Dismissal backoff

    func testThreeDismissalsRestForFiveDays() {
        var state = SuggestionState()
        for offset in 0..<3 {
            state = policy.offered(state, at: day(1 + offset))
            state = policy.resolve(state, outcome: .dismissed, at: day(1 + offset))
        }

        XCTAssertFalse(policy.mayOffer(state, at: day(4)), "should be resting")
        XCTAssertFalse(policy.mayOffer(state, at: day(7)), "still resting on day five")
        XCTAssertTrue(policy.mayOffer(state, at: day(9)), "rest is over")
    }

    func testTwoDismissalsDoNotRest() {
        var state = SuggestionState()
        for offset in 0..<2 {
            state = policy.offered(state, at: day(1 + offset))
            state = policy.resolve(state, outcome: .dismissed, at: day(1 + offset))
        }
        XCTAssertTrue(policy.mayOffer(state, at: day(3)))
    }

    func testAcceptingClearsADismissalStreak() {
        var state = SuggestionState()
        for offset in 0..<2 {
            state = policy.offered(state, at: day(1 + offset))
            state = policy.resolve(state, outcome: .dismissed, at: day(1 + offset))
        }
        state = policy.offered(state, at: day(3))
        state = policy.resolve(state, outcome: .accepted, at: day(3))

        // Two more dismissals must not now tip it into a rest: the count restarted.
        for offset in 0..<2 {
            state = policy.offered(state, at: day(4 + offset))
            state = policy.resolve(state, outcome: .dismissed, at: day(4 + offset))
        }
        XCTAssertTrue(policy.mayOffer(state, at: day(6)))
    }

    // MARK: - Ignore backoff

    func testThreeIgnoresRestForOneDay() {
        var state = SuggestionState()
        for offset in 0..<3 {
            state = policy.offered(state, at: day(1 + offset))
            state = policy.resolve(state, outcome: .ignored, at: day(1 + offset))
        }
        XCTAssertFalse(policy.mayOffer(state, at: day(3, hour: 20)))
        XCTAssertTrue(policy.mayOffer(state, at: day(5)))
    }

    func testIgnoreRestDoublesAndCapsAtAWeek() {
        var state = SuggestionState()
        var expected = [1, 2, 4, 7, 7]

        for round in 0..<expected.count {
            for _ in 0..<3 {
                state = policy.offered(state, at: day(1))
                state = policy.resolve(state, outcome: .ignored, at: day(1))
            }
            XCTAssertEqual(
                state.ignoreRestDays, expected[round],
                "round \(round + 1) should rest \(expected[round]) days"
            )
        }
        XCTAssertLessThanOrEqual(state.ignoreRestDays, SuggestionPolicy.Limits.maximumRestDays)
    }

    func testAcceptingResetsTheDoubling() {
        var state = SuggestionState()
        for _ in 0..<6 { // two full ignore rounds: rests of 1 then 2 days
            state = policy.offered(state, at: day(1))
            state = policy.resolve(state, outcome: .ignored, at: day(1))
        }
        XCTAssertEqual(state.ignoreRestDays, 2)

        state = policy.resolve(state, outcome: .accepted, at: day(1))
        XCTAssertEqual(state.ignoreRestDays, 0)
        XCTAssertNil(state.restingUntil)
        XCTAssertTrue(policy.mayOffer(state, at: day(2)))
    }

    // MARK: - Unanswered offers become ignores by themselves

    func testAnUnansweredOfferCountsAsIgnoredWhenTheNextIsMade() {
        var state = SuggestionState()
        state = policy.offered(state, at: day(1))      // never resolved
        state = policy.offered(state, at: day(2))      // retires day 1 as ignored
        XCTAssertEqual(state.consecutiveIgnored, 1)
        XCTAssertNotNil(state.pendingSince)
    }

    func testThreeUnansweredOffersTriggerTheRest() {
        var state = SuggestionState()
        for offset in 0..<4 { // the fourth retires the third
            state = policy.offered(state, at: day(1 + offset))
        }
        XCTAssertNotNil(state.restingUntil)
    }

    // MARK: - Reporting

    func testNextOfferAllowedIsNilWhenFree() {
        XCTAssertNil(policy.nextOfferAllowed(SuggestionState(), at: day(1)))
    }

    func testNextOfferAllowedIsTomorrowAfterOffering() {
        let state = policy.offered(SuggestionState(), at: day(1, hour: 9))
        XCTAssertEqual(policy.nextOfferAllowed(state, at: day(1, hour: 10)), day(2, hour: 0))
    }

    func testNextOfferAllowedIsTheRestEndWhileResting() {
        var state = SuggestionState()
        for offset in 0..<3 {
            state = policy.offered(state, at: day(1 + offset))
            state = policy.resolve(state, outcome: .dismissed, at: day(1 + offset))
        }
        XCTAssertEqual(policy.nextOfferAllowed(state, at: day(4)), state.restingUntil)
    }
}
