using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Win365Agent;

namespace Win365Agent.Tests;

internal static class TestSettings
{
    internal static Settings Create() => new(
        new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["W365_TENANT_ID"] = "11111111-1111-1111-1111-111111111111",
                ["VIEWER_PUBLIC_URL"] = "http://localhost:5050",
                ["SAMPLE_LOCAL_MODE"] = "true",
                ["OPERATOR_TENANT_ID"] = "tenant",
                ["OPERATOR_OBJECT_ID"] = "owner"
            })
            .Build());

    internal static JsonElement Json(string json) =>
        JsonDocument.Parse(json).RootElement.Clone();

    internal static DesktopSession Session() => new()
    {
        RequestId = "task",
        OwnerObjectId = "owner",
        OwnerTenantId = "tenant",
        Phase = DesktopSessionPhase.Active,
        SessionId = "desktop"
    };
}
