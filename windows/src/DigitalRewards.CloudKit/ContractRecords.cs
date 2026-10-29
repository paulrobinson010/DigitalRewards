using System.Globalization;
using System.Text.Json;
using DigitalRewards.Core;

namespace DigitalRewards.CloudKit;

/// <summary>Zone and record names from CONTRACT §6.</summary>
public static class ContractNames
{
    public const string FamilyZonePrefix = "Family-";
    public const string ActivityZonePrefix = "Activity-";

    public const string Child = "Child";
    public const string Rules = "Rules";
    public const string Adjustment = "Adjustment";
    public const string SessionOverride = "SessionOverride";
    public const string Bonus = "Bonus";
    public const string RulesChange = "RulesChange";
    public const string Parent = "Parent";
    public const string AllowList = "AllowList";
    public const string Session = "Session";
    public const string Spend = "Spend";
    public const string Device = "Device";

    public const string ChildRecordName = "child";
    public const string RulesRecordName = "rules";

    /// <summary>Family-&lt;childId&gt; becomes Activity-&lt;childId&gt;: both zones are owned by the same parent.</summary>
    public static string ActivityZoneFor(string familyZoneName) =>
        ActivityZonePrefix + (familyZoneName.StartsWith(FamilyZonePrefix, StringComparison.Ordinal)
            ? familyZoneName[FamilyZonePrefix.Length..]
            : familyZoneName);

    public static string AllowListRecordName(string deviceId) => "allow-" + deviceId;
    public static string DeviceRecordName(string deviceId) => "device-" + deviceId;

    /// <summary>spend-&lt;deviceId&gt;-&lt;yyyyMMddHHmm UTC of minute start&gt;.</summary>
    public static string SpendRecordName(string deviceId, DateTimeOffset minuteStart) =>
        "spend-" + deviceId + "-" + minuteStart.ToUniversalTime().ToString("yyyyMMddHHmm", CultureInfo.InvariantCulture);
}

public sealed record ChildInfo(string ChildId, string Name, int? BirthYear, string TimeZone);

public sealed record AdjustmentInfo(string RecordName, int Minutes, string? Note, long At, string? ByParent);

public sealed record DetectedApp(string Exe, string Name);

public sealed record SpendInfo(string DeviceId, DateTimeOffset MinuteStart, int Minutes, string App)
{
    public string RecordName => ContractNames.SpendRecordName(DeviceId, MinuteStart);
}

public sealed record DeviceInfo(string DeviceId, string Kind, string Name, DateTimeOffset LastSeenAt, IReadOnlyList<DetectedApp>? DetectedApps);

/// <summary>Converts between <see cref="CloudRecord"/> and contract types.</summary>
public static class ContractRecords
{
    public static ChildInfo ToChild(CloudRecord r) => new(
        r.GetString("childId") ?? "",
        r.GetString("name") ?? "",
        r.GetInt64("birthYear") is { } y ? (int)y : null,
        r.GetString("timeZone") ?? "UTC");

    public static Rules ToRules(CloudRecord r)
    {
        var d = Rules.Default;
        IReadOnlyList<PlayWindow>? windows = null;
        if (r.GetString("playWindows") is { Length: > 0 } json)
        {
            windows = ContractJson.Deserialize<List<PlayWindow>>(json);
        }
        return new Rules
        {
            Ratio = (int?)r.GetInt64("ratio") ?? d.Ratio,
            WalkCadenceSpm = (int?)r.GetInt64("walkCadenceSpm") ?? d.WalkCadenceSpm,
            WalkHrPct = r.GetDouble("walkHrPct") ?? d.WalkHrPct,
            OtherHrPct = r.GetDouble("otherHrPct") ?? d.OtherHrPct,
            QualifyFraction = r.GetDouble("qualifyFraction") ?? d.QualifyFraction,
            DebitLimit = (int?)r.GetInt64("debitLimit") ?? d.DebitLimit,
            MaxBank = (int?)r.GetInt64("maxBank"),
            DailyPlayCap = (int?)r.GetInt64("dailyPlayCap"),
            PlayWindows = windows,
        };
    }

    public static AdjustmentInfo ToAdjustment(CloudRecord r) => new(
        r.RecordName,
        (int)(r.GetInt64("minutes") ?? 0),
        r.GetString("note"),
        r.GetTimestampMs("at") ?? 0,
        r.GetString("byParent"));

    public static SessionOverride ToSessionOverride(CloudRecord r) =>
        new(r.GetString("sessionId") ?? "", (int)(r.GetInt64("earnedMinutes") ?? 0));

    public static Bonus ToBonus(CloudRecord r) =>
        new(r.GetDouble("multiplier") ?? 1.0, r.GetTimestampMs("startsAt") ?? 0, r.GetTimestampMs("endsAt") ?? 0);

    public static SessionSummary ToSession(CloudRecord r) => new(
        r.RecordName,
        (int)(r.GetInt64("earnedMinutes") ?? 0),
        r.GetTimestampMs("startedAt") ?? 0,
        r.GetTimestampMs("endedAt") ?? 0);

    /// <summary>Lowercase exe names; empty when the record is missing or malformed.</summary>
    public static IReadOnlyList<string> ToAllowList(CloudRecord r)
    {
        if (r.GetString("executables") is not { Length: > 0 } json)
        {
            return [];
        }
        try
        {
            return (JsonSerializer.Deserialize<List<string>>(json) ?? [])
                .Select(e => e.Trim().ToLowerInvariant())
                .Where(e => e.Length > 0)
                .ToList();
        }
        catch (JsonException)
        {
            return [];
        }
    }

    public static LedgerEntry ToSpendEntry(CloudRecord r) =>
        new(r.RecordName, EntryKind.Spend, (int)(r.GetInt64("minutes") ?? 0), r.GetTimestampMs("at") ?? 0);

    public static LedgerEntry ToAdjustEntry(CloudRecord r) =>
        new(r.RecordName, EntryKind.Adjust, (int)(r.GetInt64("minutes") ?? 0), r.GetTimestampMs("at") ?? 0);

    public static CloudRecord FromSpend(SpendInfo s) => new CloudRecord(s.RecordName, ContractNames.Spend)
        .Set("minutes", (long)s.Minutes)
        .Set("at", (DateTimeOffset?)s.MinuteStart)
        .Set("deviceId", s.DeviceId)
        .Set("app", s.App);

    public static CloudRecord FromDevice(DeviceInfo d)
    {
        var r = new CloudRecord(ContractNames.DeviceRecordName(d.DeviceId), ContractNames.Device)
            .Set("kind", d.Kind)
            .Set("name", d.Name)
            .Set("lastSeenAt", (DateTimeOffset?)d.LastSeenAt);
        if (d.DetectedApps is not null)
        {
            r.Set("detectedApps", JsonSerializer.Serialize(d.DetectedApps.Select(a => new { exe = a.Exe, name = a.Name })));
        }
        return r;
    }
}

/// <summary>Everything the enforcer needs about one child, decoded from both zones.</summary>
public sealed class ChildSnapshot
{
    public ChildInfo? Child { get; init; }
    public Rules Rules { get; init; } = Rules.Default;
    public IReadOnlyList<SessionSummary> Sessions { get; init; } = [];
    public IReadOnlyList<SessionOverride> Overrides { get; init; } = [];
    public IReadOnlyList<Bonus> Bonuses { get; init; } = [];
    public IReadOnlyList<LedgerEntry> Adjustments { get; init; } = [];
    public IReadOnlyList<LedgerEntry> Spends { get; init; } = [];

    /// <summary>Allowed exes for this PC (lowercase).</summary>
    public IReadOnlyList<string> AllowList { get; init; } = [];

    public string TimeZone => Child?.TimeZone ?? "UTC";

    /// <summary>All ledger entries with sessions resolved per CONTRACT §3.</summary>
    public List<LedgerEntry> Ledger(IEnumerable<LedgerEntry>? extraSpends = null)
    {
        var entries = EarnResolution.ToEntries(Sessions, Overrides, Bonuses);
        entries.AddRange(Adjustments);
        entries.AddRange(Spends);
        if (extraSpends is not null)
        {
            entries.AddRange(extraSpends);
        }
        return entries;
    }

    /// <summary>
    /// Builds a snapshot from the raw records of the child's Family zone and Activity zone.
    /// </summary>
    public static ChildSnapshot From(IEnumerable<CloudRecord> familyRecords, IEnumerable<CloudRecord> activityRecords, string deviceId)
    {
        var family = familyRecords.Where(r => !r.Deleted).ToList();
        var activity = activityRecords.Where(r => !r.Deleted).ToList();
        var childRec = family.FirstOrDefault(r => r.RecordType == ContractNames.Child);
        var rulesRec = family.FirstOrDefault(r => r.RecordType == ContractNames.Rules);
        var allowRec = family.FirstOrDefault(r => r.RecordType == ContractNames.AllowList
                                                  && r.RecordName == ContractNames.AllowListRecordName(deviceId));
        return new ChildSnapshot
        {
            Child = childRec is null ? null : ContractRecords.ToChild(childRec),
            Rules = rulesRec is null ? Rules.Default : ContractRecords.ToRules(rulesRec),
            Overrides = family.Where(r => r.RecordType == ContractNames.SessionOverride).Select(ContractRecords.ToSessionOverride).ToList(),
            Bonuses = family.Where(r => r.RecordType == ContractNames.Bonus).Select(ContractRecords.ToBonus).ToList(),
            Adjustments = family.Where(r => r.RecordType == ContractNames.Adjustment).Select(ContractRecords.ToAdjustEntry).ToList(),
            AllowList = allowRec is null ? [] : ContractRecords.ToAllowList(allowRec),
            Sessions = activity.Where(r => r.RecordType == ContractNames.Session).Select(ContractRecords.ToSession).ToList(),
            Spends = activity.Where(r => r.RecordType == ContractNames.Spend).Select(ContractRecords.ToSpendEntry).ToList(),
        };
    }
}
