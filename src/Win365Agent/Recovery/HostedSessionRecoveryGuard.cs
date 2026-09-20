using System.Diagnostics;
using System.Text.Json;

namespace Win365Agent;

internal static class HostedSessionRecoveryGuard
{
    private static readonly HashSet<string> _stoppedStatuses = new(
        ["stopped", "idle", "deleted", "expired"],
        StringComparer.OrdinalIgnoreCase);

    internal static async Task<IReadOnlyDictionary<string, string>> VerifyAndLoadConfigurationAsync(
        string environmentName,
        CancellationToken cancellationToken)
    {
        var azd = Environment.GetEnvironmentVariable("RECOVERY_AZD_PATH") ?? "azd";
        var names = new[]
        {
            "SESSION_BLOB_URI",
            "W365_TENANT_ID",
            "W365_BLUEPRINT_ID",
            "W365_AGENT_ID",
            "W365_AGENT_USER_ID",
            "W365_BLUEPRINT_CREDENTIAL_MODE",
            "OPERATOR_TENANT_ID",
            "OPERATOR_OBJECT_ID",
            "FOUNDRY_AGENT_NAME"
        };
        var configuration = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var name in names)
        {
            configuration[name] = await GetEnvironmentValueAsync(
                azd,
                environmentName,
                name,
                cancellationToken);
        }
        if (StaleStateRecoveryCommand.RequiresKeyVault(
            configuration["W365_BLUEPRINT_CREDENTIAL_MODE"]))
        {
            configuration["W365_KEY_VAULT_NAME"] = await GetEnvironmentValueAsync(
                azd,
                environmentName,
                "W365_KEY_VAULT_NAME",
                cancellationToken);
        }

        var output = await RunAsync(
            azd,
            [
                "ai", "agent", "sessions", "list",
                "--agent-name", configuration["FOUNDRY_AGENT_NAME"],
                "--environment", environmentName,
                "--limit", "100",
                "--output", "json"
            ],
            cancellationToken);
        if (!HasOnlyStoppedSessions(output))
        {
            throw new InvalidOperationException(
                "Recovery blocked: the deployed agent's hosted sessions are active, ambiguous, paged, or malformed.");
        }
        return configuration;
    }

    internal static bool HasOnlyStoppedSessions(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (HasContinuation(root) ||
                root.ValueKind == JsonValueKind.Object &&
                root.TryGetProperty("data", out var data) &&
                data.ValueKind == JsonValueKind.Object &&
                HasContinuation(data))
            {
                return false;
            }

            if (!TryGetSingleCollection(root, out var records))
            {
                return false;
            }
            foreach (var record in records.EnumerateArray())
            {
                if (record.ValueKind != JsonValueKind.Object ||
                    !record.TryGetProperty("status", out var status) ||
                    status.ValueKind != JsonValueKind.String ||
                    string.IsNullOrWhiteSpace(status.GetString()) ||
                    !_stoppedStatuses.Contains(status.GetString()!.Trim()))
                {
                    return false;
                }
            }
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool TryGetSingleCollection(JsonElement root, out JsonElement records)
    {
        if (root.ValueKind == JsonValueKind.Array)
        {
            records = root;
            return true;
        }
        if (root.ValueKind != JsonValueKind.Object)
        {
            records = default;
            return false;
        }

        var found = new List<JsonElement>();
        AddCollections(root, found);
        if (root.TryGetProperty("data", out var data))
        {
            if (data.ValueKind == JsonValueKind.Array)
            {
                found.Add(data);
            }
            else if (data.ValueKind == JsonValueKind.Object)
            {
                AddCollections(data, found);
            }
        }
        records = found.Count == 1 ? found[0] : default;
        return found.Count == 1;
    }

    private static void AddCollections(JsonElement element, List<JsonElement> found)
    {
        foreach (var name in new[] { "sessions", "items", "value" })
        {
            if (element.TryGetProperty(name, out var value) &&
                value.ValueKind == JsonValueKind.Array)
            {
                found.Add(value);
            }
        }
    }

    private static bool HasContinuation(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return false;
        }
        foreach (var name in new[]
        {
            "paginationToken", "pagination_token", "continuationToken",
            "nextLink", "next_link", "nextToken", "nextPageToken", "@odata.nextLink"
        })
        {
            if (element.TryGetProperty(name, out var value) &&
                value.ValueKind != JsonValueKind.Null &&
                (value.ValueKind != JsonValueKind.String ||
                 !string.IsNullOrWhiteSpace(value.GetString())))
            {
                return true;
            }
        }
        if (element.TryGetProperty("pagination", out var pagination) &&
            pagination.ValueKind == JsonValueKind.Object)
        {
            return HasContinuation(pagination);
        }
        return false;
    }

    private static async Task<string> GetEnvironmentValueAsync(
        string azd,
        string environmentName,
        string name,
        CancellationToken cancellationToken)
    {
        var value = (await RunAsync(
            azd,
            ["env", "get-value", name, "--environment", environmentName],
            cancellationToken)).Trim().Trim('"');
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new InvalidOperationException(
                $"Recovery blocked: deployed agent binding '{name}' is missing.");
        }
        return value;
    }

    private static async Task<string> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo(executable)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        using var process = Process.Start(start) ??
            throw new InvalidOperationException("Recovery blocked: azd could not be started.");
        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        _ = await errorTask;
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(
                "Recovery blocked: an azd hosted-session verification command failed.");
        }
        return await outputTask;
    }
}
