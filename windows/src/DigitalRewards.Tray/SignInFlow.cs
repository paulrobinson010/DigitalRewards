using System.Diagnostics;
using System.Net;
using System.Text;
using System.Web;
using DigitalRewards.Enforcement;

namespace DigitalRewards.Tray;

/// <summary>
/// iCloud sign-in: ask the service for Apple's sign-in URL, open it in the browser, and catch the
/// redirect to http://localhost:43117/ck-callback carrying the ckWebAuthToken.
/// </summary>
internal static class SignInFlow
{
    public const int CallbackPort = 43117;
    private const string CallbackPath = "/ck-callback";

    /// <summary>Token parameter names CloudKit may use on the redirect.</summary>
    private static readonly string[] TokenParams = ["ckWebAuthToken", "ckwebauthtoken", "ckSession"];

    /// <summary>If CloudKit puts the token in the URL fragment, this page moves it to the query so we can read it.</summary>
    private const string FragmentRelay = """
        <!doctype html><meta charset="utf-8"><title>DigitalRewards</title>
        <script>
          if (location.hash.length > 1) { location.replace(location.pathname + '?' + location.hash.substring(1)); }
          else { document.write('Sign-in didn\'t return a token. Close this window and try again.'); }
        </script>
        """;

    private const string Done = """
        <!doctype html><meta charset="utf-8"><title>DigitalRewards</title>
        <body style="font-family:Segoe UI,sans-serif;text-align:center;margin-top:20vh">
        <h2>You're signed in to DigitalRewards.</h2><p>You can close this window.</p></body>
        """;

    public static async Task<AgentResponse> RunAsync(CancellationToken ct)
    {
        var begin = await ServiceClient.SendAsync(new AgentRequest { Type = AgentRequestType.BeginSignIn }, TimeSpan.FromSeconds(30)).ConfigureAwait(false);
        if (!begin.Ok || string.IsNullOrEmpty(begin.SignInUrl))
        {
            return begin.Ok ? AgentResponse.Fail("Couldn't start iCloud sign-in.") : begin;
        }

        using var listener = new HttpListener();
        listener.Prefixes.Add($"http://localhost:{CallbackPort}/");
        try
        {
            listener.Start();
        }
        catch (HttpListenerException)
        {
            return AgentResponse.Fail($"Port {CallbackPort} is busy. Close other sign-in windows and try again.");
        }

        Process.Start(new ProcessStartInfo(begin.SignInUrl) { UseShellExecute = true });

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromMinutes(10));
        using var reg = timeout.Token.Register(listener.Stop);
        try
        {
            while (true)
            {
                var context = await listener.GetContextAsync().ConfigureAwait(false);
                var url = context.Request.Url;
                if (url is null || !url.AbsolutePath.Equals(CallbackPath, StringComparison.OrdinalIgnoreCase))
                {
                    await RespondAsync(context, 404, "Not found").ConfigureAwait(false);
                    continue;
                }
                var query = HttpUtility.ParseQueryString(url.Query);
                var token = TokenParams.Select(p => query[p]).FirstOrDefault(t => !string.IsNullOrEmpty(t));
                if (token is null)
                {
                    await RespondAsync(context, 200, FragmentRelay).ConfigureAwait(false);
                    continue;
                }
                var result = await ServiceClient.SendAsync(new AgentRequest { Type = AgentRequestType.CompleteSignIn, Token = token }, TimeSpan.FromSeconds(60))
                    .ConfigureAwait(false);
                await RespondAsync(context, 200, result.Ok ? Done : Page(result.Error ?? "Sign-in failed.")).ConfigureAwait(false);
                return result;
            }
        }
        catch (Exception e) when (e is HttpListenerException or ObjectDisposedException or OperationCanceledException)
        {
            return AgentResponse.Fail("Sign-in timed out.");
        }
    }

    private static string Page(string message) =>
        $"<!doctype html><meta charset=\"utf-8\"><body style=\"font-family:Segoe UI,sans-serif;text-align:center;margin-top:20vh\"><h2>{WebUtility.HtmlEncode(message)}</h2></body>";

    private static async Task RespondAsync(HttpListenerContext context, int status, string html)
    {
        var bytes = Encoding.UTF8.GetBytes(html);
        context.Response.StatusCode = status;
        context.Response.ContentType = "text/html; charset=utf-8";
        context.Response.ContentLength64 = bytes.Length;
        await context.Response.OutputStream.WriteAsync(bytes).ConfigureAwait(false);
        context.Response.Close();
    }
}
