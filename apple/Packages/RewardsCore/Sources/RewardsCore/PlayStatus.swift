import Foundation

public enum PlayBlockReason: String, Codable, Sendable {
    case outsidePlayWindow, dailyCapReached, debitLimitReached
}

/// Whether the child can play right now (docs/CONTRACT.md §4).
public struct PlayStatus: Equatable, Sendable {
    public var balance: Int
    public var todayPlayed: Int
    public var minutesAvailable: Int
    public var canPlay: Bool
    public var reason: PlayBlockReason?

    public init(balance: Int, todayPlayed: Int, minutesAvailable: Int, canPlay: Bool, reason: PlayBlockReason?) {
        self.balance = balance
        self.todayPlayed = todayPlayed
        self.minutesAvailable = minutesAvailable
        self.canPlay = canPlay
        self.reason = reason
    }

    public static func compute(rules: Rules, timeZone: TimeZone, now: Date, entries: [LedgerEntry]) -> PlayStatus {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let balance = Ledger.balance(entries: entries, maxBank: rules.maxBank)
        let todayPlayed = entries
            .filter { $0.kind == .spend && calendar.isDate($0.date, inSameDayAs: now) }
            .reduce(0) { $0 + $1.minutes }

        let fromBalance = balance + rules.debitLimit
        let fromCap: Int? = rules.dailyPlayCap.map { $0 - todayPlayed }
        let fromWindow: Int? = windowMinutesLeft(rules.playWindows, calendar: calendar, now: now)

        let available = max(0, min(fromBalance, fromCap ?? Int.max, fromWindow ?? Int.max))
        let canPlay = available > 0
        var reason: PlayBlockReason?
        if !canPlay {
            if let w = fromWindow, w <= 0 {
                reason = .outsidePlayWindow
            } else if let c = fromCap, c <= 0 {
                reason = .dailyCapReached
            } else {
                reason = .debitLimitReached
            }
        }
        return PlayStatus(balance: balance, todayPlayed: todayPlayed,
                          minutesAvailable: available, canPlay: canPlay, reason: reason)
    }

    /// nil = no windows configured (unlimited); 0 = outside every window.
    static func windowMinutesLeft(_ windows: [PlayWindow]?, calendar: Calendar, now: Date) -> Int? {
        guard let windows, !windows.isEmpty else { return nil }
        let c = calendar.dateComponents([.weekday, .hour, .minute, .second, .nanosecond], from: now)
        // Calendar weekday: Sunday = 1 ... Saturday = 7. ISO: Monday = 1 ... Sunday = 7.
        let isoWeekday = ((c.weekday ?? 1) + 5) % 7 + 1
        let t = Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
            + Double(c.second ?? 0) / 60
            + Double(c.nanosecond ?? 0) / 60e9
        var best = 0
        for w in windows where w.days.contains(isoWeekday) {
            guard let s = w.startMinutes, let e = w.endMinutes, Double(s) <= t, t < Double(e) else { continue }
            best = max(best, Int((Double(e) - t).rounded(.up)))
        }
        return best
    }
}
