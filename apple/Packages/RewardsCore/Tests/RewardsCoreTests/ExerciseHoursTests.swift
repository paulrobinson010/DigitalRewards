import XCTest
import RewardsCore

final class ExerciseHoursTests: XCTestCase {
    /// 2026-11-06 17:00:00 UTC
    private let h17 = Date(timeIntervalSince1970: 1_793_984_400)

    private func sample(_ minuteOffset: Double, _ minutes: Double) -> ExerciseHours.Sample {
        let start = h17.addingTimeInterval(minuteOffset * 60)
        return .init(start: start, end: start.addingTimeInterval(minutes * 60), minutes: minutes)
    }

    func testHourKeyIsUTC() {
        XCTAssertEqual(ExerciseHours.hourKey(h17), "2026110617")
        XCTAssertEqual(ExerciseHours.hourStart(h17.addingTimeInterval(59 * 60 + 59)), h17)
    }

    func testSumsAndRoundsWithinAnHour() {
        let hours = ExerciseHours.buckets([sample(0, 1), sample(1, 1), sample(5, 0.5)], since: nil, ratio: 10)
        XCTAssertEqual(hours.count, 1)
        XCTAssertEqual(hours[0].minutes, 3) // 2.5 rounds away from zero
        XCTAssertEqual(hours[0].earned, 30)
        XCTAssertEqual(hours[0].recordName, "session-exm-2026110617")
        XCTAssertEqual(hours[0].endedAt, h17.addingTimeInterval(5.5 * 60))
    }

    func testSplitsAcrossHourBoundaries() {
        let hours = ExerciseHours.buckets([sample(58, 1), sample(59, 1), sample(60, 1), sample(125, 1)],
                                          since: nil, ratio: 5)
        XCTAssertEqual(hours.map(\.minutes), [2, 1, 1])
        XCTAssertEqual(hours.map(\.earned), [10, 5, 5])
        XCTAssertEqual(hours.map(\.hourStart), [h17, h17.addingTimeInterval(3600), h17.addingTimeInterval(7200)])
        // A sample running past the hour end is capped at the hour end.
        let capped = ExerciseHours.buckets([sample(59, 3)], since: nil, ratio: 10)
        XCTAssertEqual(capped[0].endedAt, h17.addingTimeInterval(3600))
    }

    func testIgnoresSamplesBeforeSinceEvenMidHour() {
        let since = h17.addingTimeInterval(30 * 60)
        let hours = ExerciseHours.buckets([sample(10, 1), sample(29, 1), sample(30, 1), sample(45, 1)],
                                          since: since, ratio: 10)
        XCTAssertEqual(hours.map(\.minutes), [2])
    }

    func testDropsHoursThatRoundToZero() {
        XCTAssertTrue(ExerciseHours.buckets([sample(0, 0.4)], since: nil, ratio: 10).isEmpty)
        XCTAssertTrue(ExerciseHours.buckets([], since: nil, ratio: 10).isEmpty)
    }

    func testRulesDefaultToWatchWhenEarnSourceIsMissing() throws {
        let rules = try JSONDecoder().decode(Rules.self, from: Data(#"{"ratio": 12}"#.utf8))
        XCTAssertEqual(rules.earnSource, .watch)
        XCTAssertNil(rules.earnSourceSince)
        let round = try JSONDecoder().decode(Rules.self, from: JSONEncoder().encode(Rules(earnSource: .exercise, earnSourceSince: h17)))
        XCTAssertEqual(round.earnSource, .exercise)
        XCTAssertEqual(round.earnSourceSince, h17)
    }

    func testRulesDiffNamesEarnSource() {
        let summary = RulesDiff.summary(from: Rules(earnSource: .watch), to: Rules(earnSource: .exercise))
        XCTAssertEqual(summary, "Earn from Go AFK watch workouts → Apple Exercise minutes")
    }
}
