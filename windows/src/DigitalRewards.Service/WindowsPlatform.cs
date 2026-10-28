using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using DigitalRewards.CloudKit;
using DigitalRewards.Enforcement;
using Microsoft.Win32;
using static DigitalRewards.Service.NativeMethods;

namespace DigitalRewards.Service;

/// <summary>Interactive sessions via the WTS API. SIDs come from each session's user token.</summary>
internal sealed class WindowsSessionProvider : ISessionProvider
{
    private readonly Dictionary<(int, string), string> _sidCache = [];

    public IReadOnlyList<UserSession> Sessions()
    {
        var result = new List<UserSession>();
        if (!WTSEnumerateSessions(IntPtr.Zero, 0, 1, out var buffer, out var count))
        {
            return result;
        }
        try
        {
            var size = Marshal.SizeOf<WTS_SESSION_INFO>();
            for (var i = 0; i < count; i++)
            {
                var info = Marshal.PtrToStructure<WTS_SESSION_INFO>(buffer + i * size);
                if (info.SessionId == 0)
                {
                    continue;
                }
                var user = QueryString(info.SessionId, WTS_INFO_CLASS.WTSUserName);
                if (string.IsNullOrEmpty(user))
                {
                    continue;
                }
                var domain = QueryString(info.SessionId, WTS_INFO_CLASS.WTSDomainName) ?? "";
                var key = (info.SessionId, domain + "\\" + user);
                if (!_sidCache.TryGetValue(key, out var sid))
                {
                    sid = SidOfSession(info.SessionId);
                    if (sid is null)
                    {
                        continue;
                    }
                    _sidCache[key] = sid;
                }
                result.Add(new UserSession(info.SessionId, sid, key.Item2, info.State == WTS_CONNECTSTATE_CLASS.WTSActive));
            }
        }
        finally
        {
            WTSFreeMemory(buffer);
        }
        return result;
    }

    private static string? QueryString(int sessionId, WTS_INFO_CLASS cls)
    {
        if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, cls, out var buf, out _))
        {
            return null;
        }
        try
        {
            return Marshal.PtrToStringUni(buf);
        }
        finally
        {
            WTSFreeMemory(buf);
        }
    }

    private static string? SidOfSession(int sessionId)
    {
        if (!WTSQueryUserToken(sessionId, out var token))
        {
            return null;
        }
        try
        {
            using var identity = new WindowsIdentity(token);
            return identity.User?.Value;
        }
        finally
        {
            CloseHandle(token);
        }
    }
}

internal sealed class WindowsProcessController : IProcessController
{
    public IReadOnlyList<ProcessRef> ProcessesInSession(int sessionId)
    {
        var list = new List<ProcessRef>();
        foreach (var p in Process.GetProcesses())
        {
            using (p)
            {
                try
                {
                    if (p.SessionId != sessionId)
                    {
                        continue;
                    }
                    var path = ProcessImagePath(p.Id);
                    var exe = path is null ? p.ProcessName + ".exe" : Path.GetFileName(path);
                    list.Add(new ProcessRef(p.Id, exe, path));
                }
                catch (Exception e) when (e is InvalidOperationException or Win32Exception)
                {
                    // Process exited while we looked at it.
                }
            }
        }
        return list;
    }

    public bool Kill(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            p.Kill(entireProcessTree: false);
            return true;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or Win32Exception or NotSupportedException)
        {
            return false;
        }
    }
}

/// <summary>Starts DigitalRewards.Tray.exe as the logged-on user in their session.</summary>
internal sealed class WindowsAgentLauncher(string agentPath) : IAgentLauncher
{
    public string AgentPath { get; } = agentPath;

    public bool IsAgentRunning(int sessionId)
    {
        var name = Path.GetFileNameWithoutExtension(AgentPath);
        var procs = Process.GetProcessesByName(name);
        try
        {
            return procs.Any(p => p.SessionId == sessionId);
        }
        finally
        {
            foreach (var p in procs)
            {
                p.Dispose();
            }
        }
    }

    public void Launch(int sessionId)
    {
        if (!File.Exists(AgentPath))
        {
            throw new InvalidOperationException("Agent not found at " + AgentPath);
        }
        if (!WTSQueryUserToken(sessionId, out var userToken))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WTSQueryUserToken failed");
        }
        var primary = IntPtr.Zero;
        var env = IntPtr.Zero;
        try
        {
            if (!DuplicateTokenEx(userToken, MAXIMUM_ALLOWED, IntPtr.Zero, SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation, TOKEN_TYPE.TokenPrimary, out primary))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "DuplicateTokenEx failed");
            }
            if (!CreateEnvironmentBlock(out env, primary, false))
            {
                env = IntPtr.Zero;
            }
            var si = new STARTUPINFO { cb = Marshal.SizeOf<STARTUPINFO>(), lpDesktop = @"winsta0\default" };
            var cmd = new StringBuilder("\"" + AgentPath + "\" --agent");
            var flags = CREATE_NO_WINDOW | (env != IntPtr.Zero ? CREATE_UNICODE_ENVIRONMENT : 0);
            if (!CreateProcessAsUser(primary, AgentPath, cmd, IntPtr.Zero, IntPtr.Zero, false, flags, env,
                    Path.GetDirectoryName(AgentPath), ref si, out var pi))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessAsUser failed");
            }
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }
        finally
        {
            if (env != IntPtr.Zero)
            {
                DestroyEnvironmentBlock(env);
            }
            if (primary != IntPtr.Zero)
            {
                CloseHandle(primary);
            }
            CloseHandle(userToken);
        }
    }
}

/// <summary>Installed apps from the Uninstall registry keys (machine-wide and the user's own).</summary>
internal sealed class WindowsAppCatalog : IAppCatalog
{
    private const string UninstallKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";
    private const string UninstallKey32 = @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall";

    public IReadOnlyList<DetectedApp> InstalledApps(string sid)
    {
        var apps = new Dictionary<string, DetectedApp>(StringComparer.OrdinalIgnoreCase);
        Read(Registry.LocalMachine, UninstallKey, apps);
        Read(Registry.LocalMachine, UninstallKey32, apps);
        Read(Registry.Users, sid + @"\" + UninstallKey, apps);
        return apps.Values.ToList();
    }

    public string? Describe(string? path)
    {
        if (string.IsNullOrEmpty(path) || !File.Exists(path))
        {
            return null;
        }
        try
        {
            var info = FileVersionInfo.GetVersionInfo(path);
            return string.IsNullOrWhiteSpace(info.FileDescription) ? info.ProductName : info.FileDescription;
        }
        catch (FileNotFoundException)
        {
            return null;
        }
    }

    private static void Read(RegistryKey root, string path, Dictionary<string, DetectedApp> into)
    {
        using var key = root.OpenSubKey(path);
        if (key is null)
        {
            return;
        }
        foreach (var name in key.GetSubKeyNames())
        {
            using var sub = key.OpenSubKey(name);
            if (sub is null || sub.GetValue("SystemComponent") is int sc && sc == 1)
            {
                continue;
            }
            var display = sub.GetValue("DisplayName") as string;
            var exe = ExeFromIcon(sub.GetValue("DisplayIcon") as string);
            if (string.IsNullOrWhiteSpace(display) || exe is null)
            {
                continue;
            }
            var file = AllowPolicy.Normalize(exe);
            if (file.StartsWith("unins", StringComparison.OrdinalIgnoreCase) || file.Contains("uninstall", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            into.TryAdd(file, new DetectedApp(file, display.Trim()));
        }
    }

    /// <summary>DisplayIcon is like "C:\Games\x.exe,0" or "\"C:\x.exe\"".</summary>
    internal static string? ExeFromIcon(string? icon)
    {
        if (string.IsNullOrWhiteSpace(icon))
        {
            return null;
        }
        var s = icon.Trim().Trim('"');
        var comma = s.LastIndexOf(',');
        if (comma > 0 && !s[(comma + 1)..].Contains('\\'))
        {
            s = s[..comma].Trim().Trim('"');
        }
        return s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? s : null;
    }
}
