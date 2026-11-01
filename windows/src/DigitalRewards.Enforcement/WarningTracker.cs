namespace DigitalRewards.Enforcement;

public enum WarningKind
{
    None,
    MinutesLeft,
    TimeUp,
}

public sealed record Warning(WarningKind Kind, int Minutes = 0);

/// <summary>
/// Shows each "N minutes left" warning (10, 5, 1) once per run-down, and "time's up" once per block.
/// Warnings re-arm when the time available rises above the threshold again (e.g. after earning).
/// Only warns while the child is actually playing. After a "time's up" it stays quiet for
/// <see cref="TimeUpCooldown"/>, so a balance that flickers around the limit (or a game the
/// child keeps relaunching) doesn't keep popping the notice up.
/// </summary>
public sealed class WarningTracker
{
    public static readonly int[] DefaultThresholds = [10, 5, 1];
    public static readonly TimeSpan TimeUpCooldown = TimeSpan.FromMinutes(15);

    private readonly int[] _thresholds;
    private readonly TimeProvider _clock;
    private DateTimeOffset? _lastTimeUpAt;
    private readonly HashSet<int> _shown = [];
    private bool _timeUpShown;
    private bool _wasPlaying;

    public WarningTracker(IEnumerable<int>? thresholds = null, TimeProvider? clock = null)
    {
        _thresholds = (thresholds ?? DefaultThresholds).OrderBy(t => t).ToArray();
        _clock = clock ?? TimeProvider.System;
    }

    public Warning Update(int minutesAvailable, bool blocked, bool playing)
    {
        // The game may already be closed by the time the agent hears about the block.
        var playingNowOrJustBefore = playing || _wasPlaying;
        _wasPlaying = playing;
        foreach (var t in _thresholds)
        {
            if (minutesAvailable > t)
            {
                _shown.Remove(t);
            }
        }
        if (!blocked)
        {
            _timeUpShown = false;
        }
        if (blocked)
        {
            if (!_timeUpShown && playingNowOrJustBefore)
            {
                _timeUpShown = true;
                var now = _clock.GetUtcNow();
                if (_lastTimeUpAt is { } last && now - last < TimeUpCooldown)
                {
                    return new Warning(WarningKind.None);
                }
                _lastTimeUpAt = now;
                return new Warning(WarningKind.TimeUp);
            }
            return new Warning(WarningKind.None);
        }
        if (!playing)
        {
            return new Warning(WarningKind.None);
        }
        // Smallest threshold reached that hasn't been shown yet; mark larger ones as shown too.
        var due = _thresholds.Where(t => minutesAvailable <= t && !_shown.Contains(t)).ToList();
        if (due.Count == 0)
        {
            return new Warning(WarningKind.None);
        }
        foreach (var t in _thresholds.Where(t => minutesAvailable <= t))
        {
            _shown.Add(t);
        }
        return new Warning(WarningKind.MinutesLeft, minutesAvailable);
    }
}
