using System.Net;
using System.Text.Json;
using System.Web;

namespace DigitalRewards.CloudKit.Tests;

public class CloudKitClientTests
{
    private static JsonElement Body(string? body) => JsonDocument.Parse(body!).RootElement;

    [Fact]
    public void BuildsUrlsWithEncodedTokens()
    {
        var client = FakeHandler.Client(new FakeHandler());
        var uri = client.BuildUri(CloudDatabase.Shared, "records/query");

        Assert.Equal("/database/1/iCloud.com.digitalrewards.app/development/shared/records/query", uri.AbsolutePath);
        var q = HttpUtility.ParseQueryString(uri.Query);
        Assert.Equal("api123", q["ckAPIToken"]);
        Assert.Equal("tok+/=", q["ckWebAuthToken"]);
        Assert.Contains("ckWebAuthToken=tok%2B%2F%3D", uri.AbsoluteUri);
    }

    [Fact]
    public void OmitsWebTokenWhenSignedOut()
    {
        var uri = FakeHandler.Client(new FakeHandler(), token: null).BuildUri(CloudDatabase.Private, "zones/list");
        Assert.DoesNotContain("ckWebAuthToken", uri.Query);
    }

    [Fact]
    public async Task QueryFollowsContinuationMarker()
    {
        var handler = new FakeHandler()
            .Ok("""{"records":[{"recordName":"a","recordType":"Spend","fields":{"minutes":{"value":1,"type":"INT64"}}}],"continuationMarker":"m1"}""")
            .Ok("""{"records":[{"recordName":"b","recordType":"Spend","fields":{"minutes":{"value":2,"type":"INT64"}}}]}""");
        var client = FakeHandler.Client(handler);

        var records = await client.QueryAsync(CloudDatabase.Shared, new ZoneId("Activity-c1", "_mum"), "Spend",
            [new QueryFilter("at", "GREATER_THAN", CloudValue.TimestampMs(5))], [new QuerySort("at")]);

        Assert.Equal(["a", "b"], records.Select(r => r.RecordName));
        Assert.Equal(2, handler.Requests.Count);
        var first = Body(handler.Requests[0].Body);
        Assert.Equal("Activity-c1", first.GetProperty("zoneID").GetProperty("zoneName").GetString());
        Assert.Equal("_mum", first.GetProperty("zoneID").GetProperty("ownerRecordName").GetString());
        Assert.Equal(2, first.GetProperty("resultsLimit").GetInt32());
        Assert.Equal("Spend", first.GetProperty("query").GetProperty("recordType").GetString());
        var filter = first.GetProperty("query").GetProperty("filterBy")[0];
        Assert.Equal("GREATER_THAN", filter.GetProperty("comparator").GetString());
        Assert.Equal("TIMESTAMP", filter.GetProperty("fieldValue").GetProperty("type").GetString());
        Assert.Equal(5, filter.GetProperty("fieldValue").GetProperty("value").GetInt64());
        Assert.False(first.TryGetProperty("continuationMarker", out _));
        Assert.Equal("m1", Body(handler.Requests[1].Body).GetProperty("continuationMarker").GetString());
    }

    [Fact]
    public async Task ZoneChangesPagesUntilNoMoreComingAndKeepsDeletions()
    {
        var handler = new FakeHandler()
            .Ok("""{"zones":[{"zoneID":{"zoneName":"Family-x","ownerRecordName":"_p"},"syncToken":"t1","moreComing":true,"records":[{"recordName":"rules","recordType":"Rules","fields":{}}]}]}""")
            .Ok("""{"zones":[{"zoneID":{"zoneName":"Family-x","ownerRecordName":"_p"},"syncToken":"t2","moreComing":false,"records":[{"recordName":"adjust-1","deleted":true}]}]}""");
        var client = FakeHandler.Client(handler);

        var changes = await client.FetchZoneChangesAsync(CloudDatabase.Shared, new ZoneId("Family-x", "_p"), null);

        Assert.Equal("t2", changes.SyncToken);
        Assert.Equal(2, changes.Records.Count);
        Assert.True(changes.Records[1].Deleted);
        Assert.Contains("/shared/changes/zone", handler.Requests[0].Uri.AbsolutePath);
        var zoneReq = Body(handler.Requests[0].Body).GetProperty("zones")[0];
        Assert.Equal("_p", zoneReq.GetProperty("zoneID").GetProperty("ownerRecordName").GetString());
        Assert.False(zoneReq.TryGetProperty("syncToken", out _));
        Assert.Equal("t1", Body(handler.Requests[1].Body).GetProperty("zones")[0].GetProperty("syncToken").GetString());
    }

    [Fact]
    public async Task ZoneChangesErrorThrowsWithCode()
    {
        var handler = new FakeHandler()
            .Ok("""{"zones":[{"zoneID":{"zoneName":"Activity-c1","ownerRecordName":"_mum"},"serverErrorCode":"CHANGE_TOKEN_EXPIRED","reason":"old"}]}""");
        var e = await Assert.ThrowsAsync<CloudKitException>(() =>
            FakeHandler.Client(handler).FetchZoneChangesAsync(CloudDatabase.Shared, new ZoneId("Activity-c1", "_mum"), "stale"));
        Assert.Equal("CHANGE_TOKEN_EXPIRED", e.ServerErrorCode);
    }

    [Fact]
    public async Task AuthenticationRequiredExposesRedirect()
    {
        var handler = new FakeHandler()
            .Respond((HttpStatusCode)421, """{"uuid":"u","serverErrorCode":"AUTHENTICATION_REQUIRED","reason":"no token","redirectURL":"https://idmsa.apple.com/signin?x=1"}""");
        var e = await Assert.ThrowsAsync<CloudKitAuthenticationRequiredException>(() => FakeHandler.Client(handler).GetCurrentUserRecordNameAsync());
        Assert.Equal("https://idmsa.apple.com/signin?x=1", e.RedirectUrl);
    }

    [Fact]
    public async Task SignInUrlIsFetchedWithoutWebToken()
    {
        var handler = new FakeHandler()
            .Respond((HttpStatusCode)421, """{"serverErrorCode":"AUTHENTICATION_REQUIRED","redirectURL":"https://idmsa.apple.com/x"}""");
        var client = FakeHandler.Client(handler, token: "existing");

        var url = await client.GetSignInUrlAsync();

        Assert.Equal("https://idmsa.apple.com/x", url);
        Assert.DoesNotContain("ckWebAuthToken", handler.Requests[0].Uri.Query);
        Assert.Contains("/public/users/current", handler.Requests[0].Uri.AbsolutePath);
        Assert.Equal("existing", client.WebAuthToken);
    }

    [Fact]
    public async Task RotatedTokenFromHeaderIsAdoptedAndAnnounced()
    {
        var handler = new FakeHandler()
            .Respond(HttpStatusCode.OK, """{"userRecordName":"_child"}""", r => r.Headers.Add("X-Apple-CloudKit-Web-Auth-Token", "new-token"))
            .Ok("""{"userRecordName":"_child"}""");
        var client = FakeHandler.Client(handler, token: "old");
        string? announced = null;
        client.WebAuthTokenChanged += t => announced = t;

        Assert.Equal("_child", await client.GetCurrentUserRecordNameAsync());
        await client.GetCurrentUserRecordNameAsync();

        Assert.Equal("new-token", announced);
        Assert.Equal("new-token", client.WebAuthToken);
        Assert.Equal("new-token", HttpUtility.ParseQueryString(handler.Requests[1].Uri.Query)["ckWebAuthToken"]);
    }

    [Fact]
    public async Task RotatedTokenFromBodyIsAdopted()
    {
        var handler = new FakeHandler().Ok("""{"userRecordName":"_c","ckWebAuthToken":"body-token"}""");
        var client = FakeHandler.Client(handler, token: "old");
        await client.GetCurrentUserRecordNameAsync();
        Assert.Equal("body-token", client.WebAuthToken);
    }

    [Fact]
    public async Task ModifyReportsPerRecordErrors()
    {
        var handler = new FakeHandler().Ok("""
            {"records":[
              {"recordName":"spend-d-202610281700","recordType":"Spend","recordChangeTag":"x","fields":{}},
              {"recordName":"spend-d-202610281701","serverErrorCode":"CONFLICT","reason":"exists"}
            ]}
            """);
        var client = FakeHandler.Client(handler);
        var records = new[]
        {
            new CloudRecord("spend-d-202610281700", "Spend").Set("minutes", 1L),
            new CloudRecord("spend-d-202610281701", "Spend").Set("minutes", 1L),
        };

        var results = await client.ModifyAsync(CloudDatabase.Shared, new ZoneId("Activity-c1", "_mum"), ModifyOperation.Create, records);

        Assert.True(results[0].Succeeded);
        Assert.False(results[1].Succeeded);
        Assert.Equal("CONFLICT", results[1].ServerErrorCode);
        Assert.Contains("/shared/records/modify", handler.Requests[0].Uri.AbsolutePath);
        var body = Body(handler.Requests[0].Body);
        Assert.Equal("_mum", body.GetProperty("zoneID").GetProperty("ownerRecordName").GetString());
        Assert.False(body.GetProperty("atomic").GetBoolean());
        var op = body.GetProperty("operations")[0];
        Assert.Equal("create", op.GetProperty("operationType").GetString());
        Assert.Equal("INT64", op.GetProperty("record").GetProperty("fields").GetProperty("minutes").GetProperty("type").GetString());
    }

    [Fact]
    public async Task ModifyWithNothingSendsNothing()
    {
        var handler = new FakeHandler();
        var results = await FakeHandler.Client(handler).ModifyAsync(CloudDatabase.Shared, new ZoneId("Activity-c1", "_mum"), ModifyOperation.Create, []);
        Assert.Empty(results);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task HttpErrorsCarryServerCode()
    {
        var handler = new FakeHandler().Respond(HttpStatusCode.BadRequest, """{"serverErrorCode":"BAD_REQUEST","reason":"nope"}""");
        var e = await Assert.ThrowsAsync<CloudKitException>(() => FakeHandler.Client(handler).ListZonesAsync(CloudDatabase.Shared));
        Assert.Equal("BAD_REQUEST", e.ServerErrorCode);
        Assert.Equal(HttpStatusCode.BadRequest, e.Status);
    }

    [Fact]
    public async Task ListsZonesWithOwners()
    {
        var handler = new FakeHandler().Ok("""{"zones":[{"zoneID":{"zoneName":"Family-1","ownerRecordName":"_mum"},"syncToken":"s"}]}""");
        var zones = await FakeHandler.Client(handler).ListZonesAsync(CloudDatabase.Shared);
        Assert.Equal(new ZoneId("Family-1", "_mum"), Assert.Single(zones).ZoneId);
        Assert.Equal(HttpMethod.Get, handler.Requests[0].Method);
    }

    [Fact]
    public async Task LookupReturnsRecordsAndMisses()
    {
        var handler = new FakeHandler().Ok("""{"records":[{"recordName":"child","recordType":"Child","fields":{"name":{"value":"Sam","type":"STRING"}}},{"recordName":"x","serverErrorCode":"NOT_FOUND"}]}""");
        var results = await FakeHandler.Client(handler).LookupAsync(CloudDatabase.Shared, new ZoneId("Family-1", "_mum"), ["child", "x"]);
        Assert.Equal("Sam", results[0].Record!.GetString("name"));
        Assert.Equal("NOT_FOUND", results[1].ServerErrorCode);
    }
}
