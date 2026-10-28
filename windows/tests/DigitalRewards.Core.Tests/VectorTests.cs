using System.Text.Json;
using DigitalRewards.Core;

namespace DigitalRewards.Core.Tests;

public class QualificationVectorTests
{
    public static TheoryData<string> Samples => TestVectors.Names("qualification.json", "samples");
    public static TheoryData<string> Sessions => TestVectors.Names("qualification.json", "sessions");

    [Theory]
    [MemberData(nameof(Samples))]
    public void Sample(string name)
    {
        var c = TestVectors.Case("qualification.json", "samples", name);
        var rules = TestVectors.As<Rules>(c.GetProperty("rules"));
        var activity = TestVectors.As<ActivityType>(c.GetProperty("activityType"));
        var birthYear = c.GetProperty("birthYear").GetInt32();
        var atYear = c.GetProperty("atYear").GetInt32();
        int? hr = c.GetProperty("hr").ValueKind == JsonValueKind.Null ? null : c.GetProperty("hr").GetInt32();
        double? cadence = c.GetProperty("cadence").ValueKind == JsonValueKind.Null ? null : c.GetProperty("cadence").GetDouble();

        Assert.Equal(c.GetProperty("expectedThresholdBpm").GetInt32(), Qualification.HrThresholdBpm(rules, activity, birthYear, atYear));
        Assert.Equal(c.GetProperty("expectedPass").GetBoolean(), Qualification.SamplePasses(rules, activity, birthYear, atYear, hr, cadence));
    }

    [Theory]
    [MemberData(nameof(Sessions))]
    public void Session(string name)
    {
        var c = TestVectors.Case("qualification.json", "sessions", name);
        var rules = TestVectors.As<Rules>(c.GetProperty("rules"));
        var minutes = TestVectors.As<List<MinuteResult>>(c.GetProperty("minutes"));

        Assert.Equal(c.GetProperty("expectedQualifyingMinutes").GetInt32(), Qualification.QualifyingMinutes(rules, minutes));
        Assert.Equal(c.GetProperty("expectedEarnedMinutes").GetInt32(), Qualification.EarnedMinutes(rules, minutes));
    }
}

public class LedgerVectorTests
{
    public static TheoryData<string> Cases => TestVectors.Names("ledger.json", "cases");

    [Theory]
    [MemberData(nameof(Cases))]
    public void Fold(string name)
    {
        var c = TestVectors.Case("ledger.json", "cases", name);
        var entries = TestVectors.As<List<LedgerEntry>>(c.GetProperty("entries"));
        int? maxBank = c.GetProperty("maxBank").ValueKind == JsonValueKind.Null ? null : c.GetProperty("maxBank").GetInt32();

        Assert.Equal(c.GetProperty("expectedBalance").GetInt32(), LedgerFold.Balance(entries, maxBank));
    }
}

public class StatusVectorTests
{
    public static TheoryData<string> Cases => TestVectors.Names("status.json", "cases");

    [Theory]
    [MemberData(nameof(Cases))]
    public void Status(string name)
    {
        var c = TestVectors.Case("status.json", "cases", name);
        var rules = TestVectors.As<Rules>(c.GetProperty("rules"));
        var entries = TestVectors.As<List<LedgerEntry>>(c.GetProperty("entries"));
        var now = DateTimeOffset.Parse(c.GetProperty("now").GetString()!, System.Globalization.CultureInfo.InvariantCulture);
        var expected = TestVectors.As<PlayStatus>(c.GetProperty("expected"));

        var actual = PlayStatusCalculator.Compute(rules, c.GetProperty("timeZone").GetString()!, now, entries);

        Assert.Equal(expected, actual);
    }
}

public class CoreUnitTests
{
    [Fact]
    public void ParsesPlayWindowTimes()
    {
        Assert.Equal(16 * 60, PlayWindow.ParseMinutes("16:00"));
        Assert.Equal(24 * 60, PlayWindow.ParseMinutes("24:00"));
        Assert.Throws<FormatException>(() => PlayWindow.ParseMinutes("24:30"));
        Assert.Throws<FormatException>(() => PlayWindow.ParseMinutes("7pm"));
    }

    [Fact]
    public void RulesRoundTripUsesContractNames()
    {
        var json = ContractJson.Serialize(new Rules { MaxBank = 600 });
        Assert.Contains("\"walkCadenceSpm\":100", json);
        Assert.Contains("\"maxBank\":600", json);
        Assert.Contains("\"playWindows\":null", json);
        Assert.Equal(new Rules { MaxBank = 600 }.MaxBank, ContractJson.Deserialize<Rules>(json)!.MaxBank);
    }

    [Fact]
    public void FindsIanaZones()
    {
        Assert.True(TimeZones.TryFind("Europe/London", out _));
        Assert.False(TimeZones.TryFind("Not/AZone", out _));
    }
}
