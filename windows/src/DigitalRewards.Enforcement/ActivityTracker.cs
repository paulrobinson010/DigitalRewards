namespace DigitalRewards.Enforcement;

/// <summary>
/// Decides when the child last really used the PC, from raw input events. Unlike Windows' own
/// "last input" time it ignores mouse jitter (a few pixels of drift from a sensitive mouse keeps
/// Windows awake all night), counts game controller use (which Windows ignores), and treats a
/// turned-off display as idle. Thread-safe: hooks and polling call in on the UI thread, and the
/// report is read on a worker thread.
/// </summary>
public sealed class ActivityTracker
{
    /// <summary>The pointer has to move at least this far within <see cref="MouseMoveWindow"/> to count.</summary>
    public const int MouseMoveThresholdPx = 24;
    public static readonly TimeSpan MouseMoveWindow = TimeSpan.FromSeconds(2);

    /// <summary>Stick change (of ±32767) between polls that counts as use; smaller changes are drift.</summary>
    public const int StickChangeThreshold = 3000;
    /// <summary>Trigger change (of 0–255) between polls that counts as use.</summary>
    public const int TriggerChangeThreshold = 30;

    /// <summary>Reported while the display is off: comfortably past any idle threshold.</summary>
    public const int DisplayOffIdleSeconds = 24 * 60 * 60;

    private readonly object _gate = new();
    private DateTimeOffset _lastActive;
    private (int X, int Y)? _anchor;
    private DateTimeOffset _anchorAt;
    private bool _displayOff;
    private readonly Dictionary<int, GamepadState> _pads = [];

    public ActivityTracker(DateTimeOffset start)
    {
        _lastActive = start;
    }

    public void KeyDown(DateTimeOffset at) => Mark(at);

    public void MouseButtonOrWheel(DateTimeOffset at) => Mark(at);

    public void MouseMove(DateTimeOffset at, int x, int y)
    {
        lock (_gate)
        {
            if (_anchor is not { } a || at - _anchorAt > MouseMoveWindow)
            {
                _anchor = (x, y);
                _anchorAt = at;
                return;
            }
            var dx = x - a.X;
            var dy = y - a.Y;
            if (dx * dx + dy * dy >= MouseMoveThresholdPx * MouseMoveThresholdPx)
            {
                _anchor = (x, y);
                _anchorAt = at;
                MarkLocked(at);
            }
        }
    }

    /// <summary>One poll of a connected controller. A missing controller just isn't reported.</summary>
    public void Gamepad(DateTimeOffset at, int index, GamepadState state)
    {
        lock (_gate)
        {
            if (_pads.TryGetValue(index, out var last) && IsUse(last, state))
            {
                MarkLocked(at);
            }
            _pads[index] = state;
        }
    }

    public void GamepadDisconnected(int index)
    {
        lock (_gate)
        {
            _pads.Remove(index);
        }
    }

    public void DisplayChanged(DateTimeOffset at, bool on)
    {
        lock (_gate)
        {
            _displayOff = !on;
            if (on)
            {
                // Waking the screen is usually someone sitting down.
                MarkLocked(at);
            }
        }
    }

    public int IdleSeconds(DateTimeOffset now)
    {
        lock (_gate)
        {
            if (_displayOff)
            {
                return DisplayOffIdleSeconds;
            }
            return (int)Math.Max(0, (now - _lastActive).TotalSeconds);
        }
    }

    private static bool IsUse(GamepadState a, GamepadState b) =>
        a.Buttons != b.Buttons
        || Math.Abs(a.LeftTrigger - b.LeftTrigger) >= TriggerChangeThreshold
        || Math.Abs(a.RightTrigger - b.RightTrigger) >= TriggerChangeThreshold
        || Math.Abs(a.LeftX - b.LeftX) >= StickChangeThreshold
        || Math.Abs(a.LeftY - b.LeftY) >= StickChangeThreshold
        || Math.Abs(a.RightX - b.RightX) >= StickChangeThreshold
        || Math.Abs(a.RightY - b.RightY) >= StickChangeThreshold;

    private void Mark(DateTimeOffset at)
    {
        lock (_gate)
        {
            MarkLocked(at);
        }
    }

    private void MarkLocked(DateTimeOffset at)
    {
        if (at > _lastActive)
        {
            _lastActive = at;
        }
    }
}

/// <summary>An XInput-style controller reading.</summary>
public readonly record struct GamepadState(int Buttons, int LeftTrigger, int RightTrigger, int LeftX, int LeftY, int RightX, int RightY);
