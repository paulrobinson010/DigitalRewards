using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using DigitalRewards.Enforcement;
using static DigitalRewards.Service.NativeMethods;

namespace DigitalRewards.Service;

/// <summary>
/// Serves the agent protocol on \\.\pipe\DigitalRewards.Agent. The caller's SID and session come
/// from the pipe itself, and (optionally) the caller must be the installed agent executable.
/// </summary>
internal sealed class AgentPipeServer(Enforcer enforcer, AgentPipeOptions options, ILogger<AgentPipeServer> log) : BackgroundService
{
    private const int MaxLineChars = 256 * 1024;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            NamedPipeServerStream pipe;
            try
            {
                pipe = NamedPipeServerStreamAcl.Create(
                    AgentProtocol.PipeName,
                    PipeDirection.InOut,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous,
                    0,
                    0,
                    SecureStorage.AgentPipeSecurity());
            }
            catch (IOException e)
            {
                log.LogError(e, "Couldn't create the agent pipe");
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken).ConfigureAwait(false);
                continue;
            }
            try
            {
                await pipe.WaitForConnectionAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                await pipe.DisposeAsync().ConfigureAwait(false);
                break;
            }
            _ = Task.Run(() => HandleAsync(pipe, stoppingToken), stoppingToken);
        }
    }

    private async Task HandleAsync(NamedPipeServerStream pipe, CancellationToken stoppingToken)
    {
        await using var _ = pipe;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        timeout.CancelAfter(TimeSpan.FromMinutes(2));
        var ct = timeout.Token;
        try
        {
            var line = await ReadLineAsync(pipe, ct).ConfigureAwait(false);
            if (line is null)
            {
                return;
            }
            AgentResponse response;
            var client = Identify(pipe);
            if (client is null)
            {
                response = AgentResponse.Fail("Not allowed.");
            }
            else
            {
                var request = AgentProtocol.Deserialize<AgentRequest>(line);
                response = request is null ? AgentResponse.Fail("Bad request.") : await enforcer.HandleAsync(client, request, ct).ConfigureAwait(false);
            }
            var bytes = Encoding.UTF8.GetBytes(AgentProtocol.Serialize(response) + "\n");
            await pipe.WriteAsync(bytes, ct).ConfigureAwait(false);
            await pipe.FlushAsync(ct).ConfigureAwait(false);
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or System.Text.Json.JsonException)
        {
            log.LogDebug(e, "Agent connection ended");
        }
    }

    private AgentClient? Identify(NamedPipeServerStream pipe)
    {
        var handle = pipe.SafePipeHandle.DangerousGetHandle();
        if (!GetNamedPipeClientSessionId(handle, out var sessionId) || !GetNamedPipeClientProcessId(handle, out var pid))
        {
            return null;
        }
        if (options.VerifyAgentPath)
        {
            var path = ProcessImagePath(pid);
            if (path is null || !string.Equals(Path.GetFullPath(path), Path.GetFullPath(options.AgentPath), StringComparison.OrdinalIgnoreCase))
            {
                log.LogWarning("Rejected agent connection from {Path} (pid {Pid})", path, pid);
                return null;
            }
        }
        string? sid = null;
        pipe.RunAsClient(() =>
        {
            using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
            sid = identity.User?.Value;
        });
        return sid is null ? null : new AgentClient(sid, sessionId);
    }

    private static async Task<string?> ReadLineAsync(Stream stream, CancellationToken ct)
    {
        var sb = new StringBuilder();
        var buffer = new byte[4096];
        var decoder = Encoding.UTF8.GetDecoder();
        var chars = new char[4096];
        while (true)
        {
            var n = await stream.ReadAsync(buffer, ct).ConfigureAwait(false);
            if (n == 0)
            {
                return sb.Length > 0 ? sb.ToString() : null;
            }
            var c = decoder.GetChars(buffer, 0, n, chars, 0);
            for (var i = 0; i < c; i++)
            {
                if (chars[i] == '\n')
                {
                    return sb.ToString();
                }
                sb.Append(chars[i]);
            }
            if (sb.Length > MaxLineChars)
            {
                throw new IOException("Request too large.");
            }
        }
    }
}

internal sealed class AgentPipeOptions
{
    public required string AgentPath { get; init; }
    public bool VerifyAgentPath { get; init; } = true;
}
