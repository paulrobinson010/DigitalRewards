using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DigitalRewards.Enforcement;

namespace DigitalRewards.Enforcement.Tests;

public class UpdateTests : IDisposable
{
    private readonly ECDsa _key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    private readonly Dictionary<string, byte[]> _files = new();
    private readonly string _temp = Path.Combine(Path.GetTempPath(), "goafk-update-tests-" + Guid.NewGuid().ToString("N"));
    private static readonly byte[] Package = Encoding.UTF8.GetBytes("pretend zip contents");

    public UpdateTests() => Directory.CreateDirectory(_temp);

    public void Dispose()
    {
        _key.Dispose();
        Directory.Delete(_temp, recursive: true);
    }

    private UpdateOptions Options(ECDsa? key = null) => new()
    {
        Repository = "owner/repo",
        PublicKey = (key ?? _key).ExportSubjectPublicKeyInfoPem(),
    };

    private UpdateChecker Checker(UpdateOptions? options = null) =>
        new(new HttpClient(new FilesHandler(_files)), options ?? Options());

    /// <summary>Publishes a release the way the GitHub workflow does.</summary>
    private void Publish(string tag, string version, byte[]? package = null, ECDsa? signer = null, bool draft = false)
    {
        package ??= Package;
        var manifest = JsonSerializer.SerializeToUtf8Bytes(new
        {
            version,
            asset = "GoAFK-Windows-production.zip",
            sha256 = Convert.ToHexString(SHA256.HashData(Package)).ToLowerInvariant(),
            size = (long)Package.Length,
        });
        var signature = Convert.ToBase64String((signer ?? _key).SignData(manifest, HashAlgorithmName.SHA256));
        var baseUrl = $"https://github.com/owner/repo/releases/download/{tag}/";
        _files[baseUrl + "update.json"] = manifest;
        _files[baseUrl + "update.json.sig"] = Encoding.UTF8.GetBytes(signature);
        _files[baseUrl + "GoAFK-Windows-production.zip"] = package;

        var list = _files.TryGetValue(ReleasesUrl, out var existing)
            ? JsonSerializer.Deserialize<List<object>>(existing)!
            : [];
        list.Add(new
        {
            tag_name = tag,
            draft,
            prerelease = false,
            assets = new[] { "update.json", "update.json.sig", "GoAFK-Windows-production.zip" }
                .Select(n => new { name = n, browser_download_url = baseUrl + n }),
        });
        _files[ReleasesUrl] = JsonSerializer.SerializeToUtf8Bytes(list);
    }

    private const string ReleasesUrl = "https://api.github.com/repos/owner/repo/releases?per_page=20";

    [Fact]
    public async Task FindsNewestSignedReleaseAndDownloadsIt()
    {
        Publish("windows-v1.0.40", "1.0.40");
        Publish("windows-v1.0.42", "1.0.42");
        Publish("windows-v1.0.50", "1.0.50", draft: true);
        Publish("ios-v9.9.9", "9.9.9");

        var candidate = await Checker().FindAsync(new Version(1, 0, 30), default);

        Assert.NotNull(candidate);
        Assert.Equal(new Version(1, 0, 42, 0), candidate!.Version);
        var path = Path.Combine(_temp, "pkg.zip");
        await Checker().DownloadAsync(candidate, path, default);
        Assert.Equal(Package, File.ReadAllBytes(path));
    }

    [Fact]
    public async Task NothingWhenAlreadyCurrentOrNewer()
    {
        Publish("windows-v1.0.42", "1.0.42");
        Assert.Null(await Checker().FindAsync(new Version(1, 0, 42), default));
        Assert.Null(await Checker().FindAsync(new Version(1, 0, 43), default));
    }

    [Fact]
    public async Task RejectsReleaseSignedWithAnotherKey()
    {
        using var attacker = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        Publish("windows-v1.0.42", "1.0.42", signer: attacker);
        await Assert.ThrowsAsync<UpdateException>(() => Checker().FindAsync(new Version(1, 0, 1), default));
    }

    [Fact]
    public async Task RejectsTamperedPackage()
    {
        Publish("windows-v1.0.42", "1.0.42", package: Encoding.UTF8.GetBytes("evil contents!!!!!!!"));
        var candidate = await Checker().FindAsync(new Version(1, 0, 1), default);
        var path = Path.Combine(_temp, "pkg.zip");
        await Assert.ThrowsAsync<UpdateException>(() => Checker().DownloadAsync(candidate!, path, default));
        Assert.False(File.Exists(path));
    }

    [Fact]
    public async Task OffWithoutPublicKey()
    {
        Publish("windows-v1.0.42", "1.0.42");
        Assert.Null(await Checker(new UpdateOptions { Repository = "owner/repo" }).FindAsync(new Version(1, 0, 1), default));
    }

    [Fact]
    public void VersionsCompareWithMissingParts()
    {
        Assert.Equal(UpdateChecker.ParseVersion("1.0.5"), UpdateChecker.Normalize(new Version(1, 0, 5, 0)));
        Assert.True(UpdateChecker.ParseVersion("1.0.10") > UpdateChecker.ParseVersion("1.0.9"));
        Assert.Null(UpdateChecker.ParseVersion("not-a-version"));
    }

    private sealed class FilesHandler(Dictionary<string, byte[]> files) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(files.TryGetValue(request.RequestUri!.ToString(), out var body)
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(body) }
                : new HttpResponseMessage(HttpStatusCode.NotFound));
    }
}
