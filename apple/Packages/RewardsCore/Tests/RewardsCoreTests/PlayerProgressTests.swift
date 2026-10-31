import RewardsCore
import XCTest

final class PlayerProgressTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: Levels

    func testLevelThresholds() {
        XCTAssertEqual(PlayerLevel.level(forMinutes: 0), .rookie)
        XCTAssertEqual(PlayerLevel.level(forMinutes: 29), .rookie)
        XCTAssertEqual(PlayerLevel.level(forMinutes: 30), .spaceCadet)
        XCTAssertEqual(PlayerLevel.level(forMinutes: 119), .spaceCadet)
        XCTAssertEqual(PlayerLevel.level(forMinutes: 120), .pilot)
        XCTAssertEqual(PlayerLevel.level(forMinutes: 300), .captain)
        XCTAssertEqual(PlayerLevel.level(forMinutes: 600), .commander)
        XCTAssertEqual(PlayerLevel.level(forMinutes: 1200), .legend)
        XCTAssertEqual(PlayerLevel.level(forMinutes: 99_999), .legend)
    }

    func testProgressToNextLevel() {
        let p = PlayerProgress(lifetimeMinutes: 75)   // Space Cadet: 30 → 120
        XCTAssertEqual(p.level, .spaceCadet)
        XCTAssertEqual(p.nextLevel, .pilot)
        XCTAssertEqual(p.minutesToNext, 45)
        XCTAssertEqual(p.fractionToNext, 0.5, accuracy: 1e-9)
    }

    func testProgressAtTopLevel() {
        let p = PlayerProgress(lifetimeMinutes: 5000)
        XCTAssertEqual(p.level, .legend)
        XCTAssertNil(p.nextLevel)
        XCTAssertEqual(p.minutesToNext, 0)
        XCTAssertEqual(p.fractionToNext, 1)
    }

    func testNegativeMinutesClampToZero() {
        let p = PlayerProgress(lifetimeMinutes: -10)
        XCTAssertEqual(p.lifetimeMinutes, 0)
        XCTAssertEqual(p.level, .rookie)
        XCTAssertEqual(p.minutesToNext, 30)
    }

    // MARK: Streaks

    func testNoActivityIsZero() {
        XCTAssertEqual(Streak.days(activeDates: [], timeZone: london, now: date("2026-10-31T12:00:00Z")), 0)
    }

    func testStreakIncludingToday() {
        let dates = [date("2026-10-29T17:00:00Z"), date("2026-10-30T08:00:00Z"),
                     date("2026-10-31T09:00:00Z"), date("2026-10-31T10:00:00Z")]
        XCTAssertEqual(Streak.days(activeDates: dates, timeZone: london, now: date("2026-10-31T12:00:00Z")), 3)
    }

    func testStreakSurvivesUntilEndOfToday() {
        let dates = [date("2026-10-29T17:00:00Z"), date("2026-10-30T08:00:00Z")]
        XCTAssertEqual(Streak.days(activeDates: dates, timeZone: london, now: date("2026-10-31T20:00:00Z")), 2)
    }

    func testStreakBrokenByMissedDay() {
        let dates = [date("2026-10-28T17:00:00Z"), date("2026-10-29T08:00:00Z")]
        XCTAssertEqual(Streak.days(activeDates: dates, timeZone: london, now: date("2026-10-31T12:00:00Z")), 0)
    }

    func testGapEarlierStopsCount() {
        let dates = [date("2026-10-27T17:00:00Z"), date("2026-10-30T08:00:00Z"), date("2026-10-31T08:00:00Z")]
        XCTAssertEqual(Streak.days(activeDates: dates, timeZone: london, now: date("2026-10-31T12:00:00Z")), 2)
    }

    func testUsesChildsTimeZone() {
        // 23:30 on 30 Oct in New York is 03:30 on 31 Oct UTC: still the 30th for the child.
        let ny = TimeZone(identifier: "America/New_York")!
        let dates = [date("2026-10-29T22:00:00Z"), date("2026-10-31T03:30:00Z")]
        XCTAssertEqual(Streak.days(activeDates: dates, timeZone: ny, now: date("2026-10-31T14:00:00Z")), 2)
    }
}
