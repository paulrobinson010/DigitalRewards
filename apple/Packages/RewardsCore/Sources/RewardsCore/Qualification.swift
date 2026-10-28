import Foundation

public enum ActivityType: String, Codable, CaseIterable, Sendable {
    case walk, cycle, other
}

/// One completed minute of active workout time (docs/CONTRACT.md §2).
/// `hr` and `cad` are averages kept for display only.
public struct MinuteResult: Codable, Hashable, Sendable {
    public var p: Int
    public var t: Int
    public var hr: Double?
    public var cad: Double?

    public init(p: Int, t: Int, hr: Double? = nil, cad: Double? = nil) {
        self.p = p
        self.t = t
        self.hr = hr
        self.cad = cad
    }
}

public enum Qualification {
    public static func roundHalfAwayFromZero(_ x: Double) -> Int {
        Int(x.rounded(.toNearestOrAwayFromZero))
    }

    public static func maxHeartRate(birthYear: Int, atYear: Int) -> Int {
        220 - (atYear - birthYear)
    }

    public static func hrThresholdBpm(pct: Double, birthYear: Int, atYear: Int) -> Int {
        roundHalfAwayFromZero(pct * Double(maxHeartRate(birthYear: birthYear, atYear: atYear)))
    }

    public static func hrThresholdBpm(rules: Rules, activity: ActivityType, birthYear: Int, atYear: Int) -> Int {
        let pct = activity == .walk ? rules.walkHrPct : rules.otherHrPct
        return hrThresholdBpm(pct: pct, birthYear: birthYear, atYear: atYear)
    }

    /// Whether one ~5 s sample is at or above the bar. `cadence` is steps per minute.
    public static func samplePasses(
        rules: Rules, activity: ActivityType, birthYear: Int, atYear: Int,
        hr: Int?, cadence: Double?
    ) -> Bool {
        let threshold = hrThresholdBpm(rules: rules, activity: activity, birthYear: birthYear, atYear: atYear)
        guard let hr, hr >= threshold else { return false }
        switch activity {
        case .walk:
            guard let cadence else { return false }
            return cadence >= Double(rules.walkCadenceSpm)
        case .cycle, .other:
            return true
        }
    }

    public static func minuteQualifies(rules: Rules, passed p: Int, total t: Int) -> Bool {
        t > 0 && Double(p) >= rules.qualifyFraction * Double(t) - 1e-9
    }

    public static func qualifyingMinutes(rules: Rules, minutes: [MinuteResult]) -> Int {
        minutes.filter { minuteQualifies(rules: rules, passed: $0.p, total: $0.t) }.count
    }

    public static func earnedMinutes(rules: Rules, minutes: [MinuteResult]) -> Int {
        qualifyingMinutes(rules: rules, minutes: minutes) * rules.ratio
    }
}

/// Groups sample ticks into minutes of active time. Feed one tick per sample
/// interval while the workout is running (not while paused); every
/// `samplesPerMinute` ticks a `MinuteResult` is completed. A partial minute
/// at the end is discarded.
public struct MinuteAccumulator: Sendable {
    public let samplesPerMinute: Int
    public private(set) var completed: [MinuteResult] = []

    private var passed = 0
    private var total = 0
    private var hrSum = 0.0
    private var hrCount = 0
    private var cadSum = 0.0
    private var cadCount = 0

    public init(samplesPerMinute: Int = 12) {
        self.samplesPerMinute = samplesPerMinute
    }

    /// Ticks recorded so far in the current, incomplete minute.
    public var ticksInCurrentMinute: Int { total }

    /// Records one sample tick. Returns the minute it completed, if any.
    @discardableResult
    public mutating func add(passed didPass: Bool, hr: Double?, cadence: Double?) -> MinuteResult? {
        total += 1
        if didPass { passed += 1 }
        if let hr { hrSum += hr; hrCount += 1 }
        if let cadence { cadSum += cadence; cadCount += 1 }
        guard total >= samplesPerMinute else { return nil }
        let minute = MinuteResult(
            p: passed, t: total,
            hr: hrCount > 0 ? hrSum / Double(hrCount) : nil,
            cad: cadCount > 0 ? cadSum / Double(cadCount) : nil
        )
        completed.append(minute)
        passed = 0; total = 0; hrSum = 0; hrCount = 0; cadSum = 0; cadCount = 0
        return minute
    }
}
