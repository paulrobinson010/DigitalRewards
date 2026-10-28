using DigitalRewards.Enforcement;

namespace DigitalRewards.Tray;

/// <summary>Collects what the user is doing: foreground process, idle time, windowed processes.</summary>
internal static class ForegroundProbe
{
    public static ForegroundReport Capture() => new()
    {
        Foreground = ForegroundProcess(),
        IdleSeconds = Native.IdleSeconds(),
        Windows = WindowedProcesses(),
    };

    private static ProcessRef? ForegroundProcess()
    {
        var hwnd = Native.GetForegroundWindow();
        if (hwnd == IntPtr.Zero)
        {
            return null;
        }
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        var p = Describe(pid);
        if (p is not null && p.Exe.Equals("applicationframehost.exe", StringComparison.OrdinalIgnoreCase))
        {
            // Store apps run inside a frame window; the real app owns a child window.
            ProcessRef? inner = null;
            Native.EnumChildWindows(hwnd, (child, _) =>
            {
                Native.GetWindowThreadProcessId(child, out var childPid);
                if (childPid != pid && Describe(childPid) is { } c)
                {
                    inner = c;
                    return false;
                }
                return true;
            }, IntPtr.Zero);
            return inner ?? p;
        }
        return p;
    }

    private static List<ProcessRef> WindowedProcesses()
    {
        var pids = new HashSet<int>();
        Native.EnumWindows((hwnd, _) =>
        {
            if (Native.IsWindowVisible(hwnd) && Native.GetWindow(hwnd, Native.GW_OWNER) == IntPtr.Zero && Native.GetWindowTextLength(hwnd) > 0)
            {
                Native.GetWindowThreadProcessId(hwnd, out var pid);
                pids.Add(pid);
            }
            return true;
        }, IntPtr.Zero);
        return pids.Select(Describe).OfType<ProcessRef>().ToList();
    }

    private static ProcessRef? Describe(int pid)
    {
        if (pid <= 0)
        {
            return null;
        }
        var path = Native.ProcessImagePath(pid);
        return path is null ? null : new ProcessRef(pid, Path.GetFileName(path), path);
    }
}
