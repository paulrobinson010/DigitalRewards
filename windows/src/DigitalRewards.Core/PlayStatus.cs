namespace DigitalRewards.Core;

public static class PlayReasons
{
    public const string OutsidePlayWindow = "outsidePlayWindow";
    public const string DailyCapReached = "dailyCapReached";
    public const string DebitLimitReached = "debitLimitReached";
}

public sealed record PlayStatus(int Balance, int TodayPlayed, int MinutesAvailable, bool CanPlay, string? Reason);

/// <summary>Play status (CONTRACT §4).</summary>
public static class PlayStatusCalculator
{
    private const long Unlimited = long.MaxValue;

    public static PlayStatus Compute(Rules rules, string timeZoneId, DateTimeOffset now, IReadOnlyCollection<LedgerEntry> entries) =>
        Compute(rules, TimeZones.Find(timeZoneId), now, entries);

    public static PlayStatus Compute(Rules rules, TimeZoneInfo zone, DateTimeOffset now, IReadOnlyCollection<LedgerEntry> entries)
    {
        var balance = LedgerFold.Balance(entries, rules.MaxBank);
        var local = TimeZoneInfo.ConvertTime(now, zone);
        var today = local.Date;

        // Count each spend id once, matching the fold's de-duplication.
        var todayPlayed = entries
            .Where(e => e.Kind == EntryKind.Spend)
            .DistinctBy(e => e.Id, StringComparer.Ordinal)
            .Where(e => TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(e.At), zone).Date == today)
            .Sum(e => e.Minutes);

        long fromBalance = (long)balance + rules.DebitLimit;
        long fromCap = rules.DailyPlayCap is { } cap ? cap - (long)todayPlayed : Unlimited;
        long fromWindow = WindowMinutes(rules.PlayWindows, local);

        var available = Math.Max(0, Math.Min(fromBalance, Math.Min(fromCap, fromWindow)));
        var canPlay = available > 0;
        string? reason = null;
        if (!canPlay)
        {
            reason = fromWindow <= 0 ? PlayReasons.OutsidePlayWindow
                : fromCap <= 0 ? PlayReasons.DailyCapReached
                : PlayReasons.DebitLimitReached;
        }
        return new PlayStatus(balance, todayPlayed, (int)Math.Min(available, int.MaxValue), canPlay, reason);
    }

    /// <summary>Minutes left in the current play window; unlimited when there are no windows; 0 outside all windows.</summary>
    public static long WindowMinutes(IReadOnlyList<PlayWindow>? windows, DateTimeOffset local)
    {
        if (windows is null || windows.Count == 0)
        {
            return Unlimited;
        }
        var weekday = local.DayOfWeek == DayOfWeek.Sunday ? 7 : (int)local.DayOfWeek;
        var nowTicks = local.TimeOfDay.Ticks;
        long best = 0;
        foreach (var w in windows)
        {
            if (!w.Days.Contains(weekday))
            {
                continue;
            }
            var startTicks = w.StartMinutes * TimeSpan.TicksPerMinute;
            var endTicks = w.EndMinutes * TimeSpan.TicksPerMinute;
            if (nowTicks < startTicks || nowTicks >= endTicks)
            {
                continue;
            }
            var remaining = endTicks - nowTicks;
            var minutes = (remaining + TimeSpan.TicksPerMinute - 1) / TimeSpan.TicksPerMinute;
            best = Math.Max(best, minutes);
        }
        return best;
    }
}
