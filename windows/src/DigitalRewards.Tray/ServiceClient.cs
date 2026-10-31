using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using DigitalRewards.Enforcement;

namespace DigitalRewards.Tray;

/// <summary>Talks to the Go AFK service over its named pipe (one request per connection).</summary>
internal static class ServiceClient
{
    public static async Task<AgentResponse> SendAsync(AgentRequest request, TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await using var pipe = new NamedPipeClientStream(".", AgentProtocol.PipeName, PipeDirection.InOut,
                PipeOptions.Asynchronous, TokenImpersonationLevel.Identification);
            await pipe.ConnectAsync(cts.Token).ConfigureAwait(false);
            var bytes = Encoding.UTF8.GetBytes(AgentProtocol.Serialize(request) + "\n");
            await pipe.WriteAsync(bytes, cts.Token).ConfigureAwait(false);
            await pipe.FlushAsync(cts.Token).ConfigureAwait(false);
            using var reader = new StreamReader(pipe, Encoding.UTF8);
            var line = await reader.ReadLineAsync(cts.Token).ConfigureAwait(false);
            return line is null
                ? AgentResponse.Fail("No answer from the Go AFK service.")
                : AgentProtocol.Deserialize<AgentResponse>(line) ?? AgentResponse.Fail("Bad answer from the service.");
        }
        catch (Exception e) when (e is IOException or OperationCanceledException or TimeoutException or UnauthorizedAccessException)
        {
            return AgentResponse.Fail("The Go AFK service isn't running.");
        }
    }
}
