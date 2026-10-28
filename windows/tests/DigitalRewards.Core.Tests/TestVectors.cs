using System.Text.Json;
using DigitalRewards.Core;

namespace DigitalRewards.Core.Tests;

/// <summary>Loads shared/test-vectors/*.json from the repository root.</summary>
public static class TestVectors
{
    public static string Directory { get; } = Locate();

    private static string Locate()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "shared", "test-vectors");
            if (System.IO.Directory.Exists(candidate))
            {
                return candidate;
            }
            dir = dir.Parent;
        }
        throw new DirectoryNotFoundException("Could not find shared/test-vectors above " + AppContext.BaseDirectory);
    }

    public static JsonElement Load(string file) =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(Directory, file))).RootElement;

    public static T As<T>(JsonElement e) => e.Deserialize<T>(ContractJson.Options)!;

    /// <summary>Theory data: one row per case name in the given array.</summary>
    public static TheoryData<string> Names(string file, string arrayProperty)
    {
        var data = new TheoryData<string>();
        foreach (var c in Load(file).GetProperty(arrayProperty).EnumerateArray())
        {
            data.Add(c.GetProperty("name").GetString()!);
        }
        return data;
    }

    public static JsonElement Case(string file, string arrayProperty, string name) =>
        Load(file).GetProperty(arrayProperty).EnumerateArray().Single(c => c.GetProperty("name").GetString() == name);
}
