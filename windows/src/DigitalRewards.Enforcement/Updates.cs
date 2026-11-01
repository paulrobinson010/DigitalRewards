using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DigitalRewards.Enforcement;

public sealed class UpdateOptions
{
    /// <summary>"owner/repo" whose GitHub Releases carry the Windows packages.</summary>
    public string Repository { get; set; } = "";

    /// <summary>PEM public key (ECDSA P-256) that signs update.json. Updates are off without it.</summary>
    public string PublicKey { get; set; } = "";

    public double CheckIntervalHours { get; set; } = 6;

    public bool Enabled { get; set; } = true;

    public const string TagPrefix = "windows-v";
    public const string ManifestAsset = "update.json";
    public const string SignatureAsset = "update.json.sig";

    public bool IsConfigured => Enabled && Repository.Contains('/') && PublicKey.Contains("PUBLIC KEY");
}

/// <summary>update.json: what a release contains, signed by the build.</summary>
public sealed record UpdateManifest(
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("asset")] string Asset,
    [property: JsonPropertyName("sha256")] string Sha256,
    [property: JsonPropertyName("size")] long Size);

/// <summary>A verified newer release, ready to download.</summary>
public sealed record UpdateCandidate(Version Version, UpdateManifest Manifest, Uri PackageUrl);

public static class UpdateSignature
{
    /// <summary>ECDSA P-256 / SHA-256 over the exact manifest bytes (IEEE P1363 signature, base64).</summary>
    public static bool Verify(byte[] manifest, string signatureBase64, string publicKeyPem)
    {
        try
        {
            using var ecdsa = ECDsa.Create();
            ecdsa.ImportFromPem(publicKeyPem);
            var signature = Convert.FromBase64String(signatureBase64.Trim());
            return ecdsa.VerifyData(manifest, signature, HashAlgorithmName.SHA256);
        }
        catch (Exception e) when (e is FormatException or CryptographicException or ArgumentException)
        {
            return false;
        }
    }
}

/// <summary>
/// Looks for a newer signed Windows release on GitHub and downloads it. Nothing is trusted until
/// the manifest's signature checks out against the configured public key, and the package's size
/// and SHA-256 match the manifest.
/// </summary>
public sealed class UpdateChecker(HttpClient http, UpdateOptions options)
{
    public async Task<UpdateCandidate?> FindAsync(Version current, CancellationToken ct)
    {
        if (!options.IsConfigured)
        {
            return null;
        }
        current = Normalize(current);
        var releases = await GetJsonAsync<List<GitHubRelease>>(
            $"https://api.github.com/repos/{options.Repository}/releases?per_page=20", ct) ?? [];
        var release = releases
            .Where(r => !r.Draft && !r.Prerelease && r.TagName.StartsWith(UpdateOptions.TagPrefix, StringComparison.Ordinal))
            .Select(r => (Release: r, Version: ParseVersion(r.TagName[UpdateOptions.TagPrefix.Length..])))
            .Where(x => x.Version is not null)
            .OrderByDescending(x => x.Version)
            .FirstOrDefault();
        if (release.Release is null || release.Version! <= current)
        {
            return null;
        }

        var manifestUrl = AssetUrl(release.Release, UpdateOptions.ManifestAsset);
        var signatureUrl = AssetUrl(release.Release, UpdateOptions.SignatureAsset);
        if (manifestUrl is null || signatureUrl is null)
        {
            return null;
        }
        var manifestBytes = await http.GetByteArrayAsync(manifestUrl, ct);
        var signature = await http.GetStringAsync(signatureUrl, ct);
        if (!UpdateSignature.Verify(manifestBytes, signature, options.PublicKey))
        {
            throw new UpdateException($"Release {release.Release.TagName} has a bad signature; ignoring it.");
        }
        var manifest = JsonSerializer.Deserialize<UpdateManifest>(manifestBytes)
            ?? throw new UpdateException("Empty update manifest.");
        // The signed version is the one that counts, not the tag.
        if (ParseVersion(manifest.Version) is not { } version || version <= current)
        {
            return null;
        }
        var packageUrl = AssetUrl(release.Release, manifest.Asset)
            ?? throw new UpdateException($"Release {release.Release.TagName} has no {manifest.Asset}.");
        return new UpdateCandidate(version, manifest, packageUrl);
    }

    /// <summary>Downloads the package to <paramref name="path"/>; deletes it and throws if it doesn't match.</summary>
    public async Task DownloadAsync(UpdateCandidate candidate, string path, CancellationToken ct)
    {
        using (var response = await http.GetAsync(candidate.PackageUrl, HttpCompletionOption.ResponseHeadersRead, ct))
        {
            response.EnsureSuccessStatusCode();
            await using var file = File.Create(path);
            await response.Content.CopyToAsync(file, ct);
        }
        var info = new FileInfo(path);
        string hash;
        await using (var file = File.OpenRead(path))
        {
            hash = Convert.ToHexString(await SHA256.HashDataAsync(file, ct)).ToLowerInvariant();
        }
        if (info.Length != candidate.Manifest.Size || !hash.Equals(candidate.Manifest.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(path);
            throw new UpdateException($"Downloaded package for {candidate.Version} doesn't match its manifest.");
        }
    }

    public static Version? ParseVersion(string text) =>
        Version.TryParse(text.Trim().TrimStart('v'), out var v) ? Normalize(v) : null;

    /// <summary>Treats missing parts as 0 so 1.0.5 and 1.0.5.0 compare equal.</summary>
    public static Version Normalize(Version v) =>
        new(v.Major, Math.Max(v.Minor, 0), Math.Max(v.Build, 0), Math.Max(v.Revision, 0));

    private static Uri? AssetUrl(GitHubRelease release, string name) =>
        release.Assets.FirstOrDefault(a => a.Name == name)?.BrowserDownloadUrl is { } url ? new Uri(url) : null;

    private async Task<T?> GetJsonAsync<T>(string url, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd("GoAFK-Updater");
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var response = await http.SendAsync(request, ct);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<T>(ct);
    }

    private sealed class GitHubRelease
    {
        [JsonPropertyName("tag_name")] public string TagName { get; set; } = "";
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public List<GitHubAsset> Assets { get; set; } = [];
    }

    private sealed class GitHubAsset
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("browser_download_url")] public string? BrowserDownloadUrl { get; set; }
    }
}

public sealed class UpdateException(string message) : Exception(message);
