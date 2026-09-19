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
    public void LocalPortsHaveSafeDefaultsAndCanBeOverridden()
    {
        var defaults = Config([]);
        Assert.Equal(8088, defaults.LocalAgentPort);
        Assert.Equal(5050, defaults.LocalViewerPort);

        var custom = Config(new() { ["LOCAL_AGENT_PORT"] = "18088", ["LOCAL_VIEWER_PORT"] = "15050" });
        Assert.Equal(18088, custom.LocalAgentPort);
        Assert.Equal(15050, custom.LocalViewerPort);
        Assert.Throws<InvalidOperationException>(() => Config(new() { ["LOCAL_AGENT_PORT"] = "0" }).LocalAgentPort);
    }

    [Fact]
    public void EnabledRequiresPostDeploymentConfiguration() =>
        Assert.Throws<InvalidOperationException>(() => Config(new() { ["W365_ENABLED"] = "true" }).Validate());

    [Fact]
    public void LocalCredentialsCannotImpersonateFoundry() =>
        Assert.Throws<InvalidOperationException>(() => Config(new()
        {
            ["W365_ENABLED"] = "true",
            ["SAMPLE_LOCAL_MODE"] = "true"
        }).Validate());

    [Theory]
    [InlineData("W365_CERTIFICATE_PATH")]
    [InlineData("W365_CERTIFICATE_PASSWORD")]
    public void LegacyBlueprintCredentialsAreExplicitlyRejected(string key) =>
        Assert.Throws<InvalidOperationException>(() => Config(new() { [key] = "obsolete" }).Validate());

    [Fact]
    public void ClientSecretModeRequiresAnExplicitSecret()
    {
        var values = EnabledValues();
        values["W365_BLUEPRINT_CREDENTIAL_MODE"] = "client_secret";
        Assert.Throws<InvalidOperationException>(() => Config(values).Validate());

        values["W365_CLIENT_SECRET"] = "temporary-secret";
        Config(values).Validate();
        values["SCREENSHARE_APP_URL"] = "https://screenshare.example.com";
        values["AZURE_CLIENT_ID"] = "99999999-9999-9999-9999-999999999999";
        Config(values).Validate(viewerMode: true);
    }

    [Theory]
    [InlineData("key_vault_certificate")]
    [InlineData("unknown")]
    public void UnimplementedCredentialModesFailClosed(string mode)
    {
        var values = EnabledValues();
        values["W365_BLUEPRINT_CREDENTIAL_MODE"] = mode;
        var error = Assert.Throws<InvalidOperationException>(() => Config(values).Validate());
        Assert.Contains("fails closed", error.Message);
    }

    [Fact]
    public void MisspelledEnableFlagDoesNotSilentlyDisableDesktop() =>
        Assert.Throws<InvalidOperationException>(() => Config(new() { ["W365_ENABLED"] = "tru" }).Validate());

    [Theory]
    [InlineData("true", true)]
    [InlineData("True", true)]
    [InlineData("TRUE", true)]
    [InlineData("false", false)]
    [InlineData("False", false)]
    [InlineData("FALSE", false)]
    public void EnabledFlagToleratesAnyCasingWrittenByIacOrTooling(string rawValue, bool expected) =>
        Assert.Equal(expected, Config(new() { ["W365_ENABLED"] = rawValue }).Enabled);

    [Theory]
    [InlineData("true", true)]
    [InlineData("True", true)]
    [InlineData("TRUE", true)]
    [InlineData("false", false)]
    [InlineData("False", false)]
    [InlineData("anything-else", false)]
    public void LocalModeFlagToleratesAnyCasingWrittenByIacOrTooling(string rawValue, bool expected) =>
        Assert.Equal(expected, Config(new() { ["SAMPLE_LOCAL_MODE"] = rawValue }).Local);

    [Fact]
    public void WrongFoundryBlueprintIsRejected()
    {
        var values = EnabledValues();
        values["FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID"] = "88888888-8888-8888-8888-888888888888";
        var error = Assert.Throws<InvalidOperationException>(() => Config(values).Validate());
        Assert.Contains("does not match", error.Message);
        values["FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID"] = values["W365_BLUEPRINT_ID"];
        Config(values).Validate();

        values.Remove("VIEWER_PUBLIC_URL");
        Config(values).Validate();
    }

    [Fact]
    public void ScreenShareAppRequiresConfiguredSafeHttps()
    {
        Assert.Throws<InvalidOperationException>(() => Config([]).ScreenShareAppUrl);

        var values = EnabledValues();
        values["SCREENSHARE_APP_URL"] = "https://screenshare.example.com/app";
        Assert.Equal("https://screenshare.example.com/app/", Config(values).ScreenShareAppUrl.ToString());

        values["SCREENSHARE_APP_URL"] = "https://user:password@screenshare.example.com";
        Assert.Throws<InvalidOperationException>(() => Config(values).Validate(viewerMode: true));
    }

    private static Dictionary<string, string?> EnabledValues() => new()
    {
        ["W365_ENABLED"] = "true",
        ["W365_TENANT_ID"] = "11111111-1111-1111-1111-111111111111",
        ["W365_BLUEPRINT_ID"] = "22222222-2222-2222-2222-222222222222",
        ["W365_AGENT_ID"] = "33333333-3333-3333-3333-333333333333",
        ["W365_AGENT_OBJECT_ID"] = "44444444-4444-4444-4444-444444444444",
        ["W365_AGENT_USER_ID"] = "55555555-5555-5555-5555-555555555555",
        ["OPERATOR_TENANT_ID"] = "66666666-6666-6666-6666-666666666666",
        ["OPERATOR_OBJECT_ID"] = "77777777-7777-7777-7777-777777777777",
        ["FOUNDRY_AGENT_BLUEPRINT_CLIENT_ID"] = "22222222-2222-2222-2222-222222222222",
        ["VIEWER_PUBLIC_URL"] = "https://viewer.example.com",
        ["SESSION_BLOB_URI"] = "https://storage.example.com/state/slot.json",
        ["HOSTED_ALLOWED_USER_ID"] = "operator"
    };
}
