import CloudKit
import Foundation

/// Local mirror of the CloudKit zones this device reads, kept current with change
/// tokens so a refresh only downloads what changed.
///
/// - Each zone's records live on disk together with the zone's server change token.
///   Fetches ask CloudKit only for records added, changed or deleted since then.
/// - Each database (private, shared) keeps a database change token, so zones with
///   no changes aren't contacted at all.
/// - The app's own saves and deletes are applied straight away (see `CloudStore`),
///   so the UI reflects them before the next fetch, and while offline.
/// - `records(in:)` never touches the network, so screens can show the last known
///   state at launch.
///
/// On disk, a zone is a folder of numbered chunks: a base chunk with every record,
/// followed by small delta chunks. Every chunk carries the change token that was
/// current when it was written, so a token is never saved ahead of its records.
/// Deltas are folded into a new base every `maxDeltas` writes.
///
/// The public database isn't mirrored; invite codes and share links are fetched by name.
actor SyncEngine {
    static let shared = SyncEngine()

    private static let maxDeltas = 32

    private let store: CloudStore
    private let root: URL
    private var indexes: [CloudScope: ScopeIndex] = [:]
    private var states: [ZoneRef: ZoneState] = [:]
    private var running: [CloudScope: Task<Void, Error>] = [:]
    private var accountChecked = false

    init(store: CloudStore = .shared) {
        self.store = store
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = caches.appendingPathComponent("DigitalRewardsSync", isDirectory: true)
    }

    // MARK: Reading (local only)

    /// Zones mirrored from a database: everything seen by the last sync, plus zones
    /// fetched individually (e.g. a share just accepted).
    func knownZones(_ scope: CloudScope) -> [ZoneRef] {
        index(scope).zones
    }

    /// Every mirrored record in a zone (no share records).
    func records(in zone: ZoneRef) -> [CKRecord] {
        Array(loadedState(Self.normalized(zone)).records.values)
    }

    // MARK: Syncing

    /// Brings every zone in a database up to date. Concurrent calls for the same
    /// database share one fetch.
    func sync(_ scope: CloudScope) async throws {
        #if DEBUG
        // Screenshot mode never touches iCloud.
        if ScreenshotMode.isOn { return }
        #endif
        precondition(scope != .publicDB, "The public database isn't mirrored")
        if let task = running[scope] {
            try await task.value
            return
        }
        let task = Task { try await self.syncDatabase(scope) }
        running[scope] = task
        defer { running[scope] = nil }
        try await task.value
    }

    /// Brings one zone up to date and keeps mirroring it from now on.
    func syncZone(_ zone: ZoneRef) async throws {
        #if DEBUG
        // Screenshot mode never touches iCloud.
        if ScreenshotMode.isOn { return }
        #endif
        try await ensureAccount()
        let zone = Self.normalized(zone)
        do {
            try await fetchChanges(zone)
            track(zone)
        } catch let error where Self.zoneIsGone(error) {
            drop(zone)
            throw error
        }
    }

    // MARK: Own writes

    /// Applies records this device just saved. Only zones already mirrored are
    /// updated; any other zone is picked up in full by its first sync.
    func didSave(_ records: [CKRecord], scope: CloudScope) {
        guard scope != .publicDB else { return }
        let byZone = Dictionary(grouping: records.filter { !($0 is CKShare) }) {
            Self.normalized(ZoneRef(zoneID: $0.recordID.zoneID, scope: scope))
        }
        for (zone, saved) in byZone where isTracked(zone) {
            var upserts: [String: CKRecord] = [:]
            for record in saved { upserts[record.recordID.recordName] = record }
            apply(zone, upserts: upserts, deletes: [], token: loadedState(zone).token, reset: false)
        }
    }

    /// Applies deletes this device just made.
    func didDelete(_ ids: [CKRecord.ID], scope: CloudScope) {
        guard scope != .publicDB else { return }
        let byZone = Dictionary(grouping: ids) { Self.normalized(ZoneRef(zoneID: $0.zoneID, scope: scope)) }
        for (zone, deleted) in byZone where isTracked(zone) {
            apply(zone, upserts: [:], deletes: Set(deleted.map(\.recordName)),
                  token: loadedState(zone).token, reset: false)
        }
    }

    // MARK: Fetching

    private func syncDatabase(_ scope: CloudScope) async throws {
        try await ensureAccount()
        let previous = index(scope).token.flatMap(Self.decodeToken)
        let delta = try await databaseChanges(scope, since: previous)

        var toFetch = delta.changed
        if delta.fromScratch {
            // No usable database token: every zone is a candidate (each still
            // fetches incrementally from its own token), and zones that no longer
            // exist are forgotten.
            let all = try await store.allZones(scope)
                .map { Self.normalized(ZoneRef(zoneID: $0.zoneID, scope: scope)) }
                .filter(Self.isMirrorable)
            for zone in index(scope).zones where !all.contains(zone) {
                drop(zone)
            }
            toFetch = all
        }
        for zone in delta.deleted {
            drop(zone)
        }
        // A zone whose local copy went missing (caches purged) needs a full fetch
        // even when the database reports no change.
        for zone in index(scope).zones where loadedState(zone).token == nil && !toFetch.contains(zone) {
            toFetch.append(zone)
        }

        var firstError: Error?
        for zone in toFetch where !delta.deleted.contains(zone) && Self.isMirrorable(zone) {
            do {
                try await fetchChanges(zone)
                track(zone)
            } catch {
                if Self.zoneIsGone(error) {
                    drop(zone)
                } else if firstError == nil {
                    firstError = error
                }
            }
        }
        // Only move the database token on once every changed zone is safely mirrored;
        // otherwise the next sync is told about the same zones again.
        if let firstError { throw firstError }
        let newToken = delta.token.flatMap(Self.encodeToken)
        updateIndex(scope) { $0.token = newToken }
    }

    private struct DatabaseDelta {
        var changed: [ZoneRef] = []
        var deleted: [ZoneRef] = []
        var token: CKServerChangeToken?
        var fromScratch: Bool
    }

    private func databaseChanges(_ scope: CloudScope, since start: CKServerChangeToken?) async throws -> DatabaseDelta {
        var token = start
        var delta = DatabaseDelta(fromScratch: start == nil)
        while true {
            let page: CloudStore.DatabaseChanges
            do {
                page = try await store.fetchDatabaseChanges(scope, since: token)
            } catch let error where error.ckCode == .changeTokenExpired && token != nil {
                token = nil
                delta = DatabaseDelta(fromScratch: true)
                continue
            }
            for id in page.changedZoneIDs {
                let zone = Self.normalized(ZoneRef(zoneID: id, scope: scope))
                guard Self.isMirrorable(zone) else { continue }
                delta.deleted.removeAll { $0 == zone }
                if !delta.changed.contains(zone) { delta.changed.append(zone) }
            }
            for id in page.deletedZoneIDs {
                let zone = Self.normalized(ZoneRef(zoneID: id, scope: scope))
                delta.changed.removeAll { $0 == zone }
                if !delta.deleted.contains(zone) { delta.deleted.append(zone) }
            }
            let advanced = page.token != nil && page.token != token
            token = page.token ?? token
            delta.token = token
            if !page.moreComing || !advanced { return delta }
        }
    }

    /// Fetches a zone's changes since its stored token and applies them. An expired
    /// token restarts the zone from scratch.
    private func fetchChanges(_ zone: ZoneRef) async throws {
        var token = loadedState(zone).token
        var reset = false
        var upserts: [String: CKRecord] = [:]
        var deletes = Set<String>()
        while true {
            let page: CloudStore.ZoneChanges
            do {
                page = try await store.fetchZoneChanges(zone, since: token)
            } catch let error where error.ckCode == .changeTokenExpired && token != nil {
                token = nil
                reset = true
                upserts = [:]
                deletes = []
                continue
            }
            for event in page.events {
                if let record = event.record {
                    upserts[event.name] = record
                    deletes.remove(event.name)
                } else {
                    upserts[event.name] = nil
                    deletes.insert(event.name)
                }
            }
            let advanced = page.token != nil && page.token != token
            token = page.token ?? token
            if !page.moreComing || !advanced { break }
        }
        apply(zone, upserts: upserts, deletes: deletes, token: token, reset: reset)
    }

    // MARK: State

    private func apply(_ zone: ZoneRef, upserts: [String: CKRecord], deletes: Set<String>,
                       token: CKServerChangeToken?, reset: Bool) {
        let previous = loadedState(zone)
        if !reset, upserts.isEmpty, deletes.isEmpty, token == previous.token { return }

        var next = reset ? ZoneState() : previous
        for name in deletes { next.records[name] = nil }
        for (name, record) in upserts { next.records[name] = record }
        next.token = token
        next.seq = previous.seq + 1

        let tokenData = token.flatMap(Self.encodeToken)
        if reset || next.deltaCount >= Self.maxDeltas {
            next.deltaCount = 0
            let base = Chunk(seq: next.seq, isBase: true, token: tokenData,
                             upserts: Self.encodeRecords(next.records), deletes: [])
            if write(base, to: chunkURL(zone, seq: next.seq)) {
                removeChunks(before: next.seq, in: zone)
            }
        } else {
            next.deltaCount += 1
            let chunk = Chunk(seq: next.seq, isBase: false, token: tokenData,
                              upserts: Self.encodeRecords(upserts), deletes: Array(deletes))
            _ = write(chunk, to: chunkURL(zone, seq: next.seq))
        }
        states[zone] = next
    }

    private func loadedState(_ zone: ZoneRef) -> ZoneState {
        if let cached = states[zone] { return cached }
        let files = (try? FileManager.default.contentsOfDirectory(at: zoneDir(zone), includingPropertiesForKeys: nil)) ?? []
        let decoder = PropertyListDecoder()
        var chunks: [Chunk] = []
        var damaged = false
        for file in files where file.pathExtension == "plist" {
            if let data = try? Data(contentsOf: file), let chunk = try? decoder.decode(Chunk.self, from: data) {
                chunks.append(chunk)
            } else {
                damaged = true
            }
        }
        chunks.sort { $0.seq < $1.seq }

        var state = ZoneState()
        // A missing or unreadable chunk could hide changes behind a newer token, so
        // start the zone again rather than trust it.
        if !damaged {
            let baseSeq = chunks.last(where: { $0.isBase })?.seq ?? 0
            for chunk in chunks where chunk.seq >= baseSeq {
                for name in chunk.deletes { state.records[name] = nil }
                for (name, data) in chunk.upserts {
                    if let record = Self.decodeRecord(data) { state.records[name] = record }
                }
                state.token = chunk.token.flatMap(Self.decodeToken)
                state.seq = chunk.seq
                if !chunk.isBase { state.deltaCount += 1 }
            }
        } else {
            try? FileManager.default.removeItem(at: zoneDir(zone))
        }
        states[zone] = state
        return state
    }

    private func index(_ scope: CloudScope) -> ScopeIndex {
        if let cached = indexes[scope] { return cached }
        let loaded = (try? Data(contentsOf: indexURL(scope)))
            .flatMap { try? PropertyListDecoder().decode(ScopeIndex.self, from: $0) } ?? ScopeIndex()
        indexes[scope] = loaded
        return loaded
    }

    private func updateIndex(_ scope: CloudScope, _ change: (inout ScopeIndex) -> Void) {
        var value = index(scope)
        change(&value)
        indexes[scope] = value
        _ = write(value, to: indexURL(scope))
    }

    /// The default zone doesn't support change fetches ("AppDefaultZone does not
    /// support getChanges call"), and the apps keep nothing in it, so it's never mirrored.
    private static func isMirrorable(_ zone: ZoneRef) -> Bool {
        zone.zoneName != CKRecordZone.ID.defaultZoneName
    }

    private func isTracked(_ zone: ZoneRef) -> Bool {
        index(zone.scope).zones.contains(zone)
    }

    private func track(_ zone: ZoneRef) {
        guard !isTracked(zone) else { return }
        updateIndex(zone.scope) { $0.zones.append(zone) }
    }

    private func drop(_ zone: ZoneRef) {
        states[zone] = nil
        try? FileManager.default.removeItem(at: zoneDir(zone))
        if isTracked(zone) {
            updateIndex(zone.scope) { $0.zones.removeAll { $0 == zone } }
        }
    }

    /// The mirror belongs to one iCloud account; start again if it changed.
    private func ensureAccount() async throws {
        guard !accountChecked else { return }
        let user = try await store.currentUserRecordName()
        guard !accountChecked else { return }
        let marker = root.appendingPathComponent("account")
        if (try? String(contentsOf: marker, encoding: .utf8)) != user {
            try? FileManager.default.removeItem(at: root)
            indexes = [:]
            states = [:]
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? user.write(to: marker, atomically: true, encoding: .utf8)
        }
        accountChecked = true
    }

    // MARK: Files

    private func scopeDir(_ scope: CloudScope) -> URL {
        root.appendingPathComponent(scope.rawValue, isDirectory: true)
    }

    private func indexURL(_ scope: CloudScope) -> URL {
        scopeDir(scope).appendingPathComponent("index.plist")
    }

    private func zoneDir(_ zone: ZoneRef) -> URL {
        let name = Self.safe(zone.ownerName) + "~" + Self.safe(zone.zoneName)
        return scopeDir(zone.scope).appendingPathComponent(name, isDirectory: true)
    }

    private func chunkURL(_ zone: ZoneRef, seq: Int) -> URL {
        zoneDir(zone).appendingPathComponent("\(seq).plist")
    }

    private func removeChunks(before seq: Int, in zone: ZoneRef) {
        let files = (try? FileManager.default.contentsOfDirectory(at: zoneDir(zone), includingPropertiesForKeys: nil)) ?? []
        for file in files {
            if let n = Int(file.deletingPathExtension().lastPathComponent), n < seq {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(value).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: Helpers

    /// Private-database zones are keyed by name only; the owner can come back as
    /// either the current user's record name or `CKCurrentUserDefaultName`.
    static func normalized(_ zone: ZoneRef) -> ZoneRef {
        guard zone.scope == .privateDB else { return zone }
        var copy = zone
        copy.ownerName = CKCurrentUserDefaultName
        return copy
    }

    private static func zoneIsGone(_ error: Error) -> Bool {
        guard let code = error.ckCode else { return false }
        return code == .zoneNotFound || code == .userDeletedZone
    }

    private static func safe(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
    }

    private static func encodeRecords(_ records: [String: CKRecord]) -> [String: Data] {
        var result: [String: Data] = [:]
        for (name, record) in records {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true) {
                result[name] = data
            }
        }
        return result
    }

    private static func decodeRecord(_ data: Data) -> CKRecord? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
    }

    private static func encodeToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func decodeToken(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }
}

/// Per-database bookkeeping: the database change token and the zones mirrored.
private struct ScopeIndex: Codable {
    var token: Data?
    var zones: [ZoneRef] = []
}

/// One file in a zone's folder. A base chunk holds every record; a delta holds
/// changes since the previous chunk. Records are keyed-archived `CKRecord`s.
private struct Chunk: Codable {
    var seq: Int
    var isBase: Bool
    var token: Data?
    var upserts: [String: Data]
    var deletes: [String]
}

/// A zone in memory.
private struct ZoneState {
    var records: [String: CKRecord] = [:]
    var token: CKServerChangeToken?
    var seq = 0
    var deltaCount = 0
}
