using System.Text.Json;
using System.Text.Json.Serialization;

namespace DigitalRewards.Core;

/// <summary>A time-of-day window in which play is allowed (CONTRACT §1).</summary>
public sealed record PlayWindow
{
    /// <summary>ISO weekdays, Monday = 1 … Sunday = 7.</summary>
    public int[] Days { get; init; } = [];

    /// <summary>"HH:mm".</summary>
    public string Start { get; init; } = "00:00";

    /// <summary>"HH:mm", may be "24:00".</summary>
    public string End { get; init; } = "24:00";

    public int StartMinutes => ParseMinutes(Start);
    public int EndMinutes => ParseMinutes(End);

    public static int ParseMinutes(string hhmm)
    {
        var parts = hhmm.Split(':');
        if (parts.Length != 2 || !int.TryParse(parts[0], out var h) || !int.TryParse(parts[1], out var m)
            || h < 0 || h > 24 || m < 0 || m > 59 || (h == 24 && m != 0))
        {
            throw new FormatException($"Invalid time of day '{hhmm}', expected HH:mm.");
        }
        return h * 60 + m;
    }
}

/// <summary>Per-child rules (CONTRACT §1). Defaults are the values for a new child.</summary>
public sealed record Rules
{
    public int Ratio { get; init; } = 10;
    public int WalkCadenceSpm { get; init; } = 100;
    public double WalkHrPct { get; init; } = 0.55;
    public double OtherHrPct { get; init; } = 0.65;
    public double QualifyFraction { get; init; } = 0.8;
    public int DebitLimit { get; init; } = 60;
    public int? MaxBank { get; init; }
    public int? DailyPlayCap { get; init; }
    public IReadOnlyList<PlayWindow>? PlayWindows { get; init; }

    public static Rules Default { get; } = new();
}

/// <summary>Shared JSON settings matching the contract (camelCase, lowercase enums).</summary>
public static class ContractJson
{
    public static JsonSerializerOptions Options { get; } = Create();

    private static JsonSerializerOptions Create()
    {
        var o = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        };
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        o.MakeReadOnly(populateMissingResolver: true);
        return o;
    }

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Options);

    public static T? Deserialize<T>(string json) => JsonSerializer.Deserialize<T>(json, Options);
}
