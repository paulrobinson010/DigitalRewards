using DigitalRewards.CloudKit;

namespace DigitalRewards.Enforcement;

/// <summary>An interactive Windows logon session.</summary>
/// <param name="Active">True when the session is attached to the console or RDP (not disconnected).</param>
public sealed record UserSession(int SessionId, string Sid, string UserName, bool Active);

public interface ISessionProvider
{
    IReadOnlyList<UserSession> Sessions();
}

public interface IProcessController
{
    IReadOnlyList<ProcessRef> ProcessesInSession(int sessionId);
    bool Kill(int pid);
}

/// <summary>Starts the tray agent inside a user session.</summary>
public interface IAgentLauncher
{
    bool IsAgentRunning(int sessionId);
    void Launch(int sessionId);
}

public interface IAppCatalog
{
    /// <summary>Installed applications visible to this user (HKLM + their HKCU uninstall keys).</summary>
    IReadOnlyList<DetectedApp> InstalledApps(string sid);

    /// <summary>A friendly name for an executable (file description), or null.</summary>
    string? Describe(string? path);
}

/// <summary>The pipe client that sent a request, as verified by the service.</summary>
public sealed record AgentClient(string Sid, int SessionId);
