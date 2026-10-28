namespace DigitalRewards.Enforcement;

/// <summary>
/// Decides whether an executable is free to use (no play time, never closed).
/// Allowed: Windows components, the DigitalRewards agent, and the parent's allow list for this PC.
/// </summary>
public sealed class AllowPolicy
{
    /// <summary>Windows components that are always allowed, even outside %SystemRoot%.</summary>
    public static readonly IReadOnlySet<string> SystemExecutables = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "explorer.exe", "taskmgr.exe", "systemsettings.exe", "applicationframehost.exe",
        "shellexperiencehost.exe", "startmenuexperiencehost.exe", "searchhost.exe", "searchapp.exe",
        "searchui.exe", "lockapp.exe", "logonui.exe", "dwm.exe", "ctfmon.exe", "sihost.exe",
        "textinputhost.exe", "runtimebroker.exe", "taskhostw.exe", "conhost.exe", "dllhost.exe",
        "smartscreen.exe", "securityhealthsystray.exe", "securityhealthservice.exe", "fontdrvhost.exe",
        "winlogon.exe", "csrss.exe", "userinit.exe", "backgroundtaskhost.exe", "widgets.exe",
        "widgetservice.exe", "msedgewebview2.exe", "phoneexperiencehost.exe", "useroobebroker.exe",
        "credentialuibroker.exe", "consent.exe", "openwith.exe", "werfault.exe", "rundll32.exe",
        "systemsettingsbroker.exe", "settingsynchost.exe", "screenclippinghost.exe", "snippingtool.exe",
        "onedrive.exe", "filecoauth.exe", "gamebarpresencewriter.exe", "crossdeviceresume.exe",
        "digitalrewards.tray.exe", "digitalrewards.service.exe",
    };

    private readonly string? _systemRoot;
    private readonly HashSet<string> _parentAllowed;

    /// <param name="systemRoot">%SystemRoot% (e.g. C:\Windows). Anything under it is a Windows component.</param>
    public AllowPolicy(IEnumerable<string> parentAllowed, string? systemRoot)
    {
        _parentAllowed = new HashSet<string>(parentAllowed.Select(Normalize), StringComparer.OrdinalIgnoreCase);
        _systemRoot = string.IsNullOrEmpty(systemRoot) ? null : systemRoot.TrimEnd('\\', '/') + "\\";
    }

    public static string Normalize(string exe) => Path.GetFileName(exe.Replace('/', '\\').Split('\\')[^1]).Trim().ToLowerInvariant();

    public bool IsAllowed(string exe, string? path)
    {
        var name = Normalize(exe);
        if (name.Length == 0 || SystemExecutables.Contains(name) || _parentAllowed.Contains(name))
        {
            return true;
        }
        return _systemRoot is not null && path is not null
            && path.Replace('/', '\\').StartsWith(_systemRoot, StringComparison.OrdinalIgnoreCase);
    }
}
