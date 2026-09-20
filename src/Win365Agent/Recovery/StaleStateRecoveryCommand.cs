using Azure.Identity;
using Microsoft.Extensions.Logging.Abstractions;

namespace Win365Agent;

internal static class StaleStateRecoveryCommand
{
    internal const string CommandName = "recover-stale-state";

    internal static async Task<int> RunAsync(string[] arguments)
    {
        var apply = arguments.Contains("--apply", StringComparer.Ordinal);
        var environmentIndex = Array.IndexOf(arguments, "--environment");
        var environmentName = environmentIndex >= 0 && environmentIndex + 1 < arguments.Length
            ? arguments[environmentIndex + 1]
            : null;
        var allowed = new HashSet<int> { environmentIndex, environmentIndex + 1 };
        if (arguments
            .Select((argument, index) => (argument, index))
            .Any(item => item.argument != "--apply" && !allowed.Contains(item.index)) ||
            string.IsNullOrWhiteSpace(environmentName))
        {
            Console.Error.WriteLine(
                "Recovery failed: use recover-stale-state --environment <azd-environment> [--apply].");
            return 2;
        }

        using var cancellation = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        ConsoleCancelEventHandler cancelHandler = (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            cancellation.Cancel();
        };
        Console.CancelKeyPress += cancelHandler;
        try
        {
            IReadOnlyDictionary<string, string>? verifiedConfiguration = null;
            if (apply)
            {
                // The mutating process performs its own deployed-agent verification. It never
                // trusts a caller-supplied "verified" boolean or owner/state configuration.
                verifiedConfiguration = await HostedSessionRecoveryGuard.VerifyAndLoadConfigurationAsync(
                    environmentName,
                    cancellation.Token);
            }
            var configurationBuilder = new ConfigurationBuilder()
                .AddEnvironmentVariables();
            if (verifiedConfiguration is not null)
            {
                configurationBuilder.AddInMemoryCollection(
                    verifiedConfiguration.Select(pair =>
                        new KeyValuePair<string, string?>(pair.Key, pair.Value)));
            }
            var configuration = configurationBuilder.Build();
            var settings = new Settings(configuration);
            var credential = new DefaultAzureCredential();
            using var http = new HttpClient(new SocketsHttpHandler
            {
                AllowAutoRedirect = false,
                PooledConnectionLifetime = TimeSpan.FromMinutes(5)
            })
            {
                Timeout = TimeSpan.FromSeconds(45)
            };

            IBlueprintSecretResolver? secretResolver =
                settings.BlueprintCredentialMode == "client_secret"
                    ? new KeyVaultBlueprintSecretResolver(settings, credential)
                    : null;
            IBlueprintCertificateAssertionProvider? certificateAssertionProvider =
                settings.BlueprintCredentialMode == "key_vault_certificate"
                    ? new KeyVaultBlueprintCertificateAssertionProvider(settings, credential, http)
                    : null;
            var blueprint = new BlueprintTokenProvider(
                http,
                settings,
                viewerMode: false,
                NullLogger<BlueprintTokenProvider>.Instance,
                secretResolver,
                certificateAssertionProvider);
            var storageToken = await blueprint.GetAgentIdentityStorageTokenAsync(
                cancellation.Token);
            using var tokens = new AgentUserTokenProvider(
                http,
                settings,
                blueprint,
                NullLogger<AgentUserTokenProvider>.Instance);
            var mcp = new McpConnection(http, tokens, settings);
            var store = new BlobStaleStateStore(
                settings.Https("SESSION_BLOB_URI"),
                new StorageTokenCredential(storageToken));
            var recovery = new StaleDesktopStateRecovery(
                store,
                mcp,
                settings.Required("OPERATOR_TENANT_ID"),
                settings.Required("OPERATOR_OBJECT_ID"));

            Console.WriteLine(
                apply
                    ? "Recovery mode: guarded mutation."
                    : "Recovery mode: read-only inspection; no state will be changed.");
            var outcome = await recovery.InspectAsync(apply, cancellation.Token);
            Console.WriteLine(outcome switch
            {
                StaleStateRecoveryOutcome.NoRecoveryRequired =>
                    "Inspection passed: no persisted desktop state or lease requires recovery.",
                StaleStateRecoveryOutcome.Cleared =>
                    "Recovery completed: stale state was cleared and the recovery lease was released.",
                StaleStateRecoveryOutcome.ClearStateLeaseRequiresRecovery =>
                    "Inspection found clear state with a stale or breaking lease. No changes were made.",
                StaleStateRecoveryOutcome.ReconciledClearState =>
                    "Recovery completed: an interrupted clear was reconciled and the recovery lease was released.",
                _ =>
                    "Inspection passed: state is stale and W365 reports no remote session. No changes were made."
            });
            return 0;
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Recovery failed: the bounded operation was canceled or timed out.");
            return 1;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"Recovery failed safely: {SafeMessage(exception)}");
            return 1;
        }
        finally
        {
            Console.CancelKeyPress -= cancelHandler;
        }
    }

    private static string SafeMessage(Exception exception) =>
        exception switch
        {
            SessionLeaseUnavailableException => SessionLeaseUnavailableException.SafeMessage,
            InvalidOperationException when
                exception.Message.StartsWith("Recovery blocked:", StringComparison.Ordinal) ||
                exception.Message.StartsWith("Recovery stopped at ", StringComparison.Ordinal) =>
                exception.Message,
            _ => "an authorized dependency check did not complete. No state was cleared."
        };

    internal static bool RequiresKeyVault(string credentialMode) =>
        credentialMode is "client_secret" or "key_vault_certificate";
}
