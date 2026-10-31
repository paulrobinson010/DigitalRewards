import Foundation

/// Arcade-style progress for Child mode, derived from workouts only (no stored state).

/// Levels by lifetime qualifying activity minutes.
public enum PlayerLevel: Int, CaseIterable, Comparable, Sendable {
    case rookie, spaceCadet, pilot, captain, commander, legend

    public var title: String {
        switch self {
        case .rookie: return "Rookie"
        case .spaceCadet: return "Space Cadet"
        case .pilot: return "Pilot"
        case .captain: return "Captain"
        case .commander: return "Commander"
        case .legend: return "Legend"
        }
    }

    /// Lifetime qualifying activity minutes needed to reach this level.
    public var threshold: Int {
        switch self {
        case .rookie: return 0
        case .spaceCadet: return 30
        case .pilot: return 120
        case .captain: return 300
        case .commander: return 600
        case .legend: return 1200
        }
    }

    public var next: PlayerLevel? { PlayerLevel(rawValue: rawValue + 1) }

    public static func < (a: PlayerLevel, b: PlayerLevel) -> Bool { a.rawValue < b.rawValue }

    public static func level(forMinutes minutes: Int) -> PlayerLevel {
        allCases.last { minutes >= $0.threshold } ?? .rookie
    }
}

public struct PlayerProgress: Equatable, Sendable {
    public var lifetimeMinutes: Int
    public var level: PlayerLevel
    /// nil at the top level.
    public var nextLevel: PlayerLevel?
    /// Activity minutes still needed for the next level (0 at the top level).
    public var minutesToNext: Int
    /// Progress from this level's threshold to the next, 0...1 (1 at the top level).
    public var fractionToNext: Double

    public init(lifetimeMinutes: Int) {
        let minutes = max(0, lifetimeMinutes)
        self.lifetimeMinutes = minutes
        let level = PlayerLevel.level(forMinutes: minutes)
        self.level = level
        self.nextLevel = level.next
        if let next = level.next {
            let span = next.threshold - level.threshold
            minutesToNext = next.threshold - minutes
            fractionToNext = min(1, max(0, Double(minutes - level.threshold) / Double(span)))
        } else {
            minutesToNext = 0
            fractionToNext = 1
        }
    }
}

public enum Streak {
    /// Consecutive calendar days (in `timeZone`) with at least one active day, counting back
    /// from today. A streak survives until the end of today: if there's nothing yet today,
    /// it counts back from yesterday.
    ///
    /// - Parameter activeDates: when each workout with ≥ 1 qualifying minute ended.
    public static func days(activeDates: [Date], timeZone: TimeZone, now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = Set(activeDates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: now)
        var day = today
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}
