import CloudKit
import Foundation
import RewardsCore

/// Everything in one child's `Family-<childId>` zone.
struct FamilySnapshot {
    var zone: ZoneRef
    var child: ChildInfo
    var rules: Rules
    /// Kept so a rules save can detect conflicting edits from another parent.
    var rulesRecord: CKRecord?
    var adjustments: [AdjustmentEntry] = []
    var overrides: [SessionOverrideInfo] = []
    var bonuses: [BonusInfo] = []
    var rulesChanges: [RulesChangeInfo] = []
    var parents: [ParentInfo] = []
    var allowLists: [AllowListInfo] = []
    /// Latest modification of any record; used to pick between duplicate zones after a take-over.
    var lastModified: Date = .distantPast

    /// nil if the zone has no `Child` record yet.
    init?(zone: ZoneRef, records: [CKRecord]) {
        guard let childRecord = records.first(where: { $0.recordType == RecordType.child }),
              let child = ChildInfo(record: childRecord) else { return nil }
        self.zone = zone
        self.child = child
        let rulesRecord = records.first { $0.recordType == RecordType.rules }
        self.rulesRecord = rulesRecord
        self.rules = rulesRecord.map(RulesRecord.rules(from:)) ?? .defaults
        for r in records {
            if let m = r.modificationDate, m > lastModified { lastModified = m }
            switch r.recordType {
            case RecordType.adjustment: if let v = AdjustmentEntry(record: r) { adjustments.append(v) }
            case RecordType.sessionOverride: if let v = SessionOverrideInfo(record: r) { overrides.append(v) }
            case RecordType.bonus: if let v = BonusInfo(record: r) { bonuses.append(v) }
            case RecordType.rulesChange: if let v = RulesChangeInfo(record: r) { rulesChanges.append(v) }
            case RecordType.parent: if let v = ParentInfo(record: r) { parents.append(v) }
            case RecordType.allowList: if let v = AllowListInfo(record: r) { allowLists.append(v) }
            default: break
            }
        }
    }

    var childId: String { child.childId }
}

/// Everything in a child's `Activity` zone.
struct ActivitySnapshot {
    var zone: ZoneRef
    var link: LinkInfo?
    var sessions: [SessionInfo] = []
    var spends: [SpendInfo] = []
    var devices: [DeviceInfo] = []

    init(zone: ZoneRef, records: [CKRecord]) {
        self.zone = zone
        for r in records {
            switch r.recordType {
            case RecordType.link: link = LinkInfo(record: r)
            case RecordType.session: if let v = SessionInfo(record: r) { sessions.append(v) }
            case RecordType.spend: if let v = SpendInfo(record: r) { spends.append(v) }
            case RecordType.device: if let v = DeviceInfo(record: r) { devices.append(v) }
            default: break
            }
        }
    }

    static func empty(_ zone: ZoneRef) -> ActivitySnapshot { ActivitySnapshot(zone: zone, records: []) }
}

/// A child's family + activity data with the balance worked out.
struct ChildState {
    var family: FamilySnapshot
    var activity: ActivitySnapshot?
    var resolved: [ResolvedSession]
    var ledger: [LedgerEntry]
    var status: PlayStatus
    var computedAt: Date

    init(family: FamilySnapshot, activity: ActivitySnapshot?, now: Date = Date()) {
        self.family = family
        self.activity = activity
        self.computedAt = now
        resolved = LedgerBuilder.resolve(sessions: activity?.sessions ?? [],
                                         overrides: family.overrides, bonuses: family.bonuses)
        ledger = LedgerBuilder.entries(resolved: resolved, spends: activity?.spends ?? [],
                                       adjustments: family.adjustments)
        status = PlayStatus.compute(rules: family.rules, timeZone: family.child.tz, now: now, entries: ledger)
    }

    var childId: String { family.childId }
    var name: String { family.child.name }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = family.child.tz
        return c
    }

    /// Minutes earned from workouts that ended today in the child's time zone.
    var todayEarned: Int {
        let cal = calendar
        return resolved.filter { cal.isDate($0.session.endedAt, inSameDayAs: computedAt) }
            .reduce(0) { $0 + $1.earnMinutes }
    }

    /// The bonus active right now, if any (the largest multiplier).
    var activeBonus: BonusInfo? {
        family.bonuses.filter { $0.isActive(at: computedAt) }.max { $0.multiplier < $1.multiplier }
    }
}

/// Builds snapshots from the local mirror (`SyncEngine`). `family`/`activity`
/// first bring that one zone up to date; the `cached` variants never touch the network.
enum SnapshotLoader {
    static func family(_ zone: ZoneRef) async throws -> FamilySnapshot? {
        try await SyncEngine.shared.syncZone(zone)
        return await cachedFamily(zone)
    }

    static func activity(_ zone: ZoneRef) async throws -> ActivitySnapshot {
        try await SyncEngine.shared.syncZone(zone)
        return await cachedActivity(zone)
    }

    static func cachedFamily(_ zone: ZoneRef) async -> FamilySnapshot? {
        let records = await SyncEngine.shared.records(in: zone)
        return FamilySnapshot(zone: zone, records: records)
    }

    static func cachedActivity(_ zone: ZoneRef) async -> ActivitySnapshot {
        let records = await SyncEngine.shared.records(in: zone)
        return ActivitySnapshot(zone: zone, records: records)
    }
}

/// What the iPhone sends to the Watch (WatchConnectivity application context),
/// and what the Watch caches.
struct WatchContext: Codable, Hashable, Sendable {
    var childId: String
    var childName: String
    var birthYear: Int
    var rules: Rules
    var bonuses: [BonusInfo]
    var familyZone: ZoneRef?
    var updatedAt: Date

    static let contextKey = "watchContext"

    func activeBonus(at date: Date) -> BonusInfo? {
        bonuses.filter { $0.isActive(at: date) }.max { $0.multiplier < $1.multiplier }
    }
}
