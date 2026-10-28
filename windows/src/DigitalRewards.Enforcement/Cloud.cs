using DigitalRewards.CloudKit;

namespace DigitalRewards.Enforcement;

/// <summary>CloudKit access for one signed-in child.</summary>
public interface ICloudGateway
{
    /// <summary>The current (possibly rotated) web auth token.</summary>
    string? WebAuthToken { get; }

    Task<ZoneChanges> FetchChangesAsync(CloudDatabase database, ZoneId zone, string? syncToken, CancellationToken ct);
    Task<IReadOnlyList<RecordResult>> SaveSpendsAsync(IReadOnlyList<SpendInfo> spends, CancellationToken ct);
    Task SaveDeviceAsync(DeviceInfo device, CancellationToken ct);
}

public interface ICloudGatewayFactory
{
    ICloudGateway Create(string webAuthToken);

    /// <summary>Apple sign-in page for a new web auth token.</summary>
    Task<string> GetSignInUrlAsync(CancellationToken ct);

    /// <summary>Validates a new token and finds the child's family zone.</summary>
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

        var shared = await client.ListZonesAsync(CloudDatabase.Shared, ct).ConfigureAwait(false);
        var family = shared
            .Select(z => z.ZoneId)
            .Where(z => z.ZoneName.StartsWith(ContractNames.FamilyZonePrefix, StringComparison.Ordinal) && z.OwnerRecordName is not null)
            .ToList();
        if (family.Count == 0)
        {
            throw new BindingException("No family is shared with this Apple ID yet. Ask a parent to add you, then accept the invite in DigitalRewards on your iPhone.");
        }

        var priv = await client.ListZonesAsync(CloudDatabase.Private, ct).ConfigureAwait(false);
        if (!priv.Any(z => z.ZoneId.ZoneName == ContractNames.ActivityZone))
        {
            throw new BindingException("Open DigitalRewards on your iPhone and finish joining your family first.");
        }

        // A child normally sees exactly one family zone; prefer the one the Activity zone links to.
        var zone = family[0];
        var link = (await client.LookupAsync(CloudDatabase.Private, new ZoneId(ContractNames.ActivityZone), [ContractNames.LinkRecordName], ct).ConfigureAwait(false))
            .FirstOrDefault(r => r.Succeeded)?.Record;
        if (link?.GetString("familyZoneName") is { } linkedName)
        {
            zone = family.FirstOrDefault(z => z.ZoneName == linkedName) ?? zone;
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

internal sealed class CloudGateway(CloudKitClient client) : ICloudGateway
{
    private static readonly ZoneId Activity = new(ContractNames.ActivityZone);

    public string? WebAuthToken => client.WebAuthToken;

    public Task<ZoneChanges> FetchChangesAsync(CloudDatabase database, ZoneId zone, string? syncToken, CancellationToken ct) =>
        client.FetchZoneChangesAsync(database, zone, syncToken, ct);

    public Task<IReadOnlyList<RecordResult>> SaveSpendsAsync(IReadOnlyList<SpendInfo> spends, CancellationToken ct) =>
        client.ModifyAsync(CloudDatabase.Private, Activity, ModifyOperation.Create, spends.Select(ContractRecords.FromSpend), ct);

    public async Task SaveDeviceAsync(DeviceInfo device, CancellationToken ct)
    {
        var results = await client.ModifyAsync(CloudDatabase.Private, Activity, ModifyOperation.ForceReplace, [ContractRecords.FromDevice(device)], ct)
            .ConfigureAwait(false);
        if (results.FirstOrDefault(r => !r.Succeeded) is { } failed)
        {
            throw new CloudKitException(failed.ServerErrorCode, failed.Reason, System.Net.HttpStatusCode.OK);
        }
    }
}
