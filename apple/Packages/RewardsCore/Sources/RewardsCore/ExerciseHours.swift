import Foundation

/// Turns Apple Exercise minutes into one entry per UTC clock hour (docs/CONTRACT.md §2a).
public enum ExerciseHours {
    /// One HealthKit `appleExerciseTime` sample, already filtered to Apple Watch, not hand-entered.
    public struct Sample: Hashable, Sendable {
        public var start: Date
        public var end: Date
        public var minutes: Double

        public init(start: Date, end: Date, minutes: Double) {
            self.start = start
            self.end = end
            self.minutes = minutes
        }
    }

    public struct Hour: Hashable, Sendable {
        public var hourStart: Date
        /// The hour's end, or the last sample's end while the hour is still filling up.
        public var endedAt: Date
        public var minutes: Int
        public var earned: Int

        /// `session-exm-<yyyyMMddHH UTC>`
        public var recordName: String { "session-exm-" + ExerciseHours.hourKey(hourStart) }
    }

    /// Buckets samples starting at or after `since` by the UTC hour they start in.
    /// Hours that round to 0 minutes are left out. Sorted by hour.
    public static func buckets(_ samples: [Sample], since: Date?, ratio: Int) -> [Hour] {
        var totals: [Date: (minutes: Double, lastEnd: Date)] = [:]
        for s in samples where s.minutes > 0 {
            if let since, s.start < since { continue }
            let hour = hourStart(s.start)
            let current = totals[hour] ?? (0, hour)
            totals[hour] = (current.minutes + s.minutes, max(current.lastEnd, s.end))
        }
        return totals.keys.sorted().compactMap { hour in
            let t = totals[hour]!
            let minutes = Int(t.minutes.rounded(.toNearestOrAwayFromZero))
            guard minutes > 0 else { return nil }
            let end = min(hour.addingTimeInterval(3600), t.lastEnd)
            return Hour(hourStart: hour, endedAt: end, minutes: minutes, earned: minutes * ratio)
        }
    }

    public static func hourStart(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / 3600).rounded(.down) * 3600)
    }

    /// `yyyyMMddHH` in UTC.
    public static func hourKey(_ hourStart: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour], from: hourStart)
        return String(format: "%04d%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
    }
}
