using System.Text.Json;
using DigitalRewards.Core;

namespace DigitalRewards.CloudKit.Tests;

public class CodecTests
{
    private static CloudRecord RoundTrip(CloudRecord r)
    {
        var json = CloudKitJson.EncodeRecord(r).ToJsonString();
        using var doc = JsonDocument.Parse(json);
        return CloudKitJson.DecodeRecord(doc.RootElement)!;
    }

    [Fact]
    public void RoundTripsEveryFieldType()
    {
        var at = DateTimeOffset.FromUnixTimeMilliseconds(1793001600123);
        var r = new CloudRecord("rules", "Rules") { RecordChangeTag = "tag" }
            .Set("ratio", 15L)
            .Set("walkHrPct", 0.55)
            .Set("updatedBy", "Mum")
            .Set("updatedAt", (DateTimeOffset?)at);

        var back = RoundTrip(r);

        Assert.Equal("tag", back.RecordChangeTag);
        Assert.Equal(15, back.GetInt64("ratio"));
        Assert.Equal(0.55, back.GetDouble("walkHrPct"));
        Assert.Equal("Mum", back.GetString("updatedBy"));
        Assert.Equal(at, back.GetTimestamp("updatedAt"));
        Assert.Equal(CloudValueType.Timestamp, back.Fields["updatedAt"].Type);
    }

    [Fact]
    public void EncodesTimestampAsEpochMs()
    {
        var json = CloudKitJson.EncodeValue(CloudValue.TimestampMs(42)).ToJsonString();
        Assert.Equal("""{"value":42,"type":"TIMESTAMP"}""", json);
    }

    [Theory]
    [InlineData("""{"value":"x"}""", CloudValueType.String)]
    [InlineData("""{"value":7}""", CloudValueType.Int64)]
    [InlineData("""{"value":7.5}""", CloudValueType.Double)]
    [InlineData("""{"value":"12","type":"INT64"}""", CloudValueType.Int64)]
    [InlineData("""{"value":{"recordName":"r"},"type":"REFERENCE"}""", CloudValueType.Other)]
    public void DecodesValues(string json, CloudValueType expected)
    {
        using var doc = JsonDocument.Parse(json);
        Assert.Equal(expected, CloudKitJson.DecodeValue(doc.RootElement).Type);
    }

    [Fact]
    public void KeepsUnknownTypesOnReEncode()
    {
        using var doc = JsonDocument.Parse("""{"value":{"recordName":"r"},"type":"REFERENCE"}""");
        var v = CloudKitJson.DecodeValue(doc.RootElement);
        Assert.Equal("""{"value":{"recordName":"r"},"type":"REFERENCE"}""", CloudKitJson.EncodeValue(v).ToJsonString());
    }

    [Fact]
    public void ErrorEntriesDecodeToNull()
    {
        using var doc = JsonDocument.Parse("""{"recordName":"x","serverErrorCode":"NOT_FOUND"}""");
        Assert.Null(CloudKitJson.DecodeRecord(doc.RootElement));
    }
}

public class ContractRecordTests
{
    private static readonly long T0 = 1793001600000;

    [Fact]
    public void SpendRecordNameUsesUtcMinute()
    {
        var local = new DateTimeOffset(2026, 10, 28, 18, 5, 0, TimeSpan.FromHours(1));
        Assert.Equal("spend-dev1-202610281705", ContractNames.SpendRecordName("dev1", local));
    }

    [Fact]
    public void RulesDecodeWithDefaultsAndWindows()
    {
        var r = new CloudRecord("rules", "Rules")
            .Set("ratio", 12L)
            .Set("maxBank", 600L)
            .Set("playWindows", """[{"days":[1,2,3],"start":"16:00","end":"20:00"}]""");

        var rules = ContractRecords.ToRules(r);

        Assert.Equal(12, rules.Ratio);
        Assert.Equal(600, rules.MaxBank);
        Assert.Null(rules.DailyPlayCap);
        Assert.Equal(60, rules.DebitLimit);
        var w = Assert.Single(rules.PlayWindows!);
        Assert.Equal([1, 2, 3], w.Days);
        Assert.Equal(20 * 60, w.EndMinutes);
    }

    [Fact]
    public void AllowListIsLowercasedAndTolerant()
    {
        Assert.Equal(["winword.exe", "chrome.exe"],
            ContractRecords.ToAllowList(new CloudRecord("allow-d", "AllowList").Set("executables", """["WINWORD.EXE"," chrome.exe ",""]""")));
        Assert.Empty(ContractRecords.ToAllowList(new CloudRecord("allow-d", "AllowList").Set("executables", "not json")));
    }

    [Fact]
    public void DeviceRecordCarriesDetectedApps()
    {
        var r = ContractRecords.FromDevice(new DeviceInfo("d1", "windows", "PC", DateTimeOffset.FromUnixTimeMilliseconds(T0), [new DetectedApp("game.exe", "Game")]));
        Assert.Equal("device-d1", r.RecordName);
        Assert.Equal("""[{"exe":"game.exe","name":"Game"}]""", r.GetString("detectedApps"));
        Assert.Equal(T0, r.GetTimestampMs("lastSeenAt"));
    }

    [Fact]
    public void SnapshotResolvesOverridesAndBonusesIntoLedger()
    {
        var family = new[]
        {
            new CloudRecord("child", "Child").Set("childId", "c1").Set("name", "Sam").Set("birthYear", 2014L).Set("timeZone", "Europe/London"),
            new CloudRecord("rules", "Rules").Set("debitLimit", 30L),
            new CloudRecord("adjust-1", "Adjustment").Set("minutes", -5L).Set("at", (DateTimeOffset?)DateTimeOffset.FromUnixTimeMilliseconds(T0)),
            new CloudRecord("override-session-b", "SessionOverride").Set("sessionId", "session-b").Set("earnedMinutes", 0L),
            new CloudRecord("bonus-1", "Bonus").Set("multiplier", 2.0)
                .Set("startsAt", (DateTimeOffset?)DateTimeOffset.FromUnixTimeMilliseconds(T0))
                .Set("endsAt", (DateTimeOffset?)DateTimeOffset.FromUnixTimeMilliseconds(T0 + 86_400_000)),
            new CloudRecord("allow-pc1", "AllowList").Set("executables", """["word.exe"]"""),
            new CloudRecord("allow-other", "AllowList").Set("executables", """["game.exe"]"""),
            new CloudRecord("adjust-gone", "Adjustment") { Deleted = true },
        };
        var activity = new[]
        {
            Session("session-a", 50, T0 + 1000),
            Session("session-b", 70, T0 + 2000),
            Session("session-c", 30, T0 - 86_400_000),
            new CloudRecord("spend-pc1-1", "Spend").Set("minutes", 1L).Set("at", (DateTimeOffset?)DateTimeOffset.FromUnixTimeMilliseconds(T0 + 5000)),
        };

        var s = ChildSnapshot.From(family, activity, "pc1");

        Assert.Equal("Sam", s.Child!.Name);
        Assert.Equal(30, s.Rules.DebitLimit);
        Assert.Equal(["word.exe"], s.AllowList);
        var ledger = s.Ledger();
        Assert.Equal(100, ledger.Single(e => e.Id == "session-a").Minutes);   // 2x bonus
        Assert.Equal(0, ledger.Single(e => e.Id == "session-b").Minutes);     // voided
        Assert.Equal(30, ledger.Single(e => e.Id == "session-c").Minutes);    // before bonus
        Assert.Equal(100 + 0 + 30 - 5 - 1, LedgerFold.Balance(ledger, s.Rules.MaxBank));
    }

    private static CloudRecord Session(string name, long earned, long startedAt) =>
        new CloudRecord(name, "Session")
            .Set("earnedMinutes", earned)
            .Set("startedAt", (DateTimeOffset?)DateTimeOffset.FromUnixTimeMilliseconds(startedAt))
            .Set("endedAt", (DateTimeOffset?)DateTimeOffset.FromUnixTimeMilliseconds(startedAt + 1_800_000));
}
