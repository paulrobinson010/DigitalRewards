import Foundation
import RewardsCore

// Plain value types for the records in docs/CONTRACT.md §5.
// CKRecord mapping lives in RecordMapping.swift.

struct ChildInfo: Codable, Hashable, Sendable {
    var childId: String
    var name: String
    var birthYear: Int
    var timeZone: String

    var tz: TimeZone { TimeZone(identifier: timeZone) ?? .current }
}

struct AdjustmentEntry: Codable, Hashable, Sendable, Identifiable {
    var id: String          // recordName "adjust-<uuid>"
    var minutes: Int
    var note: String
    var at: Date
    var byParent: String
}

struct ParentInfo: Codable, Hashable, Sendable, Identifiable {
    var recordName: String  // "parent-<userRecordName>" (or "parent-invite-<lookup>" until they join)
    var displayName: String
    var lookupEmail: String?
    var lookupPhone: String?

    var id: String { recordName }

    /// Normalised lookup keys used to match share participants.
    var lookupKeys: Set<String> {
        var keys = Set<String>()
        if let e = lookupEmail, !e.isEmpty { keys.insert(LookupKey.email(e)) }
        if let p = lookupPhone, !p.isEmpty { keys.insert(LookupKey.phone(p)) }
        return keys
    }
}

enum LookupKey {
    static func email(_ s: String) -> String { "e:" + s.trimmingCharacters(in: .whitespaces).lowercased() }
    static func phone(_ s: String) -> String { "p:" + s.filter { $0.isNumber || $0 == "+" } }
    /// A record-name-safe form of a lookup value.
    static func recordSafe(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}

struct AllowListInfo: Codable, Hashable, Sendable {
    var deviceId: String
    var executables: [String]
}

struct SessionInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String          // recordName "session-<uuid>"
    var activityType: ActivityType
    var startedAt: Date
    var endedAt: Date
    var minutes: [MinuteResult]
    var qualifyingMinutes: Int
    var earnedMinutes: Int
    var rulesSnapshot: Rules
    var deviceId: String
}

struct SpendInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String          // recordName "spend-<deviceId>-<yyyyMMddHHmm>"
    var minutes: Int
    var at: Date
    var deviceId: String
    var app: String
}

struct DetectedApp: Codable, Hashable, Sendable, Identifiable {
    var exe: String
    var name: String
    var id: String { exe }
}

enum DeviceKind: String, Codable, Sendable {
    case watch, ios, windows
}

struct DeviceInfo: Codable, Hashable, Sendable, Identifiable {
    var deviceId: String
    var kind: DeviceKind
    var name: String
    var lastSeenAt: Date
    var detectedApps: [DetectedApp]?
    var id: String { deviceId }
}

struct AlertPrefsInfo: Codable, Hashable, Sendable {
    var childId: String
    var deviceSilent = true
    var suspicious = true
    var debit = true
    var workout = true
}

enum InviteKind: String, Codable, Sendable {
    case child, parent
}

struct InviteInfo: Codable, Hashable, Sendable {
    var code: String
    var kind: InviteKind
    var shareURLs: [URL]
    var expiresAt: Date
}

enum JSONText {
    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Parent actions visible to the child (docs/CONTRACT.md "Transparency to the child")

struct SessionOverrideInfo: Codable, Hashable, Sendable, Identifiable {
    var sessionId: String
    var earnedMinutes: Int  // 0 = void
    var note: String
    var at: Date
    var byParent: String
    var id: String { "override-" + sessionId }
}

struct BonusInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String          // recordName "bonus-<uuid>"
    var multiplier: Double
    var startsAt: Date
    var endsAt: Date
    var note: String
    var at: Date
    var byParent: String

    var label: String { BonusInfo.label(multiplier) }

    static func label(_ m: Double) -> String {
        let s = m == m.rounded() ? String(Int(m)) : String(format: "%g", m)
        return "\(s)× bonus"
    }

    func isActive(at date: Date) -> Bool { startsAt <= date && date < endsAt }

    var window: BonusWindow {
        BonusWindow(multiplier: multiplier, startsAt: Ledger.epochMs(startsAt), endsAt: Ledger.epochMs(endsAt))
    }
}

struct RulesChangeInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String          // recordName "ruleschange-<uuid>"
    var summary: String
    var note: String
    var at: Date
    var byParent: String
}

/// How one workout ended up counting toward the balance.
struct ResolvedSession: Hashable, Sendable, Identifiable {
    var session: SessionInfo
    var sessionOverride: SessionOverrideInfo?
    /// The bonus that applied (only when not overridden).
    var bonus: BonusInfo?
    var earnMinutes: Int
    /// What the workout would earn without the override (base × bonus).
    var originalMinutes: Int
    var id: String { session.id }
    var isVoided: Bool { sessionOverride?.earnedMinutes == 0 }
}

/// Builds the contract ledger (§3–4) from the record types.
enum LedgerBuilder {
    static func earnSession(_ s: SessionInfo) -> EarnSession {
        EarnSession(id: s.id, earnedMinutes: s.earnedMinutes,
                    startedAt: Ledger.epochMs(s.startedAt), endedAt: Ledger.epochMs(s.endedAt))
    }

    static func resolve(sessions: [SessionInfo], overrides: [SessionOverrideInfo], bonuses: [BonusInfo]) -> [ResolvedSession] {
        let earnOverrides = overrides.map { EarnOverride(sessionId: $0.sessionId, earnedMinutes: $0.earnedMinutes) }
        let windows = bonuses.map(\.window)
        return sessions.map { s in
            let es = earnSession(s)
            let match = overrides.first { $0.sessionId == s.id }
            var bonus: BonusInfo?
            if match == nil {
                bonus = bonuses.filter { $0.window.contains(es.startedAt) }.max { $0.multiplier < $1.multiplier }
            }
            return ResolvedSession(session: s, sessionOverride: match, bonus: bonus,
                                   earnMinutes: EarnResolution.earnMinutes(session: es, overrides: earnOverrides,
                                                                           bonuses: windows),
                                   originalMinutes: EarnResolution.earnMinutes(session: es, overrides: [],
                                                                               bonuses: windows))
        }
    }

    static func entries(resolved: [ResolvedSession], spends: [SpendInfo], adjustments: [AdjustmentEntry]) -> [LedgerEntry] {
        resolved.map { LedgerEntry(id: $0.session.id, kind: .earn, minutes: $0.earnMinutes, date: $0.session.endedAt) }
            + spends.map { LedgerEntry(id: $0.id, kind: .spend, minutes: $0.minutes, date: $0.at) }
            + adjustments.map { LedgerEntry(id: $0.id, kind: .adjust, minutes: $0.minutes, date: $0.at) }
    }
}
