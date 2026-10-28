using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace DigitalRewards.CloudKit;

public sealed class CloudKitOptions
{
    public string BaseUrl { get; set; } = "https://api.apple-cloudkit.com";
    public string ContainerId { get; set; } = "iCloud.com.digitalrewards.app";

    /// <summary>"development" or "production".</summary>
    public string Environment { get; set; } = "development";

    /// <summary>API token created in the CloudKit console (with a URL-redirect sign-in callback).</summary>
    public string ApiToken { get; set; } = "";

    /// <summary>Records requested per page for queries and zone changes.</summary>
    public int PageSize { get; set; } = 200;
}

public class CloudKitException : Exception
{
    public CloudKitException(string? serverErrorCode, string? reason, HttpStatusCode status)
        : base($"CloudKit error {(int)status} {serverErrorCode}: {reason}")
    {
        ServerErrorCode = serverErrorCode;
        Reason = reason;
        Status = status;
    }

    public string? ServerErrorCode { get; }
    public string? Reason { get; }
    public HttpStatusCode Status { get; }
}

/// <summary>Thrown when the web auth token is missing or expired (HTTP 421).</summary>
public sealed class CloudKitAuthenticationRequiredException(string? redirectUrl, string? reason)
    : CloudKitException("AUTHENTICATION_REQUIRED", reason, (HttpStatusCode)421)
{
    /// <summary>Apple sign-in page; after sign-in the browser is sent to the API token's callback URL with a ckWebAuthToken.</summary>
    public string? RedirectUrl { get; } = redirectUrl;
}

public sealed record ZoneInfo(ZoneId ZoneId, string? SyncToken);

public sealed record ZoneChanges(ZoneId ZoneId, IReadOnlyList<CloudRecord> Records, string? SyncToken);

/// <summary>Per-record outcome of records/modify or records/lookup.</summary>
public sealed record RecordResult(string RecordName, CloudRecord? Record, string? ServerErrorCode, string? Reason)
{
    public bool Succeeded => ServerErrorCode is null;
}

public sealed record QueryFilter(string FieldName, string Comparator, CloudValue Value);

public sealed record QuerySort(string FieldName, bool Ascending = true);

public static class ModifyOperation
{
    public const string Create = "create";
    public const string Update = "update";
    public const string ForceUpdate = "forceUpdate";
    public const string Replace = "replace";
    public const string ForceReplace = "forceReplace";
    public const string ForceDelete = "forceDelete";
}

/// <summary>
/// Minimal client for CloudKit Web Services
/// (https://api.apple-cloudkit.com/database/1/{container}/{environment}/{database}/{subpath}).
/// </summary>
public sealed class CloudKitClient
{
    private const string ApiVersion = "1";

    /// <summary>Response headers that may carry a rotated web auth token.</summary>
    private static readonly string[] TokenHeaders = ["X-Apple-CloudKit-Web-Auth-Token", "X-APPLE-WEBAUTH-TOKEN"];

    private readonly HttpClient _http;
    private readonly CloudKitOptions _options;
    private string? _webAuthToken;

    public CloudKitClient(HttpClient http, CloudKitOptions options, string? webAuthToken = null)
    {
        _http = http;
        _options = options;
        _webAuthToken = webAuthToken;
    }

    /// <summary>The current user web auth token, or null when signed out.</summary>
    public string? WebAuthToken => _webAuthToken;

    /// <summary>Raised when CloudKit hands back a new web auth token; persist it.</summary>
    public event Action<string>? WebAuthTokenChanged;

    public void SetWebAuthToken(string? token) => _webAuthToken = token;

    public Uri BuildUri(CloudDatabase database, string subpath)
    {
        var db = database switch
        {
            CloudDatabase.Private => "private",
            CloudDatabase.Shared => "shared",
            _ => "public",
        };
        var sb = new StringBuilder(_options.BaseUrl.TrimEnd('/'))
            .Append("/database/").Append(ApiVersion)
            .Append('/').Append(Uri.EscapeDataString(_options.ContainerId))
            .Append('/').Append(Uri.EscapeDataString(_options.Environment))
            .Append('/').Append(db)
            .Append('/').Append(subpath)
            .Append("?ckAPIToken=").Append(Uri.EscapeDataString(_options.ApiToken));
        if (!string.IsNullOrEmpty(_webAuthToken))
        {
            sb.Append("&ckWebAuthToken=").Append(Uri.EscapeDataString(_webAuthToken));
        }
        return new Uri(sb.ToString());
    }

    /// <summary>users/current. Returns the signed-in user's record name.</summary>
    public async Task<string> GetCurrentUserRecordNameAsync(CancellationToken ct = default)
    {
        using var doc = await SendAsync(HttpMethod.Get, CloudDatabase.Public, "users/current", null, ct).ConfigureAwait(false);
        return doc.RootElement.GetProperty("userRecordName").GetString()!;
    }

    /// <summary>
    /// Returns the Apple sign-in URL by calling users/current without a web auth token
    /// (CloudKit answers 421 with a redirectURL).
    /// </summary>
    public async Task<string> GetSignInUrlAsync(CancellationToken ct = default)
    {
        var saved = _webAuthToken;
        _webAuthToken = null;
        try
        {
            await GetCurrentUserRecordNameAsync(ct).ConfigureAwait(false);
            throw new CloudKitException("UNEXPECTED", "users/current succeeded without a web auth token", HttpStatusCode.OK);
        }
        catch (CloudKitAuthenticationRequiredException e) when (e.RedirectUrl is not null)
        {
            return e.RedirectUrl;
        }
        finally
        {
            _webAuthToken = saved;
        }
    }

    public async Task<IReadOnlyList<ZoneInfo>> ListZonesAsync(CloudDatabase database, CancellationToken ct = default)
    {
        using var doc = await SendAsync(HttpMethod.Get, database, "zones/list", null, ct).ConfigureAwait(false);
        var zones = new List<ZoneInfo>();
        if (doc.RootElement.TryGetProperty("zones", out var arr))
        {
            foreach (var z in arr.EnumerateArray())
            {
                if (z.TryGetProperty("serverErrorCode", out _))
                {
                    continue;
                }
                zones.Add(new ZoneInfo(
                    CloudKitJson.DecodeZoneId(z.GetProperty("zoneID")),
                    z.TryGetProperty("syncToken", out var st) ? st.GetString() : null));
            }
        }
        return zones;
    }

    /// <summary>records/query, following continuationMarker until all pages are read.</summary>
    public async Task<IReadOnlyList<CloudRecord>> QueryAsync(
        CloudDatabase database,
        ZoneId zone,
        string recordType,
        IEnumerable<QueryFilter>? filters = null,
        IEnumerable<QuerySort>? sorts = null,
        CancellationToken ct = default)
    {
        var results = new List<CloudRecord>();
        string? marker = null;
        do
        {
            var query = new JsonObject { ["recordType"] = recordType };
            if (filters is not null)
            {
                query["filterBy"] = new JsonArray(filters.Select(f => (JsonNode)new JsonObject
                {
                    ["fieldName"] = f.FieldName,
                    ["comparator"] = f.Comparator,
                    ["fieldValue"] = CloudKitJson.EncodeValue(f.Value),
                }).ToArray());
            }
            if (sorts is not null)
            {
                query["sortBy"] = new JsonArray(sorts.Select(s => (JsonNode)new JsonObject
                {
                    ["fieldName"] = s.FieldName,
                    ["ascending"] = s.Ascending,
                }).ToArray());
            }
            var body = new JsonObject
            {
                ["zoneID"] = CloudKitJson.EncodeZoneId(zone),
                ["resultsLimit"] = _options.PageSize,
                ["query"] = query,
            };
            if (marker is not null)
            {
                body["continuationMarker"] = marker;
            }
            using var doc = await SendAsync(HttpMethod.Post, database, "records/query", body, ct).ConfigureAwait(false);
            AddRecords(doc.RootElement, results);
            marker = doc.RootElement.TryGetProperty("continuationMarker", out var m) && m.ValueKind == JsonValueKind.String
                ? m.GetString()
                : null;
        }
        while (marker is not null);
        return results;
    }

    /// <summary>
    /// changes/zone: every record created, changed or deleted since <paramref name="syncToken"/>
    /// (all records when null). Deleted records come back with <see cref="CloudRecord.Deleted"/> set.
    /// </summary>
    public async Task<ZoneChanges> FetchZoneChangesAsync(CloudDatabase database, ZoneId zone, string? syncToken, CancellationToken ct = default)
    {
        var records = new List<CloudRecord>();
        var token = syncToken;
        while (true)
        {
            var zoneReq = new JsonObject
            {
                ["zoneID"] = CloudKitJson.EncodeZoneId(zone),
                ["resultsLimit"] = _options.PageSize,
            };
            if (token is not null)
            {
                zoneReq["syncToken"] = token;
            }
            var body = new JsonObject { ["zones"] = new JsonArray(zoneReq) };
            using var doc = await SendAsync(HttpMethod.Post, database, "changes/zone", body, ct).ConfigureAwait(false);
            var z = doc.RootElement.GetProperty("zones").EnumerateArray().First();
            if (z.TryGetProperty("serverErrorCode", out var err))
            {
                throw new CloudKitException(err.GetString(), z.TryGetProperty("reason", out var r) ? r.GetString() : null, HttpStatusCode.OK);
            }
            AddRecords(z, records);
            var next = z.TryGetProperty("syncToken", out var st) ? st.GetString() : null;
            var more = z.TryGetProperty("moreComing", out var mc) && mc.ValueKind == JsonValueKind.True;
            if (!more || next is null || next == token)
            {
                return new ZoneChanges(zone, records, next ?? token);
            }
            token = next;
        }
    }

    public async Task<IReadOnlyList<RecordResult>> LookupAsync(CloudDatabase database, ZoneId zone, IEnumerable<string> recordNames, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["zoneID"] = CloudKitJson.EncodeZoneId(zone),
            ["records"] = new JsonArray(recordNames.Select(n => (JsonNode)new JsonObject { ["recordName"] = n }).ToArray()),
        };
        using var doc = await SendAsync(HttpMethod.Post, database, "records/lookup", body, ct).ConfigureAwait(false);
        return ParseResults(doc.RootElement);
    }

    /// <summary>records/modify (non-atomic). Each record is sent with the same operation type.</summary>
    public async Task<IReadOnlyList<RecordResult>> ModifyAsync(
        CloudDatabase database,
        ZoneId zone,
        string operationType,
        IEnumerable<CloudRecord> records,
        CancellationToken ct = default)
    {
        var ops = new JsonArray(records.Select(r => (JsonNode)new JsonObject
        {
            ["operationType"] = operationType,
            ["record"] = CloudKitJson.EncodeRecord(r),
        }).ToArray());
        if (ops.Count == 0)
        {
            return [];
        }
        var body = new JsonObject
        {
            ["operations"] = ops,
            ["zoneID"] = CloudKitJson.EncodeZoneId(zone),
            ["atomic"] = false,
        };
        using var doc = await SendAsync(HttpMethod.Post, database, "records/modify", body, ct).ConfigureAwait(false);
        return ParseResults(doc.RootElement);
    }

    private static void AddRecords(JsonElement container, List<CloudRecord> into)
    {
        if (!container.TryGetProperty("records", out var arr))
        {
            return;
        }
        foreach (var r in arr.EnumerateArray())
        {
            if (CloudKitJson.DecodeRecord(r) is { } rec)
            {
                into.Add(rec);
            }
        }
    }

    private static List<RecordResult> ParseResults(JsonElement root)
    {
        var list = new List<RecordResult>();
        if (!root.TryGetProperty("records", out var arr))
        {
            return list;
        }
        foreach (var r in arr.EnumerateArray())
        {
            var name = r.TryGetProperty("recordName", out var n) ? n.GetString() ?? "" : "";
            if (r.TryGetProperty("serverErrorCode", out var code))
            {
                list.Add(new RecordResult(name, null, code.GetString(), r.TryGetProperty("reason", out var reason) ? reason.GetString() : null));
            }
            else
            {
                list.Add(new RecordResult(name, CloudKitJson.DecodeRecord(r), null, null));
            }
        }
        return list;
    }

    private async Task<JsonDocument> SendAsync(HttpMethod method, CloudDatabase database, string subpath, JsonObject? body, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(method, BuildUri(database, subpath));
        if (body is not null)
        {
            request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8);
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        }
        using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
        var text = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        JsonDocument? doc = null;
        if (!string.IsNullOrWhiteSpace(text))
        {
            try
            {
                doc = JsonDocument.Parse(text);
            }
            catch (JsonException)
            {
                doc = null;
            }
        }

        CaptureRotatedToken(response, doc);

        if ((int)response.StatusCode == 421 || ErrorCode(doc) == "AUTHENTICATION_REQUIRED")
        {
            var redirect = doc is not null && doc.RootElement.TryGetProperty("redirectURL", out var ru) ? ru.GetString() : null;
            var reason = Reason(doc);
            doc?.Dispose();
            throw new CloudKitAuthenticationRequiredException(redirect, reason);
        }
        if (!response.IsSuccessStatusCode || doc is null)
        {
            var code = ErrorCode(doc);
            var reason = Reason(doc) ?? (doc is null ? text : null);
            doc?.Dispose();
            throw new CloudKitException(code, reason, response.StatusCode);
        }
        return doc;
    }

    private void CaptureRotatedToken(HttpResponseMessage response, JsonDocument? doc)
    {
        string? token = null;
        foreach (var h in TokenHeaders)
        {
            if (response.Headers.TryGetValues(h, out var values))
            {
                token = values.FirstOrDefault();
                break;
            }
        }
        if (token is null && doc is not null && doc.RootElement.ValueKind == JsonValueKind.Object
            && doc.RootElement.TryGetProperty("ckWebAuthToken", out var t) && t.ValueKind == JsonValueKind.String)
        {
            token = t.GetString();
        }
        if (!string.IsNullOrEmpty(token) && token != _webAuthToken)
        {
            _webAuthToken = token;
            WebAuthTokenChanged?.Invoke(token);
        }
    }

    private static string? ErrorCode(JsonDocument? doc) =>
        doc is not null && doc.RootElement.ValueKind == JsonValueKind.Object
        && doc.RootElement.TryGetProperty("serverErrorCode", out var c) ? c.GetString() : null;

    private static string? Reason(JsonDocument? doc) =>
        doc is not null && doc.RootElement.ValueKind == JsonValueKind.Object
        && doc.RootElement.TryGetProperty("reason", out var r) ? r.GetString() : null;
}
