using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace DigitalRewards.CloudKit;

/// <summary>Encodes and decodes CloudKit Web Services JSON.</summary>
public static class CloudKitJson
{
    public static string TypeName(CloudValueType type) => type switch
    {
        CloudValueType.String => "STRING",
        CloudValueType.Int64 => "INT64",
        CloudValueType.Double => "DOUBLE",
        CloudValueType.Timestamp => "TIMESTAMP",
        _ => throw new ArgumentOutOfRangeException(nameof(type)),
    };

    public static JsonObject EncodeValue(CloudValue v)
    {
        if (v.Type == CloudValueType.Other)
        {
            return new JsonObject
            {
                ["value"] = v.Raw is { } raw ? JsonNode.Parse(raw.GetRawText()) : null,
                ["type"] = v.TypeName,
            };
        }
        JsonNode? value = v.Type switch
        {
            CloudValueType.String => JsonValue.Create(v.StringValue),
            CloudValueType.Int64 or CloudValueType.Timestamp => JsonValue.Create(v.Int64Value),
            CloudValueType.Double => JsonValue.Create(v.DoubleValue),
            _ => null,
        };
        return new JsonObject { ["value"] = value, ["type"] = TypeName(v.Type) };
    }

    public static CloudValue DecodeValue(JsonElement field)
    {
        var value = field.GetProperty("value");
        string? type = field.TryGetProperty("type", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
        switch (type)
        {
            case "STRING":
                return CloudValue.String(value.GetString() ?? "");
            case "INT64":
                return CloudValue.Int64(value.ValueKind == JsonValueKind.String
                    ? long.Parse(value.GetString()!, CultureInfo.InvariantCulture)
                    : value.GetInt64());
            case "DOUBLE":
                return CloudValue.Double(value.GetDouble());
            case "TIMESTAMP":
                return CloudValue.TimestampMs(value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var ms)
                    ? ms
                    : (long)value.GetDouble());
            case null:
                // Type omitted: infer from the JSON kind.
                return value.ValueKind switch
                {
                    JsonValueKind.String => CloudValue.String(value.GetString()!),
                    JsonValueKind.Number when value.TryGetInt64(out var l) => CloudValue.Int64(l),
                    JsonValueKind.Number => CloudValue.Double(value.GetDouble()),
                    _ => CloudValue.Other("UNKNOWN", value),
                };
            default:
                return CloudValue.Other(type, value);
        }
    }

    public static JsonObject EncodeRecord(CloudRecord record)
    {
        var fields = new JsonObject();
        foreach (var (name, value) in record.Fields)
        {
            fields[name] = EncodeValue(value);
        }
        var o = new JsonObject
        {
            ["recordName"] = record.RecordName,
            ["recordType"] = record.RecordType,
            ["fields"] = fields,
        };
        if (record.RecordChangeTag is not null)
        {
            o["recordChangeTag"] = record.RecordChangeTag;
        }
        return o;
    }

    /// <summary>Decodes a record dictionary. Returns null for per-record error entries.</summary>
    public static CloudRecord? DecodeRecord(JsonElement e)
    {
        if (e.TryGetProperty("serverErrorCode", out _))
        {
            return null;
        }
        var name = e.GetProperty("recordName").GetString()!;
        var type = e.TryGetProperty("recordType", out var rt) ? rt.GetString() ?? "" : "";
        var record = new CloudRecord(name, type)
        {
            RecordChangeTag = e.TryGetProperty("recordChangeTag", out var tag) ? tag.GetString() : null,
            Deleted = e.TryGetProperty("deleted", out var del) && del.ValueKind == JsonValueKind.True,
        };
        if (e.TryGetProperty("created", out var created) && created.TryGetProperty("userRecordName", out var urn))
        {
            record.CreatedUserRecordName = urn.GetString();
        }
        if (e.TryGetProperty("fields", out var fields) && fields.ValueKind == JsonValueKind.Object)
        {
            foreach (var f in fields.EnumerateObject())
            {
                record.Fields[f.Name] = DecodeValue(f.Value);
            }
        }
        return record;
    }

    public static JsonObject EncodeZoneId(ZoneId zone)
    {
        var o = new JsonObject { ["zoneName"] = zone.ZoneName };
        if (zone.OwnerRecordName is not null)
        {
            o["ownerRecordName"] = zone.OwnerRecordName;
        }
        return o;
    }

    public static ZoneId DecodeZoneId(JsonElement e) => new(
        e.GetProperty("zoneName").GetString()!,
        e.TryGetProperty("ownerRecordName", out var o) ? o.GetString() : null);
}
