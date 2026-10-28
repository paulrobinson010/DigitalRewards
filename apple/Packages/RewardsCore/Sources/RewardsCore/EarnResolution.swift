import Foundation

/// The parts of a Session that earn resolution needs. Times are epoch milliseconds.
public struct EarnSession: Codable, Hashable, Sendable {
    public var id: String
    public var earnedMinutes: Int
    public var startedAt: Int64
    public var endedAt: Int64

    public init(id: String, earnedMinutes: Int, startedAt: Int64, endedAt: Int64) {
        self.id = id
        self.earnedMinutes = earnedMinutes
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// A parent's replacement value for a session's earned minutes (0 = void).
public struct EarnOverride: Codable, Hashable, Sendable {
    public var sessionId: String
    public var earnedMinutes: Int

    public init(sessionId: String, earnedMinutes: Int) {
        self.sessionId = sessionId
        self.earnedMinutes = earnedMinutes
    }
}

/// A multiplier for sessions that start in `[startsAt, endsAt)`. Times are epoch milliseconds.
public struct BonusWindow: Codable, Hashable, Sendable {
    public var multiplier: Double
    public var startsAt: Int64
    public var endsAt: Int64

    public init(multiplier: Double, startsAt: Int64, endsAt: Int64) {
        self.multiplier = multiplier
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    public func contains(_ t: Int64) -> Bool { startsAt <= t && t < endsAt }
}

/// Turns sessions into earn entries (docs/CONTRACT.md §3).
public enum EarnResolution {
    /// The largest multiplier active at `startedAt`, or 1.0. Bonuses never stack.
    public static func multiplier(at startedAt: Int64, bonuses: [BonusWindow]) -> Double {
        bonuses.filter { $0.contains(startedAt) }.map(\.multiplier).max() ?? 1.0
    }

    public static func override(for sessionId: String, in overrides: [EarnOverride]) -> EarnOverride? {
        overrides.first { $0.sessionId == sessionId }
    }

    /// Override wins outright; otherwise base × max active multiplier, rounded half away from zero.
    public static func earnMinutes(session: EarnSession, overrides: [EarnOverride], bonuses: [BonusWindow]) -> Int {
        if let o = override(for: session.id, in: overrides) { return o.earnedMinutes }
        let m = multiplier(at: session.startedAt, bonuses: bonuses)
        return Qualification.roundHalfAwayFromZero(Double(session.earnedMinutes) * m)
    }

    /// Earn ledger entries: id = session id, at = endedAt.
    public static func entries(sessions: [EarnSession], overrides: [EarnOverride], bonuses: [BonusWindow]) -> [LedgerEntry] {
        sessions.map {
            LedgerEntry(id: $0.id, kind: .earn,
                        minutes: earnMinutes(session: $0, overrides: overrides, bonuses: bonuses),
                        at: $0.endedAt)
        }
    }
}
