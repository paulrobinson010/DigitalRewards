#if DEBUG
import CloudKit
import Foundation

/// Creates every record type and field in the CloudKit **Development** schema by saving one
/// sample record of each and then deleting it. Run once from a debug build (Xcode), then deploy
/// the schema to Production in the CloudKit Console. Production can't create types on the fly.
///
/// Field names and types must match `cloudkit/schema.ckdb` and `docs/CONTRACT.md` §6. Every
/// field gets a non-nil value, because CloudKit only adds fields that are present.
enum SchemaSeeder {
    private static let zoneName = "SchemaSeed"

    static func run(store: CloudStore = .shared) async throws {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let privateDB = store.database(.privateDB)
        let publicDB = store.database(.publicDB)
        _ = try await privateDB.save(CKRecordZone(zoneID: zoneID))

        let now = Date()
        let privateRecords: [CKRecord] = [
            make("Child", zoneID, ["childId": "seed", "name": "Seed", "birthYear": 2015, "timeZone": "Europe/London"]),
            make("Rules", zoneID, ["ratio": 10, "walkCadenceSpm": 100, "walkHrPct": 0.55, "otherHrPct": 0.65,
                                   "qualifyFraction": 0.8, "debitLimit": 60, "maxBank": 600, "dailyPlayCap": 120,
                                   "playWindows": "[]", "updatedAt": now, "updatedBy": "Seed"]),
            make("Adjustment", zoneID, ["minutes": 1, "note": "seed", "at": now, "byParent": "Seed"]),
            make("SessionOverride", zoneID, ["sessionId": "seed", "earnedMinutes": 0, "note": "seed",
                                             "at": now, "byParent": "Seed"]),
            make("Bonus", zoneID, ["multiplier": 2.0, "startsAt": now, "endsAt": now, "note": "seed",
                                   "at": now, "byParent": "Seed"]),
            make("RulesChange", zoneID, ["summary": "seed", "note": "seed", "at": now, "byParent": "Seed"]),
            make("Parent", zoneID, ["displayName": "Seed", "lookupEmail": "seed@example.com", "lookupPhone": "+440000000000"]),
            make("AllowList", zoneID, ["executables": "[]"]),
            make("Link", zoneID, ["childId": "seed", "familyZoneName": "seed", "familyZoneOwner": "seed"]),
            make("Session", zoneID, ["activityType": "walk", "startedAt": now, "endedAt": now, "minutes": "[]",
                                     "qualifyingMinutes": 0, "earnedMinutes": 0, "rulesSnapshot": "{}",
                                     "deviceId": "seed"]),
            make("Spend", zoneID, ["minutes": 1, "at": now, "deviceId": "seed", "app": "seed.exe"]),
            make("Device", zoneID, ["kind": "windows", "name": "Seed", "lastSeenAt": now, "detectedApps": "[]"]),
            make("AlertPrefs", zoneID, ["deviceSilent": 1, "suspicious": 1, "debit": 1, "workout": 1]),
        ]
        let publicRecords: [CKRecord] = [
            make("Invite", nil, ["kind": "child", "shareURLs": "[]", "expiresAt": now], name: "schema-seed-invite"),
            make("ShareLink", nil, ["shareURL": "https://www.icloud.com/"], name: "schema-seed-sharelink"),
        ]

        try await save(privateRecords, in: privateDB)
        try await save(publicRecords, in: publicDB)

        // Clean up: the types and fields stay in the schema.
        _ = try? await publicDB.modifyRecords(saving: [], deleting: publicRecords.map(\.recordID))
        _ = try? await privateDB.deleteRecordZone(withID: zoneID)
    }

    private static func make(_ type: String, _ zoneID: CKRecordZone.ID?, _ fields: [String: Any],
                             name: String? = nil) -> CKRecord {
        let recordName = name ?? "seed-\(type)"
        let id = zoneID.map { CKRecord.ID(recordName: recordName, zoneID: $0) } ?? CKRecord.ID(recordName: recordName)
        let record = CKRecord(recordType: type, recordID: id)
        for (key, value) in fields {
            switch value {
            case let v as String: record[key] = v as NSString
            case let v as Int: record[key] = NSNumber(value: v)
            case let v as Double: record[key] = NSNumber(value: v)
            case let v as Date: record[key] = v as NSDate
            default: break
            }
        }
        return record
    }

    private static func save(_ records: [CKRecord], in db: CKDatabase) async throws {
        let result = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
        for (_, r) in result.saveResults {
            if case .failure(let error) = r { throw error }
        }
    }
}
#endif
