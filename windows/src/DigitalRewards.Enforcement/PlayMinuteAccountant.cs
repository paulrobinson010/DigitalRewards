using DigitalRewards.CloudKit;

namespace DigitalRewards.Enforcement;

/// <summary>
/// Turns foreground reports into play minutes for one child on one PC.
/// Time spent with a non-allowed app in the foreground (and the user not idle) accumulates;
/// every 60 accumulated seconds produces one Spend for the current UTC minute.
/// If the agent stops reporting while the user session is active, that time counts as play.
/// </summary>
public sealed class PlayMinuteAccountant
{
    public const string AgentMissingApp = "(agent not reporting)";

    private readonly string _deviceId;
    private readonly AccountingOptions _options;
    private DateTimeOffset? _lastTick;
    private DateTimeOffset? _lastReportAt;
    private ForegroundReport? _lastReport;
    private DateTimeOffset _activeSince;
    private double _accumulatedSeconds;
    private readonly Dictionary<string, double> _secondsByApp = new(StringComparer.OrdinalIgnoreCase);
    private DateTimeOffset? _lastEmittedMinute;

    public PlayMinuteAccountant(string deviceId, AccountingOptions? options = null, DateTimeOffset? createdAt = null)
    {
        _deviceId = deviceId;
        _options = options ?? new AccountingOptions();
        _activeSince = createdAt ?? DateTimeOffset.MinValue;
    }

    public double AccumulatedSeconds => _accumulatedSeconds;

    public DateTimeOffset? LastReportAt => _lastReportAt;

    public void OnReport(DateTimeOffset at, ForegroundReport report)
    {
        _lastReportAt = at;
        _lastReport = report;
    }

    /// <summary>The app being played right now, or null if the current state is not play.</summary>
    public string? CurrentPlayApp(DateTimeOffset now, bool sessionActive, AllowPolicy policy)
    {
        if (!sessionActive)
        {
            return null;
        }
        if (_lastReportAt is { } at && now - at <= _options.ReportFreshness)
        {
            var fg = _lastReport?.Foreground;
            if (fg is null || _lastReport!.IdleSeconds >= _options.IdleThreshold.TotalSeconds || policy.IsAllowed(fg.Exe, fg.Path))
            {
                return null;
            }
            return AllowPolicy.Normalize(fg.Exe);
        }
        var silentSince = _lastReportAt ?? _activeSince;
        return now - silentSince > _options.AgentSilenceCountsAsPlay ? AgentMissingApp : null;
    }

    /// <summary>
    /// Call about once a second. Returns the Spend minutes completed since the last tick.
    /// </summary>
    public IReadOnlyList<SpendInfo> Tick(DateTimeOffset now, bool sessionActive, AllowPolicy policy)
    {
        if (!sessionActive)
        {
            // Session locked/disconnected: nothing counts, and silence starts again on return.
            _activeSince = now;
            _lastTick = now;
            return [];
        }
        var previous = _lastTick ?? now;
        _lastTick = now;
        var elapsed = (now - previous).TotalSeconds;
        if (elapsed <= 0 || elapsed > _options.MaxTickGap.TotalSeconds)
        {
            // First tick, clock went backwards, or the PC slept: don't count the gap.
            return [];
        }

        var app = CurrentPlayApp(now, sessionActive, policy);
        if (app is null)
        {
            return [];
        }
        _accumulatedSeconds += elapsed;
        _secondsByApp[app] = _secondsByApp.GetValueOrDefault(app) + elapsed;

        var spends = new List<SpendInfo>();
        while (_accumulatedSeconds >= 60)
        {
            _accumulatedSeconds -= 60;
            var minute = FloorToMinute(now);
            if (_lastEmittedMinute is { } last && minute <= last)
            {
                minute = last.AddMinutes(1);
            }
            _lastEmittedMinute = minute;
            var topApp = _secondsByApp.MaxBy(kv => kv.Value).Key;
            _secondsByApp.Clear();
            if (_accumulatedSeconds > 0)
            {
                _secondsByApp[app] = _accumulatedSeconds;
            }
            spends.Add(new SpendInfo(_deviceId, minute, 1, topApp));
        }
        return spends;
    }

    public static DateTimeOffset FloorToMinute(DateTimeOffset t)
    {
        var utc = t.ToUniversalTime();
        return new DateTimeOffset(utc.Year, utc.Month, utc.Day, utc.Hour, utc.Minute, 0, TimeSpan.Zero);
    }
}

public sealed class AccountingOptions
{
    /// <summary>A report older than this no longer describes the foreground.</summary>
    public TimeSpan ReportFreshness { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>No input for this long means the child walked away; the time doesn't count.</summary>
    public TimeSpan IdleThreshold { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>No reports for this long in an active session counts as play (tamper).</summary>
    public TimeSpan AgentSilenceCountsAsPlay { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>Gaps between ticks longer than this (sleep/hibernate) are ignored.</summary>
    public TimeSpan MaxTickGap { get; init; } = TimeSpan.FromSeconds(30);
}
