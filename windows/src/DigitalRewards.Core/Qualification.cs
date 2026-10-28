namespace DigitalRewards.Core;

public enum ActivityType
{
    Walk,
    Cycle,
    Other,
}

/// <summary>Result of one full minute of active workout time: passed and total sample ticks.</summary>
public readonly record struct MinuteResult(int P, int T);

/// <summary>Activity qualification (CONTRACT §2).</summary>
public static class Qualification
{
    public const int SampleIntervalSeconds = 5;
    public const int SamplesPerMinute = 60 / SampleIntervalSeconds;

    public static int MaxHeartRate(int birthYear, int atYear) => 220 - (atYear - birthYear);

    public static int HrThresholdBpm(double pct, int birthYear, int atYear) =>
        (int)Math.Round(pct * MaxHeartRate(birthYear, atYear), MidpointRounding.AwayFromZero);

    public static int HrThresholdBpm(Rules rules, ActivityType activity, int birthYear, int atYear) =>
        HrThresholdBpm(activity == ActivityType.Walk ? rules.WalkHrPct : rules.OtherHrPct, birthYear, atYear);

    public static bool SamplePasses(Rules rules, ActivityType activity, int birthYear, int atYear, int? hr, double? cadence)
    {
        var threshold = HrThresholdBpm(rules, activity, birthYear, atYear);
        var hrOk = hr is { } h && h >= threshold;
        if (activity != ActivityType.Walk)
        {
            return hrOk;
        }
        return hrOk && cadence is { } c && c >= rules.WalkCadenceSpm;
    }

    public static bool MinuteQualifies(Rules rules, MinuteResult minute) =>
        minute.T > 0 && minute.P >= rules.QualifyFraction * minute.T - 1e-9;

    public static int QualifyingMinutes(Rules rules, IEnumerable<MinuteResult> minutes) =>
        minutes.Count(m => MinuteQualifies(rules, m));

    public static int EarnedMinutes(Rules rules, IEnumerable<MinuteResult> minutes) =>
        QualifyingMinutes(rules, minutes) * rules.Ratio;
}
