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

public sealed record ProcessRef(int Pid, string Exe, string? Path);

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
