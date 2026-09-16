using Microsoft.Extensions.Configuration;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class SettingsTests
{
    private static Settings Config(Dictionary<string, string?> values) =>
        new(new ConfigurationBuilder().AddInMemoryCollection(values).Build());

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void BootstrapNeedsNoIdentityModelOrViewerConfiguration(bool viewer)
    {
        var settings = Config([]);
        Assert.False(settings.Enabled);
        settings.Validate(viewer);
    }

    [Fact]
    public void BootstrapPortMatchesFoundryContract()
    {
        Assert.Equal(8088, Config([]).HostedPort);
        Assert.Equal(9000, Config(new() { ["PORT"] = "9000" }).HostedPort);
        Assert.Throws<InvalidOperationException>(() => Config(new() { ["PORT"] = "invalid" }).HostedPort);
    }

    [Fact]
    public void EnabledRequiresPostDeploymentConfiguration() =>
        Assert.Throws<InvalidOperationException>(() => Config(new() { ["W365_ENABLED"] = "true" }).Validate());

    [Fact]
    public void LocalCredentialsCannotImpersonateFoundry() =>
        Assert.Throws<InvalidOperationException>(() => Config(new() {
            ["W365_ENABLED"] = "true", ["SAMPLE_LOCAL_MODE"] = "true" }).Validate());

    [Theory]
    [InlineData("W365_CERTIFICATE_PATH")]
    [InlineData("W365_CERTIFICATE_PASSWORD")]
    [InlineData("W365_CLIENT_SECRET")]
    public void LegacyBlueprintCredentialsAreExplicitlyRejected(string key) =>
        Assert.Throws<InvalidOperationException>(() => Config(new() { [key] = "obsolete" }).Validate());

    [Fact]
    public void MisspelledEnableFlagDoesNotSilentlyDisableDesktop() =>
        Assert.Throws<InvalidOperationException>(() => Config(new() { ["W365_ENABLED"] = "tru" }).Validate());

    [Fact]
    public void WrongFoundryBlueprintIsRejected()
    {
        var values = new Dictionary<string, string?>();
        foreach (var key in new[] { "W365_TENANT_ID", "W365_BLUEPRINT_ID", "W365_AGENT_ID", "W365_AGENT_OBJECT_ID",
            "W365_AGENT_USER_ID", "OPERATOR_TENANT_ID", "OPERATOR_OBJECT_ID" })
            values[key] = "11111111-1111-1111-1111-111111111111";
        values["W365_ENABLED"] = "true";
        values["FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID"] = "22222222-2222-2222-2222-222222222222";
        values["VIEWER_PUBLIC_URL"] = "https://viewer.example.com";
        values["SESSION_BLOB_URI"] = "https://storage.example.com/state/slot.json";
        values["HOSTED_ALLOWED_USER_ID"] = "operator";
        var error = Assert.Throws<InvalidOperationException>(() => Config(values).Validate());
        Assert.Contains("does not match", error.Message);
        values["FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID"] = values["W365_BLUEPRINT_ID"];
        Config(values).Validate();
    }
}
