using DigitalRewards.CloudKit;

namespace DigitalRewards.Enforcement;

/// <summary>CloudKit access for one signed-in child.</summary>
public interface ICloudGateway
{
    /// <summary>The current (possibly rotated) web auth token.</summary>
    string? WebAuthToken { get; }

    /// <summary>Fetches a zone the child can see in their shared database (both zones are parent-owned).</summary>
    Task<ZoneChanges> FetchChangesAsync(ZoneId zone, string? syncToken, CancellationToken ct);

    /// <summary>Creates spends in the child's Activity zone (shared database).</summary>
    Task<IReadOnlyList<RecordResult>> SaveSpendsAsync(ZoneId activityZone, IReadOnlyList<SpendInfo> spends, CancellationToken ct);

    Task SaveDeviceAsync(ZoneId activityZone, DeviceInfo device, CancellationToken ct);
}

public interface ICloudGatewayFactory
{
    ICloudGateway Create(string webAuthToken);

    /// <summary>Apple sign-in page for a new web auth token.</summary>
    Task<string> GetSignInUrlAsync(CancellationToken ct);

    /// <summary>Validates a new token and finds the child's Family and Activity zones.</summary>
    Task<ChildAccount> BindAsync(string sid, string webAuthToken, CancellationToken ct);
}

/// <summary>A sign-in that worked but can't be used yet (e.g. no family shared with this Apple ID).</summary>
public sealed class BindingException(string message) : Exception(message);

/// <summary>Production gateway over CloudKit Web Services.</summary>
public sealed class CloudGatewayFactory(HttpClient http, CloudKitOptions options) : ICloudGatewayFactory
{
    public ICloudGateway Create(string webAuthToken) => new CloudGateway(new CloudKitClient(http, options, webAuthToken));

    public Task<string> GetSignInUrlAsync(CancellationToken ct) => new CloudKitClient(http, options).GetSignInUrlAsync(ct);

    public async Task<ChildAccount> BindAsync(string sid, string webAuthToken, CancellationToken ct)
    {
        var client = new CloudKitClient(http, options, webAuthToken);
        var user = await client.GetCurrentUserRecordNameAsync(ct).ConfigureAwait(false);

        // Both of the child's zones live in a parent's iCloud, so they show up in the shared database.
        var shared = (await client.ListZonesAsync(CloudDatabase.Shared, ct).ConfigureAwait(false))
            .Select(z => z.ZoneId)
            .Where(z => z.OwnerRecordName is not null)
            .ToList();
        var family = shared
            .Where(z => z.ZoneName.StartsWith(ContractNames.FamilyZonePrefix, StringComparison.Ordinal))
            .ToList();
        if (family.Count == 0)
        {
            throw new BindingException("No family is shared with this Apple ID yet. Ask a parent to add you, then accept the invite in Go AFK on your iPhone.");
        }

        // A child normally sees exactly one family; take one whose Activity zone is shared too.
        var zone = family.FirstOrDefault(f => shared.Contains(new ZoneId(ContractNames.ActivityZoneFor(f.ZoneName), f.OwnerRecordName)));
        if (zone is null)
        {
            throw new BindingException(SetupMessages.ActivityNotShared);
        }

        var childRec = (await client.LookupAsync(CloudDatabase.Shared, zone, [ContractNames.ChildRecordName], ct).ConfigureAwait(false))
            .FirstOrDefault(r => r.Succeeded)?.Record;
        var child = childRec is null ? null : ContractRecords.ToChild(childRec);

        return new ChildAccount
        {
            Sid = sid,
            WebAuthToken = client.WebAuthToken ?? webAuthToken,
            UserRecordName = user,
            FamilyZoneName = zone.ZoneName,
            FamilyZoneOwner = zone.OwnerRecordName!,
            ChildId = child?.ChildId,
            ChildName = child?.Name,
        };
    }
}

/// <summary>Text shown to the child when their iCloud account isn't fully joined yet.</summary>
public static class SetupMessages
{
    public const string ActivityNotShared =
        "Your family isn't fully set up for this Apple ID yet. Open Go AFK on your iPhone and join with "
        + "the code from your parent, then try again.";
}

internal sealed class CloudGateway(CloudKitClient client) : ICloudGateway
{
    public string? WebAuthToken => client.WebAuthToken;

    public Task<ZoneChanges> FetchChangesAsync(ZoneId zone, string? syncToken, CancellationToken ct) =>
        client.FetchZoneChangesAsync(CloudDatabase.Shared, zone, syncToken, ct);

    public Task<IReadOnlyList<RecordResult>> SaveSpendsAsync(ZoneId activityZone, IReadOnlyList<SpendInfo> spends, CancellationToken ct) =>
        client.ModifyAsync(CloudDatabase.Shared, activityZone, ModifyOperation.Create, spends.Select(ContractRecords.FromSpend), ct);

    public async Task SaveDeviceAsync(ZoneId activityZone, DeviceInfo device, CancellationToken ct)
    {
        var results = await client.ModifyAsync(CloudDatabase.Shared, activityZone, ModifyOperation.ForceReplace, [ContractRecords.FromDevice(device)], ct)
            .ConfigureAwait(false);
        if (results.FirstOrDefault(r => !r.Succeeded) is { } failed)
        {
            throw new CloudKitException(failed.ServerErrorCode, failed.Reason, System.Net.HttpStatusCode.OK);
        }
    }
}
