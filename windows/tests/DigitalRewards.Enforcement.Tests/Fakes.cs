using DigitalRewards.CloudKit;
using DigitalRewards.Enforcement;

namespace DigitalRewards.Enforcement.Tests;

public sealed class ManualClock(DateTimeOffset start) : TimeProvider
{
    public DateTimeOffset Now { get; set; } = start;
    public override DateTimeOffset GetUtcNow() => Now;
    public void Advance(TimeSpan by) => Now += by;
}

public sealed class FakeSessions : ISessionProvider
{
    public List<UserSession> List { get; } = [];
    public IReadOnlyList<UserSession> Sessions() => List.ToList();
}

public sealed class FakeProcesses : IProcessController
{
    public Dictionary<int, List<ProcessRef>> BySession { get; } = [];
    public List<int> Killed { get; } = [];

    public IReadOnlyList<ProcessRef> ProcessesInSession(int sessionId) =>
        BySession.TryGetValue(sessionId, out var l) ? l.ToList() : [];

    public bool Kill(int pid)
    {
        Killed.Add(pid);
        foreach (var l in BySession.Values)
        {
            l.RemoveAll(p => p.Pid == pid);
        }
        return true;
    }
}

public sealed class FakeLauncher : IAgentLauncher
{
    public HashSet<int> Running { get; } = [];
    public List<int> Launched { get; } = [];
    public bool IsAgentRunning(int sessionId) => Running.Contains(sessionId);
    public void Launch(int sessionId)
    {
        Launched.Add(sessionId);
        Running.Add(sessionId);
    }
}

public sealed class FakeApps : IAppCatalog
{
    public IReadOnlyList<DetectedApp> InstalledApps(string sid) => [new DetectedApp("steam.exe", "Steam")];
    public string? Describe(string? path) => path is null ? null : "Described " + path.Split('\\')[^1];
}

public sealed class MemoryStore : IStateStore
{
    public Dictionary<string, string> Saved { get; } = [];
    private readonly Dictionary<string, ChildState> _states = [];

    public IReadOnlyList<string> KnownSids() => _states.Where(kv => kv.Value.Account is not null).Select(kv => kv.Key).ToList();
    public ChildState Load(string sid) => _states.TryGetValue(sid, out var s) ? s : new ChildState();
    public void Save(string sid, ChildState state)
    {
        _states[sid] = state;
        Saved[sid] = System.Text.Json.JsonSerializer.Serialize(state);
    }
    public void Delete(string sid) => _states.Remove(sid);
}

/// <summary>An in-memory iCloud for one child: Mum's family and activity zones, shared with the child.</summary>
public sealed class FakeCloud : ICloudGatewayFactory, ICloudGateway
{
    public static readonly ZoneId Family = new("Family-c1", "_mum");
    public static readonly ZoneId Activity = new("Activity-c1", "_mum");

    public Dictionary<string, CloudRecord> FamilyRecords { get; } = [];
    public Dictionary<string, CloudRecord> ActivityRecords { get; } = [];
    public List<DeviceInfo> Devices { get; } = [];
    public bool Offline { get; set; }

    /// <summary>False: the child hasn't accepted the Activity share (or it was removed).</summary>
    public bool ActivityShared { get; set; } = true;

    /// <summary>Zones that spends and device heartbeats were written to.</summary>
    public List<ZoneId> WriteZones { get; } = [];
    public bool AuthExpired { get; set; }
    public string? ExpireTokenFor { get; set; }
    public string? RotateTokenTo { get; set; }
    public HashSet<string> ConflictSpends { get; } = [];
    public int FetchCalls { get; private set; }
    public List<string?> FetchTokens { get; } = [];
    public string? WebAuthToken { get; private set; }
    public string UserRecordName { get; set; } = "_child";

    public ICloudGateway Create(string webAuthToken)
    {
        WebAuthToken = webAuthToken;
        return this;
    }

    public Task<string> GetSignInUrlAsync(CancellationToken ct) => Task.FromResult("https://idmsa.apple.com/signin");

    public Task<ChildAccount> BindAsync(string sid, string webAuthToken, CancellationToken ct) => Task.FromResult(new ChildAccount
    {
        Sid = sid,
        WebAuthToken = webAuthToken,
        UserRecordName = UserRecordName,
        FamilyZoneName = Family.ZoneName,
        FamilyZoneOwner = Family.OwnerRecordName!,
        ChildId = "c1",
        ChildName = "Sam",
    });

    private void Check()
    {
        if (AuthExpired)
        {
            throw new CloudKitAuthenticationRequiredException("https://idmsa.apple.com/signin", "expired");
        }
        if (Offline)
        {
            throw new HttpRequestException("offline");
        }
    }

    private void CheckZone(ZoneId zone)
    {
        if (zone != Family && zone != Activity)
        {
            throw new InvalidOperationException("Unexpected zone " + zone);
        }
        if (zone == Activity && !ActivityShared)
        {
            throw new CloudKitException("ZONE_NOT_FOUND", "zone not found", System.Net.HttpStatusCode.OK);
        }
    }

    public Task<ZoneChanges> FetchChangesAsync(ZoneId zone, string? syncToken, CancellationToken ct)
    {
        Check();
        CheckZone(zone);
        FetchCalls++;
        FetchTokens.Add(syncToken);
        if (syncToken is not null && syncToken == ExpireTokenFor)
        {
            throw new CloudKitException("CHANGE_TOKEN_EXPIRED", "expired", System.Net.HttpStatusCode.OK);
        }
        var source = zone == Family ? FamilyRecords : ActivityRecords;
        if (RotateTokenTo is not null)
        {
            WebAuthToken = RotateTokenTo;
        }
        // Always return everything: idempotent for the cache.
        return Task.FromResult(new ZoneChanges(zone, source.Values.ToList(), "tok-" + FetchCalls));
    }

    public Task<IReadOnlyList<RecordResult>> SaveSpendsAsync(ZoneId activityZone, IReadOnlyList<SpendInfo> spends, CancellationToken ct)
    {
        Check();
        CheckZone(activityZone);
        WriteZones.Add(activityZone);
        var results = new List<RecordResult>();
        foreach (var s in spends)
        {
            if (ConflictSpends.Contains(s.RecordName))
            {
                results.Add(new RecordResult(s.RecordName, null, "CONFLICT", "exists"));
                continue;
            }
            ActivityRecords[s.RecordName] = ContractRecords.FromSpend(s);
            results.Add(new RecordResult(s.RecordName, null, null, null));
        }
        return Task.FromResult<IReadOnlyList<RecordResult>>(results);
    }

    public Task SaveDeviceAsync(ZoneId activityZone, DeviceInfo device, CancellationToken ct)
    {
        Check();
        CheckZone(activityZone);
        WriteZones.Add(activityZone);
        Devices.Add(device);
        return Task.CompletedTask;
    }

    public void AddEarn(string id, int minutes, DateTimeOffset at) =>
        ActivityRecords[id] = new CloudRecord(id, "Session")
            .Set("earnedMinutes", (long)minutes)
            .Set("startedAt", (DateTimeOffset?)at.AddMinutes(-30))
            .Set("endedAt", (DateTimeOffset?)at);

    public void SetRules(long debitLimit, string? allow = null)
    {
        FamilyRecords["rules"] = new CloudRecord("rules", "Rules").Set("debitLimit", debitLimit);
        FamilyRecords["child"] = new CloudRecord("child", "Child").Set("childId", "c1").Set("name", "Sam").Set("timeZone", "Europe/London");
        if (allow is not null)
        {
            FamilyRecords["allow-pc1"] = new CloudRecord("allow-pc1", "AllowList").Set("executables", allow);
        }
    }
}
