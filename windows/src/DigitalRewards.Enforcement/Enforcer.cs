using DigitalRewards.CloudKit;
using DigitalRewards.Core;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace DigitalRewards.Enforcement;

public sealed class EnforcerOptions
{
    public required string DeviceId { get; init; }
    public string DeviceName { get; init; } = Environment.MachineName;

    /// <summary>%SystemRoot%; executables under it are always allowed.</summary>
    public string? SystemRoot { get; init; }

    public TimeSpan OfflineLimit { get; init; } = TimeSpan.FromHours(24);
    public TimeSpan SyncInterval { get; init; } = TimeSpan.FromSeconds(30);
    public TimeSpan HeartbeatInterval { get; init; } = TimeSpan.FromMinutes(5);
    public TimeSpan SaveInterval { get; init; } = TimeSpan.FromMinutes(1);

    /// <summary>Relaunch the agent if it hasn't reported for this long.</summary>
    public TimeSpan AgentSilenceRelaunch { get; init; } = TimeSpan.FromSeconds(20);

    /// <summary>Minimum time between agent launches in one session.</summary>
    public TimeSpan AgentRelaunchBackoff { get; init; } = TimeSpan.FromSeconds(30);

    public AccountingOptions Accounting { get; init; } = new();
}

/// <summary>
/// The service's brain: tracks each signed-in Windows account, counts play minutes, syncs with
/// CloudKit, closes apps when time runs out, and keeps the agent running. Platform access goes
/// through interfaces so this class is fully testable.
/// </summary>
public sealed class Enforcer
{
    private readonly IStateStore _store;
    private readonly ICloudGatewayFactory _cloud;
    private readonly ISessionProvider _sessions;
    private readonly IProcessController _processes;
    private readonly IAgentLauncher _launcher;
    private readonly IAppCatalog _apps;
    private readonly EnforcerOptions _options;
    private readonly TimeProvider _clock;
    private readonly ILogger _log;
    private readonly object _gate = new();
    private readonly Dictionary<string, Runtime> _runtimes = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<int, DateTimeOffset> _lastLaunch = [];
    private readonly SemaphoreSlim _syncGate = new(1, 1);

    public Enforcer(
        IStateStore store,
        ICloudGatewayFactory cloud,
        ISessionProvider sessions,
        IProcessController processes,
        IAgentLauncher launcher,
        IAppCatalog apps,
        EnforcerOptions options,
        TimeProvider? clock = null,
        ILogger<Enforcer>? log = null)
    {
        _store = store;
        _cloud = cloud;
        _sessions = sessions;
        _processes = processes;
        _launcher = launcher;
        _apps = apps;
        _options = options;
        _clock = clock ?? TimeProvider.System;
        _log = (ILogger?)log ?? NullLogger.Instance;
    }

    private sealed class Runtime(string sid, ChildState state, PlayMinuteAccountant accountant)
    {
        public string Sid { get; } = sid;
        public ChildState State { get; } = state;
        public PlayMinuteAccountant Accountant { get; } = accountant;
        public ChildSnapshot Snapshot { get; set; } = new();
        public PlayStatus? Status { get; set; }
        public BlockDecision Decision { get; set; } = BlockDecision.Allow;
        public DateTimeOffset LastSaved { get; set; }
        public bool Dirty { get; set; }
        public DateTimeOffset? LastSyncAttempt { get; set; }
        public string? LastSyncError { get; set; }
        public bool SetupNeeded { get; set; }
        public string? LastClosedApp { get; set; }
        public DateTimeOffset? LastClosedAt { get; set; }
    }

    private Runtime RuntimeFor(string sid)
    {
        if (!_runtimes.TryGetValue(sid, out var rt))
        {
            var state = _store.Load(sid);
            var migrated = state.Migrate();
            rt = new Runtime(sid, state, new PlayMinuteAccountant(_options.DeviceId, _options.Accounting, _clock.GetUtcNow()))
            {
                Snapshot = state.Snapshot(_options.DeviceId),
                LastSaved = _clock.GetUtcNow(),
            };
            _runtimes[sid] = rt;
            if (migrated)
            {
                Save(rt);
            }
        }
        return rt;
    }

    private AllowPolicy PolicyFor(Runtime rt) => new(rt.Snapshot.AllowList, _options.SystemRoot);

    private static bool IsBound(Runtime rt) => rt.State.Account is not null;

    // ------------------------------------------------------------------ agent requests

    public async Task<AgentResponse> HandleAsync(AgentClient client, AgentRequest request, CancellationToken ct)
    {
        switch (request.Type)
        {
            case AgentRequestType.Report when request.Report is not null:
                lock (_gate)
                {
                    var rt = RuntimeFor(client.Sid);
                    var now = _clock.GetUtcNow();
                    rt.Accountant.OnReport(now, request.Report);
                    RememberApp(rt, request.Report.Foreground);
                    var app = IsBound(rt) ? rt.Accountant.CurrentPlayApp(now, sessionActive: true, PolicyFor(rt)) : null;
                    return new AgentResponse { Status = StatusFor(rt) with { Playing = app is not null, PlayingApp = app } };
                }
            case AgentRequestType.Status:
                lock (_gate)
                {
                    return new AgentResponse { Status = StatusFor(RuntimeFor(client.Sid)) };
                }
            case AgentRequestType.BeginSignIn:
                try
                {
                    return new AgentResponse { SignInUrl = await _cloud.GetSignInUrlAsync(ct).ConfigureAwait(false) };
                }
                catch (Exception e) when (e is CloudKitException or HttpRequestException)
                {
                    _log.LogWarning(e, "Could not get the iCloud sign-in URL");
                    return AgentResponse.Fail("Couldn't reach iCloud. Check the internet connection and try again.");
                }
            case AgentRequestType.CompleteSignIn when !string.IsNullOrWhiteSpace(request.Token):
                return await CompleteSignInAsync(client, request.Token!, ct).ConfigureAwait(false);
            default:
                return AgentResponse.Fail("Bad request.");
        }
    }

    private async Task<AgentResponse> CompleteSignInAsync(AgentClient client, string token, CancellationToken ct)
    {
        ChildAccount account;
        try
        {
            account = await _cloud.BindAsync(client.Sid, token, ct).ConfigureAwait(false);
        }
        catch (BindingException e)
        {
            return AgentResponse.Fail(e.Message);
        }
        catch (Exception e) when (e is CloudKitException or HttpRequestException)
        {
            _log.LogWarning(e, "Sign-in failed for {Sid}", client.Sid);
            return AgentResponse.Fail("iCloud sign-in didn't work. Please try again.");
        }

        lock (_gate)
        {
            var rt = RuntimeFor(client.Sid);
            var sameChild = rt.State.Account?.UserRecordName == account.UserRecordName
                            && rt.State.Account?.FamilyZoneName == account.FamilyZoneName;
            if (!sameChild)
            {
                rt.State.ResetCache();
                rt.State.PendingSpends.Clear();
                rt.State.LastSyncAt = null;
                rt.Snapshot = new ChildSnapshot();
            }
            rt.State.Account = account;
            Save(rt);
            _log.LogInformation("Windows account {Sid} linked to child {Child}", client.Sid, account.ChildName);
        }
        await SyncOneAsync(client.Sid, ct).ConfigureAwait(false);
        lock (_gate)
        {
            return new AgentResponse { Status = StatusFor(RuntimeFor(client.Sid)) };
        }
    }

    private void RememberApp(Runtime rt, ProcessRef? fg)
    {
        if (fg is null || AllowPolicy.SystemExecutables.Contains(AllowPolicy.Normalize(fg.Exe)))
        {
            return;
        }
        var exe = AllowPolicy.Normalize(fg.Exe);
        if (!rt.State.SeenApps.ContainsKey(exe))
        {
            rt.State.SeenApps[exe] = _apps.Describe(fg.Path) ?? exe;
            rt.Dirty = true;
        }
    }

    private AgentStatus StatusFor(Runtime rt)
    {
        if (!IsBound(rt))
        {
            return new AgentStatus { SignedIn = false };
        }
        var s = rt.Status;
        return new AgentStatus
        {
            SignedIn = !rt.State.Account!.NeedsSignIn,
            ChildName = rt.Snapshot.Child?.Name ?? rt.State.Account.ChildName,
            Balance = s?.Balance ?? 0,
            MinutesAvailable = rt.Decision.Blocked ? 0 : s?.MinutesAvailable ?? 0,
            CanPlay = s?.CanPlay ?? false,
            Reason = s?.Reason,
            Blocked = rt.Decision.Blocked,
            BlockReason = rt.Decision.Reason,
            LastSyncAt = rt.State.LastSyncAt,
            SetupNeeded = rt.SetupNeeded,
            LastClosedApp = rt.LastClosedApp,
            LastClosedAt = rt.LastClosedAt,
        };
    }

    // ------------------------------------------------------------------ once a second

    /// <summary>Accounting, enforcement and agent supervision. Call about once a second.</summary>
    public void Tick()
    {
        var now = _clock.GetUtcNow();
        var sessions = _sessions.Sessions();
        lock (_gate)
        {
            foreach (var session in sessions)
            {
                var rt = RuntimeFor(session.Sid);
                SuperviseAgent(rt, session, now);
                if (!IsBound(rt))
                {
                    continue;
                }
                var policy = PolicyFor(rt);
                var spends = rt.Accountant.Tick(now, session.Active, policy);
                if (spends.Count > 0)
                {
                    rt.State.PendingSpends.AddRange(spends);
                    rt.Dirty = true;
                }
                Evaluate(rt, now);
                if (rt.Decision.Blocked && session.Active)
                {
                    Enforce(rt, session, policy, now);
                }
            }
            foreach (var rt in _runtimes.Values)
            {
                if (rt.Dirty && now - rt.LastSaved >= _options.SaveInterval)
                {
                    Save(rt);
                }
            }
        }
    }

    private void Evaluate(Runtime rt, DateTimeOffset now)
    {
        var zone = TimeZones.TryFind(rt.Snapshot.TimeZone, out var z) ? z : TimeZoneInfo.Local;
        var pending = rt.State.PendingSpends.Select(s => new LedgerEntry(s.RecordName, EntryKind.Spend, s.Minutes, s.MinuteStart.ToUnixTimeMilliseconds()));
        rt.Status = rt.State.LastSyncAt is null ? null : PlayStatusCalculator.Compute(rt.Snapshot.Rules, zone, now, rt.Snapshot.Ledger(pending));
        var decision = EnforcementDecider.Decide(rt.Status, rt.State.LastSyncAt, now, _options.OfflineLimit);
        if (decision != rt.Decision)
        {
            _log.LogInformation("Account {Sid}: {State} ({Reason})", rt.Sid, decision.Blocked ? "blocked" : "allowed", decision.Reason);
        }
        rt.Decision = decision;
    }

    private void Enforce(Runtime rt, UserSession session, AllowPolicy policy, DateTimeOffset now)
    {
        var victims = EnforcementDecider.ProcessesToKill(rt.Decision, _processes.ProcessesInSession(session.SessionId), policy);
        foreach (var p in victims)
        {
            if (_processes.Kill(p.Pid))
            {
                rt.LastClosedApp = _apps.Describe(p.Path) ?? p.Exe;
                rt.LastClosedAt = now;
                _log.LogInformation("Closed {Exe} ({Pid}) in session {Session}: no play time left", p.Exe, p.Pid, session.SessionId);
            }
        }
    }

    private void SuperviseAgent(Runtime rt, UserSession session, DateTimeOffset now)
    {
        if (!session.Active)
        {
            return;
        }
        var running = _launcher.IsAgentRunning(session.SessionId);
        var silent = rt.Accountant.LastReportAt is not { } last || now - last > _options.AgentSilenceRelaunch;
        if (running && !silent)
        {
            return;
        }
        if (_lastLaunch.TryGetValue(session.SessionId, out var launched) && now - launched < _options.AgentRelaunchBackoff)
        {
            return;
        }
        _lastLaunch[session.SessionId] = now;
        try
        {
            _launcher.Launch(session.SessionId);
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            _log.LogWarning(e, "Couldn't start the agent in session {Session}", session.SessionId);
        }
    }

    // ------------------------------------------------------------------ sync

    /// <summary>Syncs every signed-in account whose sync is due.</summary>
    public async Task SyncDueAsync(CancellationToken ct)
    {
        List<string> due;
        lock (_gate)
        {
            foreach (var sid in _store.KnownSids())
            {
                RuntimeFor(sid);
            }
            var now = _clock.GetUtcNow();
            due = _runtimes.Values
                .Where(rt => IsBound(rt) && !rt.State.Account!.NeedsSignIn
                             && (rt.LastSyncAttempt is not { } at || now - at >= _options.SyncInterval))
                .Select(rt => rt.Sid)
                .ToList();
        }
        foreach (var sid in due)
        {
            await SyncOneAsync(sid, ct).ConfigureAwait(false);
        }
    }

    public async Task SyncOneAsync(string sid, CancellationToken ct)
    {
        await _syncGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            SyncInput input;
            DateTimeOffset now;
            lock (_gate)
            {
                var rt = RuntimeFor(sid);
                now = _clock.GetUtcNow();
                rt.LastSyncAttempt = now;
                if (rt.State.Account is not { NeedsSignIn: false } account)
                {
                    return;
                }
                var heartbeatDue = rt.State.LastHeartbeatAt is not { } hb || now - hb >= _options.HeartbeatInterval;
                input = new SyncInput(
                    account,
                    rt.State.FamilySyncToken,
                    rt.State.ActivitySyncToken,
                    rt.State.PendingSpends.ToList(),
                    heartbeatDue,
                    new DeviceInfo(_options.DeviceId, "windows", _options.DeviceName, now, heartbeatDue ? DetectedApps(rt) : null));
            }

            var outcome = await ChildSync.RunAsync(_cloud, input, now, ct).ConfigureAwait(false);

            lock (_gate)
            {
                var rt = RuntimeFor(sid);
                if (outcome.ApplyTo(rt.State))
                {
                    rt.Snapshot = rt.State.Snapshot(_options.DeviceId);
                }
                rt.LastSyncError = outcome.Error;
                if (outcome.Succeeded || outcome.SetupNeeded)
                {
                    rt.SetupNeeded = outcome.SetupNeeded;
                }
                if (outcome.Error is not null)
                {
                    _log.LogWarning("Sync failed for {Sid}: {Error}", sid, outcome.Error);
                }
                Evaluate(rt, _clock.GetUtcNow());
                Save(rt);
            }
        }
        finally
        {
            _syncGate.Release();
        }
    }

    private List<DetectedApp> DetectedApps(Runtime rt)
    {
        var apps = new Dictionary<string, DetectedApp>(StringComparer.OrdinalIgnoreCase);
        foreach (var (exe, name) in rt.State.SeenApps)
        {
            apps[exe] = new DetectedApp(exe, name);
        }
        foreach (var app in _apps.InstalledApps(rt.Sid))
        {
            apps.TryAdd(app.Exe, app);
        }
        return apps.Values.OrderBy(a => a.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    private void Save(Runtime rt)
    {
        try
        {
            _store.Save(rt.Sid, rt.State);
            rt.Dirty = false;
            rt.LastSaved = _clock.GetUtcNow();
        }
        catch (IOException e)
        {
            _log.LogError(e, "Couldn't save state for {Sid}", rt.Sid);
        }
    }

    /// <summary>Saves all state; call on shutdown.</summary>
    public void Flush()
    {
        lock (_gate)
        {
            foreach (var rt in _runtimes.Values)
            {
                Save(rt);
            }
        }
    }

    /// <summary>Current status for a Windows account (for tests and diagnostics).</summary>
    public AgentStatus StatusOf(string sid)
    {
        lock (_gate)
        {
            return StatusFor(RuntimeFor(sid));
        }
    }

    public IReadOnlyList<SpendInfo> PendingSpendsOf(string sid)
    {
        lock (_gate)
        {
            return RuntimeFor(sid).State.PendingSpends.ToList();
        }
    }
}
