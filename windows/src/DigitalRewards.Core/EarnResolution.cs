namespace DigitalRewards.Core;

/// <summary>A completed workout as stored in the child's Activity zone.</summary>
/// <param name="Id">Session record name.</param>
/// <param name="EarnedMinutes">Base earned minutes computed on the watch.</param>
/// <param name="StartedAt">Epoch ms.</param>
/// <param name="EndedAt">Epoch ms.</param>
public sealed record SessionSummary(string Id, int EarnedMinutes, long StartedAt, long EndedAt);

/// <summary>A parent's replacement for a session's earned minutes (0 = void).</summary>
public sealed record SessionOverride(string SessionId, int EarnedMinutes);

/// <summary>A parent's earn multiplier for sessions started in [StartsAt, EndsAt).</summary>
public sealed record Bonus(double Multiplier, long StartsAt, long EndsAt);

/// <summary>Turns sessions into earn ledger entries (CONTRACT §3).</summary>
public static class EarnResolution
{
    public static double MultiplierAt(long startedAt, IEnumerable<Bonus> bonuses)
    {
        var m = 1.0;
        foreach (var b in bonuses)
        {
            if (b.StartsAt <= startedAt && startedAt < b.EndsAt && b.Multiplier > m)
            {
                m = b.Multiplier;
            }
        }
        return m;
    }

    public static int EarnMinutes(SessionSummary session, IEnumerable<SessionOverride> overrides, IEnumerable<Bonus> bonuses)
    {
        var o = overrides.FirstOrDefault(x => x.SessionId == session.Id);
        if (o is not null)
        {
            return o.EarnedMinutes;
        }
        var m = MultiplierAt(session.StartedAt, bonuses);
        return (int)Math.Round(session.EarnedMinutes * m, MidpointRounding.AwayFromZero);
    }

    public static LedgerEntry ToEntry(SessionSummary session, IEnumerable<SessionOverride> overrides, IEnumerable<Bonus> bonuses) =>
        new(session.Id, EntryKind.Earn, EarnMinutes(session, overrides, bonuses), session.EndedAt);

    public static List<LedgerEntry> ToEntries(IEnumerable<SessionSummary> sessions, IReadOnlyCollection<SessionOverride> overrides, IReadOnlyCollection<Bonus> bonuses) =>
        sessions.Select(s => ToEntry(s, overrides, bonuses)).ToList();
}
