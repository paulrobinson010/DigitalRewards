using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using DigitalRewards.CloudKit;

namespace DigitalRewards.Enforcement;

/// <summary>The binding between a Windows account and a child's iCloud account.</summary>
public sealed record ChildAccount
{
    public required string Sid { get; init; }
    public required string WebAuthToken { get; init; }
    public required string UserRecordName { get; init; }
    public required string FamilyZoneName { get; init; }
    public required string FamilyZoneOwner { get; init; }
    public string? ChildId { get; init; }
    public string? ChildName { get; init; }

    /// <summary>Set when CloudKit rejects the token; the child must sign in again.</summary>
    public bool NeedsSignIn { get; init; }

    public ZoneId FamilyZone => new(FamilyZoneName, FamilyZoneOwner);

    /// <summary>Activity-&lt;childId&gt;, owned by the same parent as the Family zone.</summary>
    public ZoneId ActivityZone => new(ContractNames.ActivityZoneFor(FamilyZoneName), FamilyZoneOwner);
}

/// <summary>Everything persisted for one Windows account (one file, encrypted at rest).</summary>
public sealed class ChildState
{
    /// <summary>
    /// Storage layout version. 2: the Activity zone is parent-owned (shared database). Older files
    /// cached a child-owned private Activity zone; <see cref="Migrate"/> drops that cache.
    /// </summary>
    public const int CurrentLayout = 2;

    /// <summary>Missing from older files, so it reads as 0 there.</summary>
    public int Layout { get; set; }

    public ChildAccount? Account { get; set; }
    public string? FamilySyncToken { get; set; }
    public string? ActivitySyncToken { get; set; }

    /// <summary>Cached records by recordName, in CloudKit Web Services JSON form.</summary>
    public Dictionary<string, JsonObject> FamilyRecords { get; set; } = new(StringComparer.Ordinal);
    public Dictionary<string, JsonObject> ActivityRecords { get; set; } = new(StringComparer.Ordinal);

    /// <summary>Spends recorded locally but not yet confirmed by CloudKit.</summary>
    public List<SpendInfo> PendingSpends { get; set; } = [];

    public DateTimeOffset? LastSyncAt { get; set; }
    public DateTimeOffset? LastHeartbeatAt { get; set; }

    /// <summary>Exes seen in the foreground, with display names, reported to the parent.</summary>
    public Dictionary<string, string> SeenApps { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public void ApplyChanges(Dictionary<string, JsonObject> cache, IEnumerable<CloudRecord> records)
    {
        foreach (var r in records)
        {
            if (r.Deleted)
            {
                cache.Remove(r.RecordName);
            }
            else
            {
                cache[r.RecordName] = CloudKitJson.EncodeRecord(r);
            }
        }
    }

    public static IEnumerable<CloudRecord> Decode(Dictionary<string, JsonObject> cache)
    {
        foreach (var json in cache.Values)
        {
            using var doc = JsonDocument.Parse(json.ToJsonString());
            if (CloudKitJson.DecodeRecord(doc.RootElement) is { } r)
            {
                yield return r;
            }
        }
    }

    public ChildSnapshot Snapshot(string deviceId) => ChildSnapshot.From(Decode(FamilyRecords), Decode(ActivityRecords), deviceId);

    /// <summary>Brings an older state up to <see cref="CurrentLayout"/>. Returns true if anything changed.</summary>
    public bool Migrate()
    {
        if (Layout >= CurrentLayout)
        {
            return false;
        }
        if (Layout < 2)
        {
            // The cached Activity records and token came from the old private zone. Unsent spends
            // are kept: they're real play and go to the new zone on the next sync.
            ActivitySyncToken = null;
            ActivityRecords.Clear();
            LastSyncAt = null;
        }
        Layout = CurrentLayout;
        return true;
    }

    public void ResetCache()
    {
        FamilySyncToken = null;
        ActivitySyncToken = null;
        FamilyRecords.Clear();
        ActivityRecords.Clear();
    }
}

/// <summary>Encrypts state at rest (DPAPI on Windows; pass-through in tests).</summary>
public interface IDataProtector
{
    byte[] Protect(byte[] data);
    byte[] Unprotect(byte[] data);
}

public sealed class NoProtection : IDataProtector
{
    public byte[] Protect(byte[] data) => data;
    public byte[] Unprotect(byte[] data) => data;
}

public interface IStateStore
{
    IReadOnlyList<string> KnownSids();
    ChildState Load(string sid);
    void Save(string sid, ChildState state);
    void Delete(string sid);
}

/// <summary>One protected JSON file per Windows account SID.</summary>
public sealed class FileStateStore : IStateStore
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = false };
    private readonly string _directory;
    private readonly IDataProtector _protector;
    private readonly object _gate = new();

    public FileStateStore(string directory, IDataProtector protector)
    {
        _directory = directory;
        _protector = protector;
        Directory.CreateDirectory(directory);
    }

    private string PathFor(string sid) => Path.Combine(_directory, Sanitize(sid) + ".state");

    private static string Sanitize(string sid) => new(sid.Where(c => char.IsLetterOrDigit(c) || c == '-').ToArray());

    public IReadOnlyList<string> KnownSids()
    {
        lock (_gate)
        {
            var sids = new List<string>();
            foreach (var file in Directory.EnumerateFiles(_directory, "*.state"))
            {
                var state = TryRead(file);
                if (state?.Account?.Sid is { } sid)
                {
                    sids.Add(sid);
                }
            }
            return sids;
        }
    }

    public ChildState Load(string sid)
    {
        lock (_gate)
        {
            return TryRead(PathFor(sid)) ?? new ChildState();
        }
    }

    public void Save(string sid, ChildState state)
    {
        lock (_gate)
        {
            var bytes = _protector.Protect(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(state, Json)));
            var path = PathFor(sid);
            var tmp = path + ".tmp";
            File.WriteAllBytes(tmp, bytes);
            File.Move(tmp, path, overwrite: true);
        }
    }

    public void Delete(string sid)
    {
        lock (_gate)
        {
            File.Delete(PathFor(sid));
        }
    }

    private ChildState? TryRead(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        try
        {
            var bytes = _protector.Unprotect(File.ReadAllBytes(path));
            return JsonSerializer.Deserialize<ChildState>(Encoding.UTF8.GetString(bytes), Json);
        }
        catch (Exception e) when (e is JsonException or IOException or System.Security.Cryptography.CryptographicException)
        {
            return null;
        }
    }
}
