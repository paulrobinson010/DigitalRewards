using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using DigitalRewards.Enforcement;

namespace DigitalRewards.Service;

/// <summary>DPAPI, machine scope. The state directory ACL keeps other users out.</summary>
internal sealed class DpapiProtector : IDataProtector
{
    private static readonly byte[] Entropy = "DigitalRewards.State.v1"u8.ToArray();

    public byte[] Protect(byte[] data) => ProtectedData.Protect(data, Entropy, DataProtectionScope.LocalMachine);

    public byte[] Unprotect(byte[] data) => ProtectedData.Unprotect(data, Entropy, DataProtectionScope.LocalMachine);
}

internal static class SecureStorage
{
    public static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "DigitalRewards");

    /// <summary>Creates a directory only SYSTEM and Administrators can read or write.</summary>
    public static string EnsurePrivateDirectory(string path)
    {
        var dir = Directory.CreateDirectory(path);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
        {
            security.AddAccessRule(new FileSystemAccessRule(
                new SecurityIdentifier(sid, null),
                FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None,
                AccessControlType.Allow));
        }
        dir.SetAccessControl(security);
        return path;
    }

    /// <summary>A stable id for this PC, created on first run.</summary>
    public static string DeviceId(string root)
    {
        var file = Path.Combine(root, "device-id");
        if (File.Exists(file))
        {
            var existing = File.ReadAllText(file).Trim();
            if (existing.Length > 0)
            {
                return existing;
            }
        }
        var id = Guid.NewGuid().ToString("N");
        File.WriteAllText(file, id);
        return id;
    }

    /// <summary>Signed-in users may connect and talk; only SYSTEM/Administrators may create pipe instances.</summary>
    public static PipeSecurity AgentPipeSecurity()
    {
        var ps = new PipeSecurity();
        ps.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        ps.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        ps.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        return ps;
    }
}
