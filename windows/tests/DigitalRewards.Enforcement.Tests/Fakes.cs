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

/// <summary>An in-memory iCloud for one child: a family zone and an activity zone.</summary>
public sealed class FakeCloud : ICloudGatewayFactory, ICloudGateway
{
    public static readonly ZoneId Family = new("Family-c1", "_mum");

    public Dictionary<string, CloudRecord> FamilyRecords { get; } = [];
    public Dictionary<string, CloudRecord> ActivityRecords { get; } = [];
    public List<DeviceInfo> Devices { get; } = [];
    public bool Offline { get; set; }
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

    public Task<ZoneChanges> FetchChangesAsync(CloudDatabase database, ZoneId zone, string? syncToken, CancellationToken ct)
    {
        Check();
        FetchCalls++;
        FetchTokens.Add(syncToken);
        if (syncToken is not null && syncToken == ExpireTokenFor)
        {
            throw new CloudKitException("CHANGE_TOKEN_EXPIRED", "expired", System.Net.HttpStatusCode.OK);
        }
        var source = database == CloudDatabase.Shared ? FamilyRecords : ActivityRecords;
        if (RotateTokenTo is not null)
        {
            WebAuthToken = RotateTokenTo;
        }
        // Always return everything: idempotent for the cache.
        return Task.FromResult(new ZoneChanges(zone, source.Values.ToList(), "tok-" + FetchCalls));
    }

    public Task<IReadOnlyList<RecordResult>> SaveSpendsAsync(IReadOnlyList<SpendInfo> spends, CancellationToken ct)
    {
        Check();
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

    public Task SaveDeviceAsync(DeviceInfo device, CancellationToken ct)
    {
        Check();
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
