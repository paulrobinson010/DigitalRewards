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

struct LinkInfo: Codable, Hashable, Sendable {
    var childId: String
    var familyZoneName: String
    var familyZoneOwner: String
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

/// Builds the contract ledger (§3) from the three record types.
enum LedgerBuilder {
    static func entries(sessions: [SessionInfo], spends: [SpendInfo], adjustments: [AdjustmentEntry]) -> [LedgerEntry] {
        sessions.map { LedgerEntry(id: $0.id, kind: .earn, minutes: $0.earnedMinutes, date: $0.endedAt) }
            + spends.map { LedgerEntry(id: $0.id, kind: .spend, minutes: $0.minutes, date: $0.at) }
            + adjustments.map { LedgerEntry(id: $0.id, kind: .adjust, minutes: $0.minutes, date: $0.at) }
    }
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
