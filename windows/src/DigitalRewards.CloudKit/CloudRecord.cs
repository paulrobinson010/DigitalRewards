using System.Text.Json;

namespace DigitalRewards.CloudKit;

public enum CloudDatabase
{
    Private,
    Shared,
    Public,
}

/// <summary>CloudKit field types used by the contract.</summary>
public enum CloudValueType
{
    String,
    Int64,
    Double,
    Timestamp,
    /// <summary>Any other CloudKit type; the raw JSON value is kept.</summary>
    Other,
}

public sealed record ZoneId(string ZoneName, string? OwnerRecordName = null)
{
    public static ZoneId Default { get; } = new("_defaultZone");
}

/// <summary>A typed CloudKit field value.</summary>
public sealed record CloudValue
{
    private CloudValue(CloudValueType type, string? s = null, long? l = null, double? d = null, JsonElement? raw = null, string? typeName = null)
    {
        Type = type;
        StringValue = s;
        Int64Value = l;
        DoubleValue = d;
        Raw = raw;
        TypeName = typeName;
    }

    public CloudValueType Type { get; }
    public string? StringValue { get; }
    public long? Int64Value { get; }
    public double? DoubleValue { get; }
    public JsonElement? Raw { get; }

    /// <summary>The CloudKit type name for <see cref="CloudValueType.Other"/> values.</summary>
    public string? TypeName { get; }

    public static CloudValue String(string value) => new(CloudValueType.String, s: value);
    public static CloudValue Int64(long value) => new(CloudValueType.Int64, l: value);
    public static CloudValue Double(double value) => new(CloudValueType.Double, d: value);
    public static CloudValue Timestamp(DateTimeOffset value) => new(CloudValueType.Timestamp, l: value.ToUnixTimeMilliseconds());
    public static CloudValue TimestampMs(long epochMs) => new(CloudValueType.Timestamp, l: epochMs);
    public static CloudValue Other(string typeName, JsonElement raw) => new(CloudValueType.Other, raw: raw.Clone(), typeName: typeName);

    public DateTimeOffset? AsTimestamp() =>
        Type == CloudValueType.Timestamp && Int64Value is { } ms ? DateTimeOffset.FromUnixTimeMilliseconds(ms) : null;
}

/// <summary>A CloudKit record as exchanged with CloudKit Web Services.</summary>
public sealed class CloudRecord
{
    public CloudRecord(string recordName, string recordType)
    {
        RecordName = recordName;
        RecordType = recordType;
    }

    public string RecordName { get; }
    public string RecordType { get; }
    public string? RecordChangeTag { get; set; }
    public bool Deleted { get; set; }
    public string? CreatedUserRecordName { get; set; }
    public Dictionary<string, CloudValue> Fields { get; } = new(StringComparer.Ordinal);

    public CloudRecord Set(string field, CloudValue? value)
    {
        if (value is null)
        {
            Fields.Remove(field);
        }
        else
        {
            Fields[field] = value;
        }
        return this;
    }

    public CloudRecord Set(string field, string? value) => Set(field, value is null ? null : CloudValue.String(value));
    public CloudRecord Set(string field, long? value) => Set(field, value is { } v ? CloudValue.Int64(v) : null);
    public CloudRecord Set(string field, double? value) => Set(field, value is { } v ? CloudValue.Double(v) : null);
    public CloudRecord Set(string field, DateTimeOffset? value) => Set(field, value is { } v ? CloudValue.Timestamp(v) : null);

    public string? GetString(string field) => Fields.TryGetValue(field, out var v) ? v.StringValue : null;

    public long? GetInt64(string field) =>
        Fields.TryGetValue(field, out var v) ? v.Int64Value ?? (v.DoubleValue is { } d ? (long)Math.Round(d) : null) : null;

    public double? GetDouble(string field) =>
        Fields.TryGetValue(field, out var v) ? v.DoubleValue ?? v.Int64Value : null;

    public DateTimeOffset? GetTimestamp(string field) =>
        Fields.TryGetValue(field, out var v) && v.Int64Value is { } ms ? DateTimeOffset.FromUnixTimeMilliseconds(ms) : null;

    public long? GetTimestampMs(string field) => Fields.TryGetValue(field, out var v) ? v.Int64Value : null;
}
