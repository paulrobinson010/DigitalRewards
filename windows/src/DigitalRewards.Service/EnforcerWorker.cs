using DigitalRewards.Enforcement;

namespace DigitalRewards.Service;

/// <summary>Runs the enforcer: a 1-second tick loop and a sync loop.</summary>
internal sealed class EnforcerWorker(Enforcer enforcer, ILogger<EnforcerWorker> log) : BackgroundService
{
    protected override Task ExecuteAsync(CancellationToken stoppingToken) =>
        Task.WhenAll(TickLoopAsync(stoppingToken), SyncLoopAsync(stoppingToken));

    private async Task TickLoopAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        while (await WaitAsync(timer, ct).ConfigureAwait(false))
        {
            try
            {
                enforcer.Tick();
            }
            catch (Exception e)
            {
                log.LogError(e, "Enforcer tick failed");
            }
        }
    }

    private async Task SyncLoopAsync(CancellationToken ct)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(5));
        do
        {
            try
            {
                await enforcer.SyncDueAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception e)
            {
                log.LogError(e, "Sync loop failed");
            }
        }
        while (await WaitAsync(timer, ct).ConfigureAwait(false));
    }

    private static async Task<bool> WaitAsync(PeriodicTimer timer, CancellationToken ct)
    {
        try
        {
            return await timer.WaitForNextTickAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        await base.StopAsync(cancellationToken).ConfigureAwait(false);
        enforcer.Flush();
    }
}
