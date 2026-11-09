using DigitalRewards.Enforcement;

namespace DigitalRewards.Enforcement.Tests;

public class StoreAppTests
{
    private const string Disney = "Disney.37853FC22B2CE_6rarf9sa4v8jt";
    private static readonly ProcessRef DisneyHost =
        new(50, "WWAHost.exe", @"C:\Windows\System32\WWAHost.exe", Disney, "Disney+");

    [Fact]
    public void StoreAppInsideWindowsHostIsNotTreatedAsWindows()
    {
        var policy = new AllowPolicy([], @"C:\Windows");
        Assert.True(policy.IsAllowed(DisneyHost.Exe, DisneyHost.Path)); // the old, exe-only view
        Assert.False(policy.IsAllowed(DisneyHost));
    }

    [Fact]
    public void ParentCanAllowAStoreAppByPackage()
    {
        var policy = new AllowPolicy([Disney.ToLowerInvariant()], @"C:\Windows");
        Assert.True(policy.IsAllowed(DisneyHost));
    }

    [Theory]
    [InlineData("windows.immersivecontrolpanel_cw5n1h2txyewy", true)]                // Settings
    [InlineData("Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy", true)]    // Start
    [InlineData("MicrosoftWindows.Client.CBS_cw5n1h2txyewy", true)]                  // Search
    [InlineData("Microsoft.WindowsStore_8wekyb3d8bbwe", false)]                       // the Store itself
    [InlineData("Microsoft.MinecraftUWP_8wekyb3d8bbwe", false)]
    public void WindowsOwnPackagesAreAllowed(string package, bool allowed)
    {
        var policy = new AllowPolicy([], @"C:\Windows");
        Assert.Equal(allowed, policy.IsAllowed(new ProcessRef(1, "app.exe", @"C:\Program Files\WindowsApps\x\app.exe", package)));
    }

    [Fact]
    public void StoreAppCountsAsPlayAndIsNamedByItsTitle()
    {
        var policy = new AllowPolicy([], @"C:\Windows");
        var start = new DateTimeOffset(2026, 11, 9, 18, 0, 0, TimeSpan.Zero);
        var accountant = new PlayMinuteAccountant("pc", createdAt: start);
        var spends = new List<CloudKit.SpendInfo>();
        accountant.Tick(start, true, policy);
        for (var s = 1; s <= 61; s++)
        {
            var now = start.AddSeconds(s);
            accountant.OnReport(now, new ForegroundReport { Foreground = DisneyHost, IdleSeconds = 0 });
            spends.AddRange(accountant.Tick(now, true, policy));
        }
        Assert.Equal("Disney+", Assert.Single(spends).App);
    }

    [Fact]
    public void StoreAppIsClosedWhenTimeIsUp()
    {
        var policy = new AllowPolicy([], @"C:\Windows");
        var procs = new[]
        {
            new ProcessRef(1, "explorer.exe", @"C:\Windows\explorer.exe"),
            DisneyHost,
            new ProcessRef(3, "StartMenuExperienceHost.exe", @"C:\Windows\SystemApps\x\StartMenuExperienceHost.exe",
                           "Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy"),
        };
        Assert.Equal([50], EnforcementDecider.ProcessesToKill(new BlockDecision(true, "x"), procs, policy).Select(p => p.Pid));
    }

    [Fact]
    public void DisplayNameFallsBackToPackageName()
    {
        Assert.Equal("Disney.37853FC22B2CE", (DisneyHost with { Title = null }).DisplayName);
        Assert.Equal(Disney.ToLowerInvariant(), DisneyHost.AppKey);
        Assert.Equal("game.exe", new ProcessRef(1, "Game.EXE", null).AppKey);
    }
}
