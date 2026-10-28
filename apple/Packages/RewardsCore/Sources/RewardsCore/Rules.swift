import Foundation

/// A time-of-day window in which play is allowed (docs/CONTRACT.md §1).
public struct PlayWindow: Codable, Hashable, Sendable {
    /// ISO weekdays, Monday = 1 ... Sunday = 7.
    public var days: [Int]
    /// "HH:mm"
    public var start: String
    /// "HH:mm", may be "24:00".
    public var end: String

    public init(days: [Int], start: String, end: String) {
        self.days = days
        self.start = start
        self.end = end
    }

    /// Minutes after local midnight, or nil if malformed.
    public var startMinutes: Int? { PlayWindow.minutes(from: start) }
    public var endMinutes: Int? { PlayWindow.minutes(from: end) }

    public static func minutes(from hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...24).contains(h), (0..<60).contains(m), h * 60 + m <= 1440 else { return nil }
        return h * 60 + m
    }

    public static func format(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

/// Per-child rules (docs/CONTRACT.md §1). Keys are camelCase and match CloudKit field names.
public struct Rules: Codable, Hashable, Sendable {
    public var ratio: Int
    public var walkCadenceSpm: Int
    public var walkHrPct: Double
    public var otherHrPct: Double
    public var qualifyFraction: Double
    public var debitLimit: Int
    public var maxBank: Int?
    public var dailyPlayCap: Int?
    public var playWindows: [PlayWindow]?

    public init(
        ratio: Int = 10,
        walkCadenceSpm: Int = 100,
        walkHrPct: Double = 0.55,
        otherHrPct: Double = 0.65,
        qualifyFraction: Double = 0.8,
        debitLimit: Int = 60,
        maxBank: Int? = nil,
        dailyPlayCap: Int? = nil,
        playWindows: [PlayWindow]? = nil
    ) {
        self.ratio = ratio
        self.walkCadenceSpm = walkCadenceSpm
        self.walkHrPct = walkHrPct
        self.otherHrPct = otherHrPct
        self.qualifyFraction = qualifyFraction
        self.debitLimit = debitLimit
        self.maxBank = maxBank
        self.dailyPlayCap = dailyPlayCap
        self.playWindows = playWindows
    }

    public static let defaults = Rules()

    private enum CodingKeys: String, CodingKey {
        case ratio, walkCadenceSpm, walkHrPct, otherHrPct, qualifyFraction
        case debitLimit, maxBank, dailyPlayCap, playWindows
    }

    /// Missing keys fall back to the defaults so older snapshots still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Rules.defaults
        ratio = try c.decodeIfPresent(Int.self, forKey: .ratio) ?? d.ratio
        walkCadenceSpm = try c.decodeIfPresent(Int.self, forKey: .walkCadenceSpm) ?? d.walkCadenceSpm
        walkHrPct = try c.decodeIfPresent(Double.self, forKey: .walkHrPct) ?? d.walkHrPct
        otherHrPct = try c.decodeIfPresent(Double.self, forKey: .otherHrPct) ?? d.otherHrPct
        qualifyFraction = try c.decodeIfPresent(Double.self, forKey: .qualifyFraction) ?? d.qualifyFraction
        debitLimit = try c.decodeIfPresent(Int.self, forKey: .debitLimit) ?? d.debitLimit
        maxBank = try c.decodeIfPresent(Int.self, forKey: .maxBank)
        dailyPlayCap = try c.decodeIfPresent(Int.self, forKey: .dailyPlayCap)
        playWindows = try c.decodeIfPresent([PlayWindow].self, forKey: .playWindows)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ratio, forKey: .ratio)
        try c.encode(walkCadenceSpm, forKey: .walkCadenceSpm)
        try c.encode(walkHrPct, forKey: .walkHrPct)
        try c.encode(otherHrPct, forKey: .otherHrPct)
        try c.encode(qualifyFraction, forKey: .qualifyFraction)
        try c.encode(debitLimit, forKey: .debitLimit)
        try c.encodeIfPresent(maxBank, forKey: .maxBank)
        try c.encodeIfPresent(dailyPlayCap, forKey: .dailyPlayCap)
        try c.encodeIfPresent(playWindows, forKey: .playWindows)
    }
}
