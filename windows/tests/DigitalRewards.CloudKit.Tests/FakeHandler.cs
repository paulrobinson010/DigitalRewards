using System.Net;
using System.Text;

namespace DigitalRewards.CloudKit.Tests;

/// <summary>Replays canned responses and records requests.</summary>
public sealed class FakeHandler : HttpMessageHandler
{
    private readonly Queue<Func<HttpRequestMessage, HttpResponseMessage>> _responses = new();

    public List<(HttpMethod Method, Uri Uri, string? Body)> Requests { get; } = [];

    public FakeHandler Respond(HttpStatusCode status, string json, Action<HttpResponseMessage>? configure = null)
    {
        _responses.Enqueue(_ =>
        {
            var r = new HttpResponseMessage(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
            configure?.Invoke(r);
            return r;
        });
        return this;
    }

    public FakeHandler Ok(string json) => Respond(HttpStatusCode.OK, json);

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
        Requests.Add((request.Method, request.RequestUri!, body));
        if (_responses.Count == 0)
        {
            throw new InvalidOperationException("No canned response for " + request.RequestUri);
        }
        return _responses.Dequeue()(request);
    }

    public static CloudKitClient Client(FakeHandler handler, string? token = "tok+/=") =>
        new(new HttpClient(handler), new CloudKitOptions
        {
            ContainerId = "iCloud.com.digitalrewards.app",
            Environment = "development",
            ApiToken = "api123",
            PageSize = 2,
        }, token);
}
