using System.Diagnostics;
using System.ServiceProcess;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace DigitalRewards.Service;

/// <summary>
/// Runs from the new version's folder (<c>DigitalRewards.Service.exe --apply-update &lt;from&gt; &lt;to&gt;</c>)
/// as SYSTEM: stops the service, backs up the install folder, copies the new files in, locks down
/// appsettings.json again and restarts the service. If anything fails it restores the backup.
/// Progress goes to %ProgramData%\DigitalRewards\update.log.
/// </summary>
internal static class UpdateApplier
{
    public const string Argument = "--apply-update";
    private const string ServiceName = "DigitalRewards";

    public static int Run(string from, string to)
    {
        var log = Path.Combine(SecureStorage.Root, "update.log");
        void Log(string message) =>
            File.AppendAllText(log, $"{DateTimeOffset.Now:u} {message}{Environment.NewLine}");

        var backup = Path.Combine(SecureStorage.Root, "updates", "backup");
        try
        {
            Log($"Applying update from {from} to {to}.");
            using var service = new ServiceController(ServiceName);
            StopService(service);
            foreach (var tray in Process.GetProcessesByName("DigitalRewards.Tray"))
            {
                try { tray.Kill(); tray.WaitForExit(5000); } catch { /* already gone */ }
            }

            if (Directory.Exists(backup))
            {
                Directory.Delete(backup, recursive: true);
            }
            CopyTree(to, backup);
            try
            {
                CopyTree(from, to);
                KeepCloudKitSettings(Path.Combine(backup, "appsettings.json"), Path.Combine(to, "appsettings.json"));
                RestrictSettings(to);
                Log("Files updated.");
            }
            catch (Exception e)
            {
                Log($"Copy failed, restoring backup: {e.Message}");
                CopyTree(backup, to);
                RestrictSettings(to);
            }
            StartService(service);
            Log("Service restarted.");
            return 0;
        }
        catch (Exception e)
        {
            Log($"Update failed: {e}");
            try
            {
                using var service = new ServiceController(ServiceName);
                StartService(service);
            }
            catch
            {
                // Recovery options in the service configuration restart it on failure anyway.
            }
            return 1;
        }
    }

    private static void StopService(ServiceController service)
    {
        service.Refresh();
        if (service.Status != ServiceControllerStatus.Stopped)
        {
            service.Stop();
            service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(60));
        }
        // Give the process a moment to release its files.
        Thread.Sleep(2000);
    }

    private static void StartService(ServiceController service)
    {
        service.Refresh();
        if (service.Status == ServiceControllerStatus.Stopped)
        {
            service.Start();
        }
    }

    private static void CopyTree(string from, string to)
    {
        foreach (var dir in Directory.EnumerateDirectories(from, "*", SearchOption.AllDirectories))
        {
            Directory.CreateDirectory(Path.Combine(to, Path.GetRelativePath(from, dir)));
        }
        Directory.CreateDirectory(to);
        foreach (var file in Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories))
        {
            var target = Path.Combine(to, Path.GetRelativePath(from, file));
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    File.Copy(file, target, overwrite: true);
                    break;
                }
                catch (IOException) when (attempt < 10)
                {
                    Thread.Sleep(1000); // a file still held open by a process that's exiting
                }
            }
        }
    }

    /// <summary>
    /// Release packages are public, so they ship without the CloudKit API token. Carry this PC's token
    /// and environment over from the previous settings whenever the new file leaves them blank.
    /// </summary>
    internal static void KeepCloudKitSettings(string previousPath, string newPath)
    {
        if (!File.Exists(previousPath) || !File.Exists(newPath))
        {
            return;
        }
        var previous = JsonNode.Parse(File.ReadAllText(previousPath))?["CloudKit"];
        var updated = JsonNode.Parse(File.ReadAllText(newPath));
        if (previous is null || updated?["CloudKit"] is not JsonObject cloudKit)
        {
            return;
        }
        foreach (var key in new[] { "ApiToken", "Environment", "ContainerId" })
        {
            var current = cloudKit[key]?.GetValue<string>();
            if ((string.IsNullOrEmpty(current) || current.StartsWith("REPLACE_WITH", StringComparison.Ordinal))
                && previous[key]?.GetValue<string>() is { Length: > 0 } kept)
            {
                cloudKit[key] = kept;
            }
        }
        File.WriteAllText(newPath, updated.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>appsettings.json holds the API token: only SYSTEM and Administrators may read it.</summary>
    private static void RestrictSettings(string folder)
    {
        var settings = Path.Combine(folder, "appsettings.json");
        if (!File.Exists(settings))
        {
            return;
        }
        using var icacls = Process.Start(new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.SystemDirectory, "icacls.exe"),
            ArgumentList = { settings, "/inheritance:r", "/grant:r", "*S-1-5-18:F", "*S-1-5-32-544:F" },
            UseShellExecute = false,
            CreateNoWindow = true,
        });
        icacls?.WaitForExit(30_000);
    }
}
