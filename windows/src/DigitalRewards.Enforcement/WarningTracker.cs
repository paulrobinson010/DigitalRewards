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
/// Only warns while the child is actually playing.
/// </summary>
public sealed class WarningTracker
{
    public static readonly int[] DefaultThresholds = [10, 5, 1];

    private readonly int[] _thresholds;
    private readonly HashSet<int> _shown = [];
    private bool _timeUpShown;
    private bool _wasPlaying;

    public WarningTracker(IEnumerable<int>? thresholds = null)
    {
        _thresholds = (thresholds ?? DefaultThresholds).OrderBy(t => t).ToArray();
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
