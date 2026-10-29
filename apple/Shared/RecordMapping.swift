import CloudKit
import Foundation
import RewardsCore

enum RecordType {
    static let child = "Child"
    static let rules = "Rules"
    static let adjustment = "Adjustment"
    static let parent = "Parent"
    static let sessionOverride = "SessionOverride"
    static let bonus = "Bonus"
    static let rulesChange = "RulesChange"
    static let allowList = "AllowList"
    static let session = "Session"
    static let spend = "Spend"
    static let device = "Device"
    static let alertPrefs = "AlertPrefs"
    static let invite = "Invite"
}

// MARK: - Typed field access

extension CKRecord {
    func string(_ key: String) -> String? { object(forKey: key) as? String }
    func int(_ key: String) -> Int? { (object(forKey: key) as? NSNumber)?.intValue }
    func double(_ key: String) -> Double? { (object(forKey: key) as? NSNumber)?.doubleValue }
    func date(_ key: String) -> Date? { object(forKey: key) as? Date }
    func bool(_ key: String) -> Bool? { int(key).map { $0 != 0 } }

    func put(_ key: String, _ value: String?) { setObject(value.map { $0 as NSString }, forKey: key) }
    func put(_ key: String, _ value: Int?) { setObject(value.map { NSNumber(value: $0) }, forKey: key) }
    func put(_ key: String, _ value: Double?) { setObject(value.map { NSNumber(value: $0) }, forKey: key) }
    func put(_ key: String, _ value: Date?) { setObject(value.map { $0 as NSDate }, forKey: key) }
    func put(_ key: String, _ value: Bool) { setObject(NSNumber(value: value ? 1 : 0), forKey: key) }
}

// MARK: - Family zone

extension ChildInfo {
    static let recordName = "child"

    init?(record: CKRecord) {
        guard let childId = record.string("childId"), let name = record.string("name") else { return nil }
        self.init(childId: childId, name: name,
                  birthYear: record.int("birthYear") ?? 2015,
                  timeZone: record.string("timeZone") ?? TimeZone.current.identifier)
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: RecordType.child, recordID: .init(recordName: Self.recordName, zoneID: zoneID))
        apply(to: r)
        return r
    }

    func apply(to r: CKRecord) {
        r.put("childId", childId)
        r.put("name", name)
        r.put("birthYear", birthYear)
        r.put("timeZone", timeZone)
    }
}

enum RulesRecord {
    static let recordName = "rules"

    static func rules(from r: CKRecord) -> Rules {
        let d = Rules.defaults
        return Rules(
            ratio: r.int("ratio") ?? d.ratio,
            walkCadenceSpm: r.int("walkCadenceSpm") ?? d.walkCadenceSpm,
            walkHrPct: r.double("walkHrPct") ?? d.walkHrPct,
            otherHrPct: r.double("otherHrPct") ?? d.otherHrPct,
            qualifyFraction: r.double("qualifyFraction") ?? d.qualifyFraction,
            debitLimit: r.int("debitLimit") ?? d.debitLimit,
            maxBank: r.int("maxBank"),
            dailyPlayCap: r.int("dailyPlayCap"),
            playWindows: JSONText.decode([PlayWindow].self, from: r.string("playWindows"))
        )
    }

    static func apply(_ rules: Rules, to r: CKRecord, updatedBy: String) {
        r.put("ratio", rules.ratio)
        r.put("walkCadenceSpm", rules.walkCadenceSpm)
        r.put("walkHrPct", rules.walkHrPct)
        r.put("otherHrPct", rules.otherHrPct)
        r.put("qualifyFraction", rules.qualifyFraction)
        r.put("debitLimit", rules.debitLimit)
        r.put("maxBank", rules.maxBank)
        r.put("dailyPlayCap", rules.dailyPlayCap)
        let windows: String? = (rules.playWindows?.isEmpty ?? true) ? nil : JSONText.encode(rules.playWindows)
        r.put("playWindows", windows)
        r.put("updatedAt", Date())
        r.put("updatedBy", updatedBy)
    }

    static func makeRecord(_ rules: Rules, zoneID: CKRecordZone.ID, updatedBy: String) -> CKRecord {
        let r = CKRecord(recordType: RecordType.rules, recordID: .init(recordName: recordName, zoneID: zoneID))
        apply(rules, to: r, updatedBy: updatedBy)
        return r
    }
}

extension AdjustmentEntry {
    init?(record: CKRecord) {
        guard let minutes = record.int("minutes") else { return nil }
        self.init(id: record.recordID.recordName, minutes: minutes,
                  note: record.string("note") ?? "",
                  at: record.date("at") ?? record.creationDate ?? Date(),
                  byParent: record.string("byParent") ?? "")
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: RecordType.adjustment, recordID: .init(recordName: id, zoneID: zoneID))
        r.put("minutes", minutes)
        r.put("note", note)
        r.put("at", at)
        r.put("byParent", byParent)
        return r
    }

    static func newRecordName() -> String { "adjust-" + UUID().uuidString.lowercased() }
}

extension ParentInfo {
    static func recordName(userRecordName: String) -> String { "parent-" + userRecordName }
    static func pendingRecordName(lookup: String) -> String { "parent-invite-" + LookupKey.recordSafe(lookup) }

    init?(record: CKRecord) {
        self.init(recordName: record.recordID.recordName,
                  displayName: record.string("displayName") ?? "Parent",
                  lookupEmail: record.string("lookupEmail"),
                  lookupPhone: record.string("lookupPhone"))
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: RecordType.parent, recordID: .init(recordName: recordName, zoneID: zoneID))
        r.put("displayName", displayName)
        r.put("lookupEmail", lookupEmail)
        r.put("lookupPhone", lookupPhone)
        return r
    }
}

extension SessionOverrideInfo {
    static func recordName(sessionId: String) -> String { "override-" + sessionId }

    init?(record: CKRecord) {
        guard let sessionId = record.string("sessionId"), let minutes = record.int("earnedMinutes") else { return nil }
        self.init(sessionId: sessionId, earnedMinutes: max(0, minutes),
                  note: record.string("note") ?? "",
                  at: record.date("at") ?? record.creationDate ?? Date(),
                  byParent: record.string("byParent") ?? "")
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: RecordType.sessionOverride,
                         recordID: .init(recordName: Self.recordName(sessionId: sessionId), zoneID: zoneID))
        r.put("sessionId", sessionId)
        r.put("earnedMinutes", max(0, earnedMinutes))
        r.put("note", note)
        r.put("at", at)
        r.put("byParent", byParent)
        return r
    }
}

extension BonusInfo {
    static func newRecordName() -> String { "bonus-" + UUID().uuidString.lowercased() }

    init?(record: CKRecord) {
        guard let multiplier = record.double("multiplier"),
              let startsAt = record.date("startsAt"), let endsAt = record.date("endsAt") else { return nil }
        self.init(id: record.recordID.recordName, multiplier: multiplier, startsAt: startsAt, endsAt: endsAt,
                  note: record.string("note") ?? "",
                  at: record.date("at") ?? record.creationDate ?? Date(),
                  byParent: record.string("byParent") ?? "")
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: RecordType.bonus, recordID: .init(recordName: id, zoneID: zoneID))
        r.put("multiplier", multiplier)
        r.put("startsAt", startsAt)
        r.put("endsAt", endsAt)
        r.put("note", note)
        r.put("at", at)
        r.put("byParent", byParent)
        return r
    }
}

extension RulesChangeInfo {
    static func newRecordName() -> String { "ruleschange-" + UUID().uuidString.lowercased() }

    init?(record: CKRecord) {
        self.init(id: record.recordID.recordName,
                  summary: record.string("summary") ?? "",
                  note: record.string("note") ?? "",
                  at: record.date("at") ?? record.creationDate ?? Date(),
                  byParent: record.string("byParent") ?? "")
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: RecordType.rulesChange, recordID: .init(recordName: id, zoneID: zoneID))
        r.put("summary", summary)
        r.put("note", note)
        r.put("at", at)
        r.put("byParent", byParent)
        return r
    }
}

extension AllowListInfo {
    static func recordName(deviceId: String) -> String { "allow-" + deviceId }

    init?(record: CKRecord) {
        let name = record.recordID.recordName
        guard name.hasPrefix("allow-") else { return nil }
        self.init(deviceId: String(name.dropFirst("allow-".count)),
                  executables: JSONText.decode([String].self, from: record.string("executables")) ?? [])
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: RecordType.allowList,
                         recordID: .init(recordName: Self.recordName(deviceId: deviceId), zoneID: zoneID))
        r.put("executables", JSONText.encode(executables.map { $0.lowercased() }))
        return r
    }
}

// MARK: - Activity zone

extension SessionInfo {
    static func recordName(uuid: UUID) -> String { "session-" + uuid.uuidString.lowercased() }

    init?(record: CKRecord) {
        guard let type = record.string("activityType").flatMap(ActivityType.init(rawValue:)),
              let startedAt = record.date("startedAt"), let endedAt = record.date("endedAt") else { return nil }
        self.init(id: record.recordID.recordName, activityType: type,
                  startedAt: startedAt, endedAt: endedAt,
                  minutes: JSONText.decode([MinuteResult].self, from: record.string("minutes")) ?? [],
                  qualifyingMinutes: record.int("qualifyingMinutes") ?? 0,
                  earnedMinutes: record.int("earnedMinutes") ?? 0,
                  rulesSnapshot: JSONText.decode(Rules.self, from: record.string("rulesSnapshot")) ?? .defaults,
                  deviceId: record.string("deviceId") ?? "")
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: RecordType.session, recordID: .init(recordName: id, zoneID: zoneID))
        r.put("activityType", activityType.rawValue)
        r.put("startedAt", startedAt)
        r.put("endedAt", endedAt)
        r.put("minutes", JSONText.encode(minutes))
        r.put("qualifyingMinutes", qualifyingMinutes)
        r.put("earnedMinutes", earnedMinutes)
        r.put("rulesSnapshot", JSONText.encode(rulesSnapshot))
        r.put("deviceId", deviceId)
        return r
    }
}

extension SpendInfo {
    init?(record: CKRecord) {
        guard let minutes = record.int("minutes"), let at = record.date("at") else { return nil }
        self.init(id: record.recordID.recordName, minutes: minutes, at: at,
                  deviceId: record.string("deviceId") ?? "", app: record.string("app") ?? "")
    }
}

extension DeviceInfo {
    static func recordName(deviceId: String) -> String { "device-" + deviceId }

    init?(record: CKRecord) {
        let name = record.recordID.recordName
        guard name.hasPrefix("device-") else { return nil }
        self.init(deviceId: String(name.dropFirst("device-".count)),
                  kind: record.string("kind").flatMap(DeviceKind.init(rawValue:)) ?? .ios,
                  name: record.string("name") ?? "Device",
                  lastSeenAt: record.date("lastSeenAt") ?? .distantPast,
                  detectedApps: JSONText.decode([DetectedApp].self, from: record.string("detectedApps")))
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: RecordType.device,
                         recordID: .init(recordName: Self.recordName(deviceId: deviceId), zoneID: zoneID))
        r.put("kind", kind.rawValue)
        r.put("name", name)
        r.put("lastSeenAt", lastSeenAt)
        if let detectedApps { r.put("detectedApps", JSONText.encode(detectedApps)) }
        return r
    }
}

// MARK: - Prefs zone

extension AlertPrefsInfo {
    static func recordName(childId: String) -> String { "alerts-" + childId }

    init(record: CKRecord, childId: String) {
        self.init(childId: childId,
                  deviceSilent: record.bool("deviceSilent") ?? true,
                  suspicious: record.bool("suspicious") ?? true,
                  debit: record.bool("debit") ?? true,
                  workout: record.bool("workout") ?? true)
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let r = CKRecord(recordType: RecordType.alertPrefs,
                         recordID: .init(recordName: Self.recordName(childId: childId), zoneID: zoneID))
        r.put("deviceSilent", deviceSilent)
        r.put("suspicious", suspicious)
        r.put("debit", debit)
        r.put("workout", workout)
        return r
    }
}

// MARK: - Public database

extension InviteInfo {
    static func recordName(code: String) -> String { "invite-" + code }

    init?(record: CKRecord) {
        let name = record.recordID.recordName
        guard name.hasPrefix("invite-"),
              let kind = record.string("kind").flatMap(InviteKind.init(rawValue:)) else { return nil }
        let urls = (JSONText.decode([String].self, from: record.string("shareURLs")) ?? []).compactMap(URL.init(string:))
        self.init(code: String(name.dropFirst("invite-".count)), kind: kind, shareURLs: urls,
                  expiresAt: record.date("expiresAt") ?? .distantPast)
    }

    func makeRecord() -> CKRecord {
        let r = CKRecord(recordType: RecordType.invite, recordID: .init(recordName: Self.recordName(code: code)))
        r.put("kind", kind.rawValue)
        r.put("shareURLs", JSONText.encode(shareURLs.map(\.absoluteString)))
        r.put("expiresAt", expiresAt)
        return r
    }
}
