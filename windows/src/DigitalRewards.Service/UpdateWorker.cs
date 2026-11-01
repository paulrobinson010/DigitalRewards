using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using DigitalRewards.Enforcement;

namespace DigitalRewards.Service;

/// <summary>
/// Checks GitHub Releases for a newer signed build a few minutes after start and then every few
/// hours. A verified package is unzipped into the private updates folder and handed to its own
/// service executable in <c>--apply-update</c> mode, which stops this service, swaps the files
/// and starts it again (see <see cref="UpdateApplier"/>).
/// </summary>
internal sealed class UpdateWorker(UpdateChecker checker, UpdateOptions options, ILogger<UpdateWorker> log) : BackgroundService
{
    private static readonly TimeSpan FirstCheckDelay = TimeSpan.FromMinutes(5);

    public static Version CurrentVersion =>
        UpdateChecker.Normalize(Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 0));

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!options.IsConfigured)
        {
            log.LogInformation("Automatic updates are off (no repository or public key configured).");
            return;
        }
        log.LogInformation("Automatic updates on: version {Version}, checking {Repo}.", CurrentVersion, options.Repository);
        try
        {
            await Task.Delay(FirstCheckDelay, stoppingToken);
            using var timer = new PeriodicTimer(TimeSpan.FromHours(Math.Max(1, options.CheckIntervalHours)));
            do
            {
                if (await TryUpdateAsync(stoppingToken))
                {
                    return; // The applier is about to stop this service.
                }
            }
            while (await timer.WaitForNextTickAsync(stoppingToken));
        }
        catch (OperationCanceledException)
        {
        }
    }

    private async Task<bool> TryUpdateAsync(CancellationToken ct)
    {
        try
        {
            var candidate = await checker.FindAsync(CurrentVersion, ct);
            if (candidate is null)
            {
                return false;
            }
            log.LogInformation("Update {Version} found; downloading.", candidate.Version);

            var updates = Path.Combine(SecureStorage.Root, "updates");
            if (Directory.Exists(updates))
            {
                Directory.Delete(updates, recursive: true); // stale downloads and old backups
            }
            Directory.CreateDirectory(updates);
            var zip = Path.Combine(updates, $"{candidate.Version}.zip");
            await checker.DownloadAsync(candidate, zip, ct);

            var staging = Path.Combine(updates, candidate.Version.ToString());
            ZipFile.ExtractToDirectory(zip, staging);
            var app = Path.Combine(staging, "app");
            var exe = Path.Combine(app, "DigitalRewards.Service.exe");
            if (!File.Exists(exe))
            {
                throw new UpdateException($"Package {candidate.Version} has no app\\DigitalRewards.Service.exe.");
            }

            log.LogInformation("Applying update {Version}.", candidate.Version);
            Process.Start(new ProcessStartInfo
            {
                FileName = exe,
                ArgumentList = { UpdateApplier.Argument, app, AppContext.BaseDirectory },
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = app,
            });
            return true;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception e)
        {
            log.LogWarning(e, "Update check failed; will try again later.");
            return false;
        }
    }
}
