using DigitalRewards.CloudKit;
using DigitalRewards.Core;

namespace DigitalRewards.Enforcement.Tests;

public class AllowPolicyTests
{
    private readonly AllowPolicy _policy = new(["WinWord.exe"], @"C:\Windows");

    [Theory]
    [InlineData("explorer.exe", null, true)]
    [InlineData("EXPLORER.EXE", null, true)]
    [InlineData("winword.exe", @"C:\Program Files\Microsoft Office\WINWORD.EXE", true)]
    [InlineData("notepad.exe", @"C:\Windows\System32\notepad.exe", true)]
    [InlineData("notepad.exe", @"c:\windows\system32\notepad.exe", true)]
    [InlineData("minecraft.exe", @"C:\Games\Minecraft\minecraft.exe", false)]
    [InlineData("game.exe", @"C:\WindowsGames\game.exe", false)]
    [InlineData("digitalrewards.tray.exe", @"C:\Program Files\DigitalRewards\DigitalRewards.Tray.exe", true)]
    [InlineData(@"C:\Games\Roblox\RobloxPlayerBeta.exe", null, false)]
    public void Decides(string exe, string? path, bool allowed) => Assert.Equal(allowed, _policy.IsAllowed(exe, path));

    [Fact]
    public void NormalizesPaths() => Assert.Equal("game.exe", AllowPolicy.Normalize(@"C:\Games\GAME.exe"));
}

public class PlayMinuteAccountantTests
{
    private static readonly DateTimeOffset T0 = new(2026, 10, 28, 17, 0, 10, TimeSpan.Zero);
    private readonly AllowPolicy _policy = new(["winword.exe"], @"C:\Windows");

    private static ForegroundReport Fg(string exe, int idle = 0) =>
        new() { Foreground = new ProcessRef(42, exe, @"C:\Games\" + exe), IdleSeconds = idle };

    /// <summary>Simulates seconds of ticks, reporting every 2 s.</summary>
    private List<SpendInfo> Run(PlayMinuteAccountant a, ref DateTimeOffset now, int seconds, ForegroundReport? report, bool active = true)
    {
        var spends = new List<SpendInfo>();
        for (var i = 0; i < seconds; i++)
        {
            now = now.AddSeconds(1);
            if (report is not null && i % 2 == 0)
            {
                a.OnReport(now, report);
            }
            spends.AddRange(a.Tick(now, active, _policy));
        }
        return spends;
    }

    [Fact]
    public void SixtySecondsOfGameIsOneMinute()
    {
        var a = new PlayMinuteAccountant("pc1", createdAt: T0);
        var now = T0;
        a.Tick(now, true, _policy);
        var spends = Run(a, ref now, 59, Fg("minecraft.exe"));
        Assert.Empty(spends);
        spends = Run(a, ref now, 1, Fg("minecraft.exe"));
        var s = Assert.Single(spends);
        Assert.Equal("minecraft.exe", s.App);
        Assert.Equal(1, s.Minutes);
        Assert.Equal(new DateTimeOffset(2026, 10, 28, 17, 1, 0, TimeSpan.Zero), s.MinuteStart);
        Assert.Equal("spend-pc1-202610281701", s.RecordName);
    }

    [Fact]
    public void TenMinutesGiveTenDistinctSpends()
    {
        var a = new PlayMinuteAccountant("pc1", createdAt: T0);
        var now = T0;
        a.Tick(now, true, _policy);
        var spends = Run(a, ref now, 600, Fg("game.exe"));
        Assert.Equal(10, spends.Count);
        Assert.Equal(10, spends.Select(s => s.RecordName).Distinct().Count());
    }

    [Fact]
    public void AllowedAppsAndIdleDontCount()
    {
        var a = new PlayMinuteAccountant("pc1", createdAt: T0);
        var now = T0;
        a.Tick(now, true, _policy);
        Assert.Empty(Run(a, ref now, 120, Fg("winword.exe")));
        Assert.Empty(Run(a, ref now, 120, Fg("game.exe", idle: 600)));
        Assert.Empty(Run(a, ref now, 120, new ForegroundReport { Foreground = null }));
        Assert.Equal(0, a.AccumulatedSeconds);
    }

    [Fact]
    public void PartialMinutesCarryOver()
    {
        var a = new PlayMinuteAccountant("pc1", createdAt: T0);
        var now = T0;
        a.Tick(now, true, _policy);
        Assert.Empty(Run(a, ref now, 40, Fg("game.exe")));
        Assert.Empty(Run(a, ref now, 30, Fg("winword.exe")));
        Assert.Single(Run(a, ref now, 20, Fg("game.exe")));
    }

    [Fact]
    public void TopAppWinsTheMinute()
    {
        var a = new PlayMinuteAccountant("pc1", createdAt: T0);
        var now = T0;
        a.Tick(now, true, _policy);
        Run(a, ref now, 20, Fg("a.exe"));
        var s = Run(a, ref now, 40, Fg("b.exe"));
        Assert.Equal("b.exe", Assert.Single(s).App);
    }

    [Fact]
    public void SilentAgentCountsAsPlayAfterSixtySeconds()
    {
        var a = new PlayMinuteAccountant("pc1", createdAt: T0);
        var now = T0;
        a.Tick(now, true, _policy);
        Run(a, ref now, 10, Fg("winword.exe"));
        // Agent killed: no more reports. 10 s fresh + 60 s grace, then it counts.
        var spends = Run(a, ref now, 69, report: null);
        Assert.Empty(spends);
        spends = Run(a, ref now, 61, report: null);
        Assert.Equal(PlayMinuteAccountant.AgentMissingApp, Assert.Single(spends).App);
    }

    [Fact]
    public void InactiveSessionCountsNothingAndResetsSilence()
    {
        var a = new PlayMinuteAccountant("pc1", createdAt: T0);
        var now = T0;
        Assert.Empty(Run(a, ref now, 300, report: null, active: false));
        Assert.Empty(Run(a, ref now, 59, report: null));
    }

    [Fact]
    public void SleepGapIsIgnored()
    {
        var a = new PlayMinuteAccountant("pc1", createdAt: T0);
        var now = T0;
        a.Tick(now, true, _policy);
        Run(a, ref now, 30, Fg("game.exe"));
        now = now.AddHours(2);
        a.OnReport(now, Fg("game.exe"));
        Assert.Empty(a.Tick(now, true, _policy));
        Assert.Equal(30, a.AccumulatedSeconds, precision: 3);
    }
}

public class EnforcementDeciderTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 28, 17, 0, 0, TimeSpan.Zero);
    private static readonly TimeSpan Limit = TimeSpan.FromHours(24);
    private static readonly PlayStatus Ok = new(10, 0, 70, true, null);

    [Fact]
    public void AllowsWhenStatusSaysPlay() => Assert.False(EnforcementDecider.Decide(Ok, Now.AddMinutes(-1), Now, Limit).Blocked);

    [Fact]
    public void BlocksWithStatusReason()
    {
        var d = EnforcementDecider.Decide(new PlayStatus(-60, 0, 0, false, PlayReasons.DebitLimitReached), Now, Now, Limit);
        Assert.Equal(new BlockDecision(true, PlayReasons.DebitLimitReached), d);
    }

    [Fact]
    public void BlocksAfterOfflineLimit()
    {
        Assert.False(EnforcementDecider.Decide(Ok, Now.AddHours(-23.9), Now, Limit).Blocked);
        Assert.Equal(BlockDecision.Offline, EnforcementDecider.Decide(Ok, Now.AddHours(-24.1), Now, Limit).Reason);
    }

    [Fact]
    public void BlocksWhenNeverSynced() =>
        Assert.Equal(BlockDecision.NeverSynced, EnforcementDecider.Decide(null, null, Now, Limit).Reason);

    [Fact]
    public void KillsOnlyNonAllowedWhenBlocked()
    {
        var policy = new AllowPolicy(["chrome.exe"], @"C:\Windows");
        var procs = new[]
        {
            new ProcessRef(1, "explorer.exe", @"C:\Windows\explorer.exe"),
            new ProcessRef(2, "chrome.exe", @"C:\Program Files\Google\chrome.exe"),
            new ProcessRef(3, "game.exe", @"C:\Games\game.exe"),
            new ProcessRef(4, "steam.exe", @"C:\Program Files (x86)\Steam\steam.exe"),
        };
        Assert.Equal([3, 4], EnforcementDecider.ProcessesToKill(new BlockDecision(true, "x"), procs, policy).Select(p => p.Pid));
        Assert.Empty(EnforcementDecider.ProcessesToKill(BlockDecision.Allow, procs, policy));
    }
}

public class WarningTrackerTests
{
    [Fact]
    public void WarnsOncePerThresholdThenTimeUp()
    {
        var w = new WarningTracker();
        var seen = new List<Warning>();
        foreach (var m in new[] { 15, 11, 10, 10, 9, 6, 5, 4, 2, 1, 1 })
        {
            seen.Add(w.Update(m, blocked: false, playing: true));
        }
        seen.Add(w.Update(0, blocked: true, playing: true));
        seen.Add(w.Update(0, blocked: true, playing: true));

        Assert.Equal(
            [new Warning(WarningKind.MinutesLeft, 10), new Warning(WarningKind.MinutesLeft, 5), new Warning(WarningKind.MinutesLeft, 1), new Warning(WarningKind.TimeUp)],
            seen.Where(x => x.Kind != WarningKind.None));
    }

    [Fact]
    public void TimeUpShowsWhenGameWasClosedBeforeTheReport()
    {
        var w = new WarningTracker();
        w.Update(1, blocked: false, playing: true);
        Assert.Equal(WarningKind.TimeUp, w.Update(0, blocked: true, playing: false).Kind);
    }

    [Fact]
    public void JumpingBelowSeveralThresholdsWarnsOnce()
    {
        var w = new WarningTracker();
        Assert.Equal(new Warning(WarningKind.MinutesLeft, 3), w.Update(3, false, true));
        Assert.Equal(WarningKind.None, w.Update(2, false, true).Kind);
        Assert.Equal(new Warning(WarningKind.MinutesLeft, 1), w.Update(1, false, true));
    }

    [Fact]
    public void RearmsAfterEarningAndStaysQuietWhenNotPlaying()
    {
        var w = new WarningTracker();
        Assert.Equal(WarningKind.None, w.Update(4, false, playing: false).Kind);
        Assert.Equal(WarningKind.MinutesLeft, w.Update(4, false, true).Kind);
        Assert.Equal(WarningKind.None, w.Update(4, false, true).Kind);
        w.Update(100, false, true);
        Assert.Equal(WarningKind.MinutesLeft, w.Update(9, false, true).Kind);
        w.Update(9, false, playing: false);
        Assert.Equal(WarningKind.None, w.Update(0, true, playing: false).Kind);
        Assert.Equal(WarningKind.TimeUp, w.Update(0, true, playing: true).Kind);
    }
}

public class ChildSyncTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 28, 17, 0, 0, TimeSpan.Zero);

    private static ChildAccount Account() => new()
    {
        Sid = "S-1", WebAuthToken = "t", UserRecordName = "_child", FamilyZoneName = "Family-c1", FamilyZoneOwner = "_mum",
    };

    private static SyncInput Input(IReadOnlyList<SpendInfo>? pending = null, string? familyToken = null, bool heartbeat = false) =>
        new(Account(), familyToken, null, pending ?? [], heartbeat, new DeviceInfo("pc1", "windows", "PC", Now, []));

    [Fact]
    public async Task PullsBothZonesAndConfirmsSpends()
    {
        var cloud = new FakeCloud();
        cloud.SetRules(debitLimit: 10);
        var spends = new[] { new SpendInfo("pc1", Now, 1, "game.exe"), new SpendInfo("pc1", Now.AddMinutes(1), 1, "game.exe") };
        cloud.ConflictSpends.Add(spends[1].RecordName);

        var outcome = await ChildSync.RunAsync(cloud, Input(spends, heartbeat: true), Now, default);

        Assert.True(outcome.Succeeded);
        Assert.Equal(2, outcome.Family!.Records.Count);
        Assert.Equal(spends.Select(s => s.RecordName), outcome.ConfirmedSpends);
        Assert.Single(cloud.Devices);

        var state = new ChildState { Account = Account(), PendingSpends = spends.ToList() };
        outcome.ApplyTo(state);
        Assert.Empty(state.PendingSpends);
        Assert.Equal(Now, state.LastSyncAt);
        Assert.Equal(Now, state.LastHeartbeatAt);
        Assert.Equal(2, state.FamilyRecords.Count);
    }

    [Fact]
    public async Task ExpiredSyncTokenRefetchesFromScratch()
    {
        var cloud = new FakeCloud { ExpireTokenFor = "stale" };
        var outcome = await ChildSync.RunAsync(cloud, Input(familyToken: "stale"), Now, default);
        Assert.True(outcome.Succeeded);
        Assert.True(outcome.ResetFamily);
        Assert.Equal(["stale", null, null], cloud.FetchTokens);
    }

    [Fact]
    public async Task AuthFailureFlagsSignIn()
    {
        var cloud = new FakeCloud { AuthExpired = true };
        var outcome = await ChildSync.RunAsync(cloud, Input(), Now, default);
        var state = new ChildState { Account = Account() };
        outcome.ApplyTo(state);
        Assert.False(outcome.Succeeded);
        Assert.True(state.Account!.NeedsSignIn);
        Assert.Null(state.LastSyncAt);
    }

    [Fact]
    public async Task OfflineKeepsPendingAndLastSync()
    {
        var cloud = new FakeCloud { Offline = true };
        var spend = new SpendInfo("pc1", Now, 1, "g.exe");
        var outcome = await ChildSync.RunAsync(cloud, Input([spend]), Now, default);
        var state = new ChildState { Account = Account(), PendingSpends = [spend], LastSyncAt = Now.AddHours(-1) };
        outcome.ApplyTo(state);
        Assert.NotNull(outcome.Error);
        Assert.Single(state.PendingSpends);
        Assert.Equal(Now.AddHours(-1), state.LastSyncAt);
    }

    [Fact]
    public async Task RotatedTokenIsKept()
    {
        var cloud = new FakeCloud { RotateTokenTo = "t2" };
        var outcome = await ChildSync.RunAsync(cloud, Input(), Now, default);
        var state = new ChildState { Account = Account() };
        outcome.ApplyTo(state);
        Assert.Equal("t2", state.Account!.WebAuthToken);
    }
}

public class FileStateStoreTests
{
    [Fact]
    public void RoundTripsState()
    {
        var dir = Path.Combine(Path.GetTempPath(), "dr-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new FileStateStore(dir, new NoProtection());
            var state = new ChildState
            {
                Account = new ChildAccount { Sid = "S-1-5-21-1", WebAuthToken = "t", UserRecordName = "_c", FamilyZoneName = "Family-x", FamilyZoneOwner = "_m" },
                PendingSpends = [new SpendInfo("pc1", new DateTimeOffset(2026, 10, 28, 17, 0, 0, TimeSpan.Zero), 1, "game.exe")],
                LastSyncAt = DateTimeOffset.UnixEpoch,
            };
            state.ApplyChanges(state.FamilyRecords, [new CloudRecord("rules", "Rules").Set("ratio", 12L)]);
            store.Save("S-1-5-21-1", state);

            var back = store.Load("S-1-5-21-1");

            Assert.Equal(state.Account, back.Account);
            Assert.Equal(state.PendingSpends, back.PendingSpends);
            Assert.Equal(12, back.Snapshot("pc1").Rules.Ratio);
            Assert.Equal(["S-1-5-21-1"], store.KnownSids());
            Assert.Null(new FileStateStore(dir, new NoProtection()).Load("S-1-5-21-2").Account);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
