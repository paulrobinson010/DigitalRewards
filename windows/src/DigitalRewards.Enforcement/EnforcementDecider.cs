using DigitalRewards.Core;

namespace DigitalRewards.Enforcement;

public sealed record BlockDecision(bool Blocked, string? Reason)
{
    public const string Offline = "offline";
    public const string NeverSynced = "neverSynced";

    public static BlockDecision Allow { get; } = new(false, null);
}

public static class EnforcementDecider
{
    /// <summary>
    /// Blocked when play status says no, or when the PC hasn't synced for longer than <paramref name="offlineLimit"/>.
    /// </summary>
    public static BlockDecision Decide(PlayStatus? status, DateTimeOffset? lastSyncAt, DateTimeOffset now, TimeSpan offlineLimit)
    {
        if (lastSyncAt is null || status is null)
        {
            return new BlockDecision(true, BlockDecision.NeverSynced);
        }
        if (now - lastSyncAt.Value > offlineLimit)
        {
            return new BlockDecision(true, BlockDecision.Offline);
        }
        return status.CanPlay ? BlockDecision.Allow : new BlockDecision(true, status.Reason);
    }

    /// <summary>Processes to close in a blocked session: everything that isn't allowed.</summary>
    public static IReadOnlyList<ProcessRef> ProcessesToKill(BlockDecision decision, IEnumerable<ProcessRef> sessionProcesses, AllowPolicy policy)
    {
        if (!decision.Blocked)
        {
            return [];
        }
        return sessionProcesses.Where(p => !policy.IsAllowed(p.Exe, p.Path)).ToList();
    }
}
