using DigitalRewards.CloudKit;
using DigitalRewards.Core;

namespace DigitalRewards.Enforcement.Tests;

public class EnforcerTests
{
    private const string Sid = "S-1-5-21-1001";
    private static readonly DateTimeOffset T0 = new(2026, 10, 28, 17, 0, 10, TimeSpan.Zero);

    private readonly ManualClock _clock = new(T0);
    private readonly FakeSessions _sessions = new();
    private readonly FakeProcesses _processes = new();
    private readonly FakeLauncher _launcher = new();
    private readonly FakeCloud _cloud = new();
    private readonly MemoryStore _store = new();
    private readonly Enforcer _enforcer;
    private readonly AgentClient _client = new(Sid, 2);

    public EnforcerTests()
    {
        _sessions.List.Add(new UserSession(2, Sid, @"PC\sam", Active: true));
        _enforcer = new Enforcer(_store, _cloud, _sessions, _processes, _launcher, new FakeApps(),
            new EnforcerOptions { DeviceId = "pc1", DeviceName = "Family PC", SystemRoot = @"C:\Windows" }, _clock);
    }

    private async Task SignInAsync()
    {
        var r = await _enforcer.HandleAsync(_client, new AgentRequest { Type = AgentRequestType.CompleteSignIn, Token = "web-token" }, default);
        Assert.True(r.Ok, r.Error);
    }

    private Task<AgentResponse> ReportAsync(string? exe) => _enforcer.HandleAsync(_client, new AgentRequest
    {
        Type = AgentRequestType.Report,
        Report = new ForegroundReport { Foreground = exe is null ? null : new ProcessRef(77, exe, @"C:\Games\" + exe) },
    }, default);

    private async Task PlayAsync(string exe, int seconds)
    {
        for (var i = 0; i < seconds; i++)
        {
            _clock.Advance(TimeSpan.FromSeconds(1));
            if (i % 2 == 0)
            {
                await ReportAsync(exe);
            }
            _enforcer.Tick();
        }
    }

    [Fact]
    public async Task UnboundAccountIsNotEnforcedButAgentStarts()
    {
        _processes.BySession[2] = [new ProcessRef(77, "game.exe", @"C:\Games\game.exe")];
        _enforcer.Tick();
        Assert.Equal([2], _launcher.Launched);
        Assert.Empty(_processes.Killed);
        var status = (await ReportAsync("game.exe")).Status!;
        Assert.False(status.SignedIn);
    }

    [Fact]
    public async Task BeginSignInReturnsAppleUrl()
    {
        var r = await _enforcer.HandleAsync(_client, new AgentRequest { Type = AgentRequestType.BeginSignIn }, default);
        Assert.Equal("https://idmsa.apple.com/signin", r.SignInUrl);
    }

    [Fact]
    public async Task SignInSyncsAndShowsBalance()
    {
        _cloud.SetRules(debitLimit: 0);
        _cloud.AddEarn("session-1", 30, T0.AddHours(-1));

        await SignInAsync();

        var s = _enforcer.StatusOf(Sid);
        Assert.True(s.SignedIn);
        Assert.Equal("Sam", s.ChildName);
        Assert.Equal(30, s.Balance);
        Assert.Equal(30, s.MinutesAvailable);
        Assert.False(s.Blocked);
        Assert.Single(_cloud.Devices);
        Assert.Contains(_cloud.Devices[0].DetectedApps!, a => a.Exe == "steam.exe");
    }

    [Fact]
    public async Task PlayingSpendsMinutesThenBlocksAndClosesGames()
    {
        _cloud.SetRules(debitLimit: 0);
        _cloud.AddEarn("session-1", 2, T0.AddHours(-1));
        await SignInAsync();
        _launcher.Running.Add(2);
        _processes.BySession[2] =
        [
            new ProcessRef(10, "explorer.exe", @"C:\Windows\explorer.exe"),
            new ProcessRef(77, "game.exe", @"C:\Games\game.exe"),
        ];

        Assert.True((await ReportAsync("game.exe")).Status!.Playing);
        await PlayAsync("game.exe", 61);
        Assert.Single(_enforcer.PendingSpendsOf(Sid));
        Assert.Equal(1, _enforcer.StatusOf(Sid).MinutesAvailable);
        Assert.Empty(_processes.Killed);

        await PlayAsync("game.exe", 60);
        var status = _enforcer.StatusOf(Sid);
        Assert.True(status.Blocked);
        Assert.Equal(PlayReasons.DebitLimitReached, status.BlockReason);
        Assert.Equal([77], _processes.Killed);
        Assert.Equal("Described game.exe", status.LastClosedApp);

        // Sync uploads the spends and the balance agrees.
        await _enforcer.SyncOneAsync(Sid, default);
        Assert.Empty(_enforcer.PendingSpendsOf(Sid));
        Assert.Equal(2, _cloud.ActivityRecords.Values.Count(r => r.RecordType == "Spend"));
        Assert.Equal(0, _enforcer.StatusOf(Sid).Balance);

        // Earning more unblocks.
        _cloud.AddEarn("session-2", 10, T0);
        await _enforcer.SyncOneAsync(Sid, default);
        _enforcer.Tick();
        Assert.False(_enforcer.StatusOf(Sid).Blocked);
    }

    [Fact]
    public async Task AllowListFromParentIsRespected()
    {
        _cloud.SetRules(debitLimit: 0, allow: """["homework.exe"]""");
        await SignInAsync();
        _launcher.Running.Add(2);
        _processes.BySession[2] = [new ProcessRef(5, "homework.exe", @"C:\Apps\homework.exe"), new ProcessRef(6, "game.exe", @"C:\Games\game.exe")];

        await PlayAsync("homework.exe", 120);
        _enforcer.Tick();

        Assert.Empty(_enforcer.PendingSpendsOf(Sid));
        Assert.True(_enforcer.StatusOf(Sid).Blocked);   // zero balance, no debit
        Assert.Equal([6], _processes.Killed);
    }

    [Fact]
    public async Task BlocksAfterTwentyFourHoursOffline()
    {
        _cloud.SetRules(debitLimit: 60);
        _cloud.AddEarn("session-1", 500, T0.AddHours(-1));
        await SignInAsync();
        _launcher.Running.Add(2);
        _cloud.Offline = true;

        _clock.Advance(TimeSpan.FromHours(23));
        await _enforcer.SyncOneAsync(Sid, default);
        _enforcer.Tick();
        Assert.False(_enforcer.StatusOf(Sid).Blocked);

        _clock.Advance(TimeSpan.FromHours(1.5));
        _enforcer.Tick();
        Assert.Equal(BlockDecision.Offline, _enforcer.StatusOf(Sid).BlockReason);

        _cloud.Offline = false;
        await _enforcer.SyncOneAsync(Sid, default);
        Assert.False(_enforcer.StatusOf(Sid).Blocked);
    }

    [Fact]
    public async Task ExpiredTokenAsksForSignInButKeepsEnforcing()
    {
        _cloud.SetRules(debitLimit: 0);
        await SignInAsync();
        _cloud.AuthExpired = true;
        await _enforcer.SyncOneAsync(Sid, default);
        var s = _enforcer.StatusOf(Sid);
        Assert.False(s.SignedIn);
        Assert.True(s.Blocked);
    }

    [Fact]
    public async Task RelaunchesSilentAgentWithBackoff()
    {
        _cloud.SetRules(debitLimit: 0);
        await SignInAsync();
        _launcher.Running.Add(2);
        await ReportAsync("explorer.exe");
        _enforcer.Tick();
        Assert.Empty(_launcher.Launched);

        _clock.Advance(TimeSpan.FromSeconds(25));
        _enforcer.Tick();
        Assert.Equal([2], _launcher.Launched);

        _clock.Advance(TimeSpan.FromSeconds(5));
        _enforcer.Tick();
        Assert.Single(_launcher.Launched);

        _clock.Advance(TimeSpan.FromSeconds(30));
        _enforcer.Tick();
        Assert.Equal(2, _launcher.Launched.Count);
    }

    [Fact]
    public async Task SignInAsDifferentChildResetsCache()
    {
        _cloud.SetRules(debitLimit: 0);
        _cloud.AddEarn("session-1", 30, T0.AddHours(-1));
        await SignInAsync();
        Assert.Equal(30, _enforcer.StatusOf(Sid).Balance);

        _cloud.ActivityRecords.Clear();
        _cloud.UserRecordName = "_sibling";
        await SignInAsync();
        Assert.Equal(0, _enforcer.StatusOf(Sid).Balance);
    }

    [Fact]
    public async Task SpendsAndHeartbeatsGoToTheParentOwnedActivityZone()
    {
        _cloud.SetRules(debitLimit: 60);
        await SignInAsync();
        await PlayAsync("game.exe", 61);
        await _enforcer.SyncOneAsync(Sid, default);

        Assert.NotEmpty(_cloud.WriteZones);
        Assert.All(_cloud.WriteZones, z => Assert.Equal(new ZoneId("Activity-c1", "_mum"), z));
        Assert.Contains(_cloud.ActivityRecords.Values, r => r.RecordType == "Spend");
    }

    [Fact]
    public async Task MissingActivityShareShowsSetupNeededUntilAccepted()
    {
        _cloud.SetRules(debitLimit: 60);
        _cloud.ActivityShared = false;
        await SignInAsync();

        var status = _enforcer.StatusOf(Sid);
        Assert.True(status.SignedIn);
        Assert.True(status.SetupNeeded);
        Assert.True(status.Blocked); // never synced

        _cloud.ActivityShared = true;
        _clock.Advance(TimeSpan.FromMinutes(1));
        await _enforcer.SyncOneAsync(Sid, default);
        status = _enforcer.StatusOf(Sid);
        Assert.False(status.SetupNeeded);
        Assert.False(status.Blocked);
    }

    [Fact]
    public void OldPrivateZoneCacheIsDroppedOnLoad()
    {
        var old = new ChildState
        {
            Layout = 0,
            Account = new ChildAccount
            {
                Sid = Sid, WebAuthToken = "t", UserRecordName = "_child",
                FamilyZoneName = "Family-c1", FamilyZoneOwner = "_mum",
            },
            ActivitySyncToken = "private-token",
            LastSyncAt = T0,
            PendingSpends = [new SpendInfo("pc1", T0.AddHours(-1), 1, "game.exe")],
        };
        old.ActivityRecords["session-old"] = new System.Text.Json.Nodes.JsonObject { ["recordName"] = "session-old" };

        Assert.True(old.Migrate());
        Assert.Equal(ChildState.CurrentLayout, old.Layout);
        Assert.Null(old.ActivitySyncToken);
        Assert.Empty(old.ActivityRecords);
        Assert.Null(old.LastSyncAt);
        Assert.Single(old.PendingSpends);
        Assert.Equal(new ZoneId("Activity-c1", "_mum"), old.Account!.ActivityZone);
        Assert.False(old.Migrate());
    }

    [Fact]
    public async Task MigratedStateIsSavedWhenLoaded()
    {
        var old = new ChildState
        {
            Account = new ChildAccount
            {
                Sid = Sid, WebAuthToken = "t", UserRecordName = "_child",
                FamilyZoneName = "Family-c1", FamilyZoneOwner = "_mum",
            },
            ActivitySyncToken = "private-token",
        };
        _store.Save(Sid, old);
        _store.Saved.Remove(Sid);

        _cloud.SetRules(debitLimit: 60);
        _cloud.AddEarn("session-1", 30, T0.AddHours(-1));
        await _enforcer.SyncOneAsync(Sid, default);

        Assert.True(_store.Saved.ContainsKey(Sid));
        Assert.Equal(30, _enforcer.StatusOf(Sid).Balance);
        Assert.Equal(new ZoneId("Activity-c1", "_mum"), _cloud.WriteZones.Last());
    }
}
