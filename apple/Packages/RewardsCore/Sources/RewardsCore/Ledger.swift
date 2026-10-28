import Foundation

public enum LedgerKind: String, Codable, Sendable {
    case earn, spend, adjust

    /// Tie-break order for entries with the same timestamp.
    var sortOrder: Int {
        switch self {
        case .earn: return 0
        case .adjust: return 1
        case .spend: return 2
        }
    }
}

/// One balance-affecting entry (docs/CONTRACT.md §3). `at` is epoch milliseconds.
public struct LedgerEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: LedgerKind
    public var minutes: Int
    public var at: Int64

    public init(id: String, kind: LedgerKind, minutes: Int, at: Int64) {
        self.id = id
        self.kind = kind
        self.minutes = minutes
        self.at = at
    }

    public init(id: String, kind: LedgerKind, minutes: Int, date: Date) {
        self.init(id: id, kind: kind, minutes: minutes, at: Ledger.epochMs(date))
    }

    public var date: Date { Date(timeIntervalSince1970: Double(at) / 1000) }

    /// Signed effect on the balance before any max-bank cap.
    public var delta: Int { kind == .spend ? -minutes : minutes }
}

public enum Ledger {
    public static func epochMs(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Contract order: `at`, then kind (earn < adjust < spend), then id (ordinal).
    public static func sorted(_ entries: [LedgerEntry]) -> [LedgerEntry] {
        entries.sorted { a, b in
            if a.at != b.at { return a.at < b.at }
            if a.kind.sortOrder != b.kind.sortOrder { return a.kind.sortOrder < b.kind.sortOrder }
            return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
        }
    }

    public static func balance(entries: [LedgerEntry], maxBank: Int?) -> Int {
        var seen = Set<String>()
        var balance = 0
        for entry in sorted(entries) {
            guard seen.insert(entry.id).inserted else { continue }
            let delta = entry.delta
            if delta > 0, let maxBank {
                balance = max(balance, min(balance + delta, maxBank))
            } else {
                balance += delta
            }
        }
        return balance
    }
}
