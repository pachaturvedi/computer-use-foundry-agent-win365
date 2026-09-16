using System.Text;
using Microsoft.AspNetCore.Http;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class ResponseRequestTests
{
    [Theory]
    [InlineData("/responses")]
    [InlineData("/responses/")]
    [InlineData("/v1/RESPONSES/")]
    public void CreateRouteVariationsAreGuarded(string path)
    {
        var context = new DefaultHttpContext();
        context.Request.Path = path;
        context.Request.Method = "POST";
        Assert.True(ResponseRequest.IsCreate(context.Request));
        context.Request.Method = "GET";
        Assert.False(ResponseRequest.IsCreate(context.Request));
    }

    [Theory]
    [InlineData("")]
    [InlineData("{invalid")]
    [InlineData("[]")]
    [InlineData("null")]
    [InlineData("{\"previous_response_id\":\"old\"}")]
    [InlineData("{\"conversation\":\"old\"}")]
    [InlineData("{\"background\":true}")]
    public async Task InvalidOrContinuingRequestsAreRejected(string json)
    {
        var context = Context(json);
        Assert.False(await ResponseRequest.ValidateAsync(context));
        Assert.Equal(400, context.Response.StatusCode);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task OversizedBodyIsRejectedWithOrWithoutContentLength(bool knownLength)
    {
        var context = Context(new string(' ', ResponseRequest.MaxBytes + 1));
        if (knownLength) context.Request.ContentLength = context.Request.Body.Length;
        Assert.False(await ResponseRequest.ValidateAsync(context));
        Assert.Equal(413, context.Response.StatusCode);
    }

    [Fact]
    public async Task MaximumSizeFreshRequestRemainsReadableBySdk()
    {
        var json = "{}".PadRight(ResponseRequest.MaxBytes);
        var context = Context(json);
        Assert.True(await ResponseRequest.ValidateAsync(context));
        Assert.Equal(0, context.Request.Body.Position);
        Assert.Equal(json, await new StreamReader(context.Request.Body).ReadToEndAsync());
    }

    private static DefaultHttpContext Context(string json)
    {
        var context = new DefaultHttpContext();
        context.Request.Body = new MemoryStream(Encoding.UTF8.GetBytes(json));
        context.Response.Body = new MemoryStream();
        return context;
    }
}
