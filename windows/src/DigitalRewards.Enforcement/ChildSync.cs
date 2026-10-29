using DigitalRewards.CloudKit;

namespace DigitalRewards.Enforcement;

/// <summary>What one sync round produced; applied to <see cref="ChildState"/> under the caller's lock.</summary>
public sealed record SyncOutcome
{
    public bool Succeeded { get; init; }
    public bool NeedsSignIn { get; init; }

    /// <summary>The child's zones aren't shared with this Apple ID (yet, or any more).</summary>
    public bool SetupNeeded { get; init; }
    public string? Error { get; init; }
    public bool ResetFamily { get; init; }
    public bool ResetActivity { get; init; }
    public ZoneChanges? Family { get; init; }
    public ZoneChanges? Activity { get; init; }
    public IReadOnlyList<string> ConfirmedSpends { get; init; } = [];
    public string? RotatedToken { get; init; }
    public bool HeartbeatSent { get; init; }
    public DateTimeOffset At { get; init; }

    /// <summary>Applies this outcome to the state. Returns true if the cached records changed.</summary>
    public bool ApplyTo(ChildState state)
    {
        var changed = false;
        if (RotatedToken is not null && state.Account is not null)
        {
            state.Account = state.Account with { WebAuthToken = RotatedToken };
        }
        if (NeedsSignIn && state.Account is not null)
        {
            state.Account = state.Account with { NeedsSignIn = true };
        }
        if (ResetFamily)
        {
            state.FamilyRecords.Clear();
            changed = true;
        }
        if (ResetActivity)
        {
            state.ActivityRecords.Clear();
            changed = true;
        }
        if (Family is not null)
        {
            state.ApplyChanges(state.FamilyRecords, Family.Records);
            state.FamilySyncToken = Family.SyncToken;
            changed |= Family.Records.Count > 0;
        }
        if (Activity is not null)
        {
            state.ApplyChanges(state.ActivityRecords, Activity.Records);
            state.ActivitySyncToken = Activity.SyncToken;
            changed |= Activity.Records.Count > 0;
        }
        if (ConfirmedSpends.Count > 0)
        {
            // Move confirmed spends into the cache so the balance never forgets them between fetches.
            var confirmed = ConfirmedSpends.ToHashSet(StringComparer.Ordinal);
            state.ApplyChanges(state.ActivityRecords, state.PendingSpends
                .Where(s => confirmed.Contains(s.RecordName) && !state.ActivityRecords.ContainsKey(s.RecordName))
                .Select(ContractRecords.FromSpend));
            state.PendingSpends.RemoveAll(s => confirmed.Contains(s.RecordName));
            changed = true;
        }
        if (HeartbeatSent)
        {
            state.LastHeartbeatAt = At;
        }
        if (Succeeded)
        {
            state.LastSyncAt = At;
        }
        return changed;
    }
}

public sealed record SyncInput(
    ChildAccount Account,
    string? FamilySyncToken,
    string? ActivitySyncToken,
    IReadOnlyList<SpendInfo> PendingSpends,
    bool HeartbeatDue,
    DeviceInfo Device);

/// <summary>One sync round for one child: pull both zones, push pending spends, heartbeat.</summary>
public static class ChildSync
{
    /// <summary>Errors meaning the sync token is no longer usable; refetch the zone from scratch.</summary>
    public static readonly IReadOnlySet<string> ResetTokenErrors = new HashSet<string>(StringComparer.Ordinal)
    {
        "CHANGE_TOKEN_EXPIRED", "BAD_SYNC_TOKEN", "INVALID_SYNC_TOKEN",
    };

    /// <summary>Errors meaning the zone isn't visible: the share wasn't accepted, or was removed.</summary>
    public static readonly IReadOnlySet<string> ZoneMissingErrors = new HashSet<string>(StringComparer.Ordinal)
    {
        "ZONE_NOT_FOUND", "USER_DELETED_ZONE",
    };

    /// <summary>Per-record errors on create that mean the spend is already saved (idempotent retry).</summary>
    public static readonly IReadOnlySet<string> AlreadySavedErrors = new HashSet<string>(StringComparer.Ordinal)
    {
        "CONFLICT", "EXISTS", "RECORD_EXISTS", "UNIQUE_FIELD_ERROR",
    };

    public static async Task<SyncOutcome> RunAsync(ICloudGatewayFactory factory, SyncInput input, DateTimeOffset now, CancellationToken ct)
    {
        var gateway = factory.Create(input.Account.WebAuthToken);
        try
        {
            // Push first so the pull that follows already contains these spends.
            var confirmed = new List<string>();
            if (input.PendingSpends.Count > 0)
            {
                var results = await gateway.SaveSpendsAsync(input.Account.ActivityZone, input.PendingSpends, ct).ConfigureAwait(false);
                confirmed.AddRange(results
                    .Where(r => r.Succeeded || (r.ServerErrorCode is { } code && AlreadySavedErrors.Contains(code)))
                    .Select(r => r.RecordName));
            }

            var resetFamily = false;
            var resetActivity = false;
            var family = await FetchAsync(gateway, input.Account.FamilyZone, input.FamilySyncToken, () => resetFamily = true, ct).ConfigureAwait(false);
            var activity = await FetchAsync(gateway, input.Account.ActivityZone, input.ActivitySyncToken, () => resetActivity = true, ct).ConfigureAwait(false);

            if (input.HeartbeatDue)
            {
                await gateway.SaveDeviceAsync(input.Account.ActivityZone, input.Device with { LastSeenAt = now }, ct).ConfigureAwait(false);
            }

            return new SyncOutcome
            {
                Succeeded = true,
                ResetFamily = resetFamily,
                ResetActivity = resetActivity,
                Family = family,
                Activity = activity,
                ConfirmedSpends = confirmed,
                HeartbeatSent = input.HeartbeatDue,
                RotatedToken = Rotated(gateway, input.Account),
                At = now,
            };
        }
        catch (CloudKitAuthenticationRequiredException)
        {
            return new SyncOutcome { NeedsSignIn = true, Error = "Sign in to iCloud again.", At = now };
        }
        catch (CloudKitException e) when (e.ServerErrorCode is { } code && ZoneMissingErrors.Contains(code))
        {
            return new SyncOutcome { SetupNeeded = true, Error = SetupMessages.ActivityNotShared, RotatedToken = Rotated(gateway, input.Account), At = now };
        }
        catch (Exception e) when (e is CloudKitException or HttpRequestException or TaskCanceledException && !ct.IsCancellationRequested)
        {
            return new SyncOutcome { Error = e.Message, RotatedToken = Rotated(gateway, input.Account), At = now };
        }
    }

    private static string? Rotated(ICloudGateway gateway, ChildAccount account) =>
        gateway.WebAuthToken is { } t && t != account.WebAuthToken ? t : null;

    private static async Task<ZoneChanges> FetchAsync(ICloudGateway gateway, ZoneId zone, string? token, Action onReset, CancellationToken ct)
    {
        try
        {
            return await gateway.FetchChangesAsync(zone, token, ct).ConfigureAwait(false);
        }
        catch (CloudKitException e) when (token is not null && e.ServerErrorCode is { } code && ResetTokenErrors.Contains(code))
        {
            onReset();
            return await gateway.FetchChangesAsync(zone, null, ct).ConfigureAwait(false);
        }
    }
}
