using System.Text.Json;
using System.Text.Json.Serialization;

namespace DigitalRewards.Enforcement;

/// <summary>Named pipe protocol between the per-user agent (tray) and the service.
/// One JSON request line per connection, answered with one JSON response line.</summary>
public static class AgentProtocol
{
    public const string PipeName = "DigitalRewards.Agent";

    public static JsonSerializerOptions Json { get; } = CreateOptions();

    private static JsonSerializerOptions CreateOptions()
    {
        var o = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        };
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        o.MakeReadOnly(populateMissingResolver: true);
        return o;
    }

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Json);

    public static T? Deserialize<T>(string line) => JsonSerializer.Deserialize<T>(line, Json);
}

public enum AgentRequestType
{
    Report,
    Status,
    BeginSignIn,
    CompleteSignIn,
}

/// <param name="Package">Package family name for Store (MSIX/UWP) apps, which often run inside a generic
/// Windows host such as WWAHost.exe; null for ordinary programs.</param>
/// <param name="Title">Window title, used as the display name for Store apps.</param>
public sealed record ProcessRef(int Pid, string Exe, string? Path, string? Package = null, string? Title = null)
{
    /// <summary>What the parent's allow list and the ledger know the app by: the package for Store apps, else the exe.</summary>
    public string AppKey => string.IsNullOrEmpty(Package) ? AllowPolicy.Normalize(Exe) : Package.ToLowerInvariant();

    /// <summary>A readable name: the window title or package name for Store apps, else the exe.</summary>
    public string DisplayName => string.IsNullOrEmpty(Package)
        ? AllowPolicy.Normalize(Exe)
        : !string.IsNullOrWhiteSpace(Title) ? Title.Trim() : Package.Split('_')[0];
}

/// <summary>What the user is doing right now, as seen by the agent in the user session.</summary>
public sealed record ForegroundReport
{
    /// <summary>Foreground process; null when there is no foreground window (locked, desktop).</summary>
    public ProcessRef? Foreground { get; init; }

    /// <summary>Seconds since the last keyboard/mouse input.</summary>
    public int IdleSeconds { get; init; }

    /// <summary>Processes owning visible top-level windows.</summary>
    public IReadOnlyList<ProcessRef> Windows { get; init; } = [];
}

public sealed record AgentRequest
{
    public AgentRequestType Type { get; init; }
    public ForegroundReport? Report { get; init; }
    public string? Token { get; init; }
}

public sealed record AgentStatus
{
    public bool SignedIn { get; init; }
    public string? ChildName { get; init; }
    public int Balance { get; init; }
    public int MinutesAvailable { get; init; }
    public bool CanPlay { get; init; }
    public string? Reason { get; init; }
    public bool Blocked { get; init; }
    public string? BlockReason { get; init; }
    public DateTimeOffset? LastSyncAt { get; init; }

    /// <summary>Signed in, but this Apple ID can't see the child's zones yet (invite not fully accepted).</summary>
    public bool SetupNeeded { get; init; }

    /// <summary>True when the foreground app costs play time right now.</summary>
    public bool Playing { get; init; }
    public string? PlayingApp { get; init; }

    /// <summary>The last app closed because play time ran out, and when.</summary>
    public string? LastClosedApp { get; init; }
    public DateTimeOffset? LastClosedAt { get; init; }
}

public sealed record AgentResponse
{
    public bool Ok { get; init; } = true;
    public string? Error { get; init; }
    public AgentStatus? Status { get; init; }
    public string? SignInUrl { get; init; }

    public static AgentResponse Fail(string error) => new() { Ok = false, Error = error };
}
