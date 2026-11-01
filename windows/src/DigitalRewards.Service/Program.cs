using DigitalRewards.CloudKit;
using DigitalRewards.Enforcement;
using DigitalRewards.Service;
using Microsoft.Extensions.Options;

if (args.Length == 3 && args[0] == UpdateApplier.Argument)
{
    return UpdateApplier.Run(args[1], args[2]);
}

var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
});
builder.Services.AddWindowsService(o => o.ServiceName = "DigitalRewards");

builder.Services.Configure<CloudKitOptions>(builder.Configuration.GetSection("CloudKit"));
builder.Services.AddHttpClient("cloudkit", c => c.Timeout = TimeSpan.FromSeconds(30));
builder.Services.AddHttpClient("updates", c => c.Timeout = TimeSpan.FromMinutes(10));

var root = SecureStorage.EnsurePrivateDirectory(SecureStorage.Root);
var deviceId = SecureStorage.DeviceId(root);
var enforcerConfig = builder.Configuration.GetSection("Enforcer");
var agentPath = enforcerConfig["AgentPath"] is { Length: > 0 } configured
    ? configured
    : Path.Combine(AppContext.BaseDirectory, "DigitalRewards.Tray.exe");

builder.Services.AddSingleton<IStateStore>(_ => new FileStateStore(Path.Combine(root, "accounts"), new DpapiProtector()));
builder.Services.AddSingleton<ICloudGatewayFactory>(sp => new CloudGatewayFactory(
    sp.GetRequiredService<IHttpClientFactory>().CreateClient("cloudkit"),
    sp.GetRequiredService<IOptions<CloudKitOptions>>().Value));
builder.Services.AddSingleton<ISessionProvider, WindowsSessionProvider>();
builder.Services.AddSingleton<IProcessController, WindowsProcessController>();
builder.Services.AddSingleton<IAgentLauncher>(_ => new WindowsAgentLauncher(agentPath));
builder.Services.AddSingleton<IAppCatalog, WindowsAppCatalog>();
builder.Services.AddSingleton(new EnforcerOptions
{
    DeviceId = deviceId,
    SystemRoot = Environment.GetEnvironmentVariable("SystemRoot"),
    OfflineLimit = TimeSpan.FromHours(enforcerConfig.GetValue("OfflineLimitHours", 24.0)),
    SyncInterval = TimeSpan.FromSeconds(enforcerConfig.GetValue("SyncIntervalSeconds", 30.0)),
    HeartbeatInterval = TimeSpan.FromMinutes(enforcerConfig.GetValue("HeartbeatMinutes", 5.0)),
});
builder.Services.AddSingleton(sp => new Enforcer(
    sp.GetRequiredService<IStateStore>(),
    sp.GetRequiredService<ICloudGatewayFactory>(),
    sp.GetRequiredService<ISessionProvider>(),
    sp.GetRequiredService<IProcessController>(),
    sp.GetRequiredService<IAgentLauncher>(),
    sp.GetRequiredService<IAppCatalog>(),
    sp.GetRequiredService<EnforcerOptions>(),
    TimeProvider.System,
    sp.GetRequiredService<ILogger<Enforcer>>()));
builder.Services.AddSingleton(new AgentPipeOptions
{
    AgentPath = agentPath,
    VerifyAgentPath = enforcerConfig.GetValue("VerifyAgentPath", true),
});
var updateOptions = builder.Configuration.GetSection("Update").Get<UpdateOptions>() ?? new UpdateOptions();
builder.Services.AddSingleton(updateOptions);
builder.Services.AddSingleton(sp => new UpdateChecker(
    sp.GetRequiredService<IHttpClientFactory>().CreateClient("updates"), updateOptions));
builder.Services.AddHostedService<UpdateWorker>();
builder.Services.AddHostedService<EnforcerWorker>();
builder.Services.AddHostedService<AgentPipeServer>();

builder.Build().Run();
return 0;
