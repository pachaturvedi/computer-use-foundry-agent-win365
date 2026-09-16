using System.Text.Json;

namespace Win365Agent;

internal static class ResponseRequest
{
    internal const int MaxBytes = 64 * 1024;

    internal static bool IsCreate(HttpRequest request) =>
        HttpMethods.IsPost(request.Method) &&
        (request.Path.Value ?? "").TrimEnd('/').EndsWith("/responses", StringComparison.OrdinalIgnoreCase);

    internal static async Task<bool> ValidateAsync(HttpContext context)
    {
        if (context.Request.ContentLength > MaxBytes)
            return await RejectAsync(context, 413, "Request exceeds the 64 KiB task limit.");

        // Read one byte past the limit to bound chunked bodies without relying on Content-Length.
        context.Request.EnableBuffering(32 * 1024, MaxBytes + 1);
        var bytes = new byte[MaxBytes + 1];
        var length = 0;
        while (length < bytes.Length)
        {
            var read = await context.Request.Body.ReadAsync(bytes.AsMemory(length), context.RequestAborted);
            if (read == 0) break;
            length += read;
        }
        if (length > MaxBytes)
            return await RejectAsync(context, 413, "Request exceeds the 64 KiB task limit.");

        JsonDocument body;
        try { body = JsonDocument.Parse(bytes.AsMemory(0, length)); }
        catch (JsonException) { return await RejectAsync(context, 400, "Request must contain a valid JSON object."); }
        using (body)
        {
            var root = body.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return await RejectAsync(context, 400, "Request must contain a valid JSON object.");
            if (root.TryGetProperty("previous_response_id", out _) ||
                root.TryGetProperty("conversation", out _) ||
                root.TryGetProperty("background", out var bg) && bg.ValueKind == JsonValueKind.True)
                return await RejectAsync(context, 400,
                    "Use a fresh foreground request: previous_response_id, conversation and background execution are not supported.");
        }
        context.Request.Body.Position = 0;
        return true;
    }

    private static async Task<bool> RejectAsync(HttpContext context, int status, string message)
    {
        context.Response.StatusCode = status;
        await context.Response.WriteAsync(message, context.RequestAborted);
        return false;
    }
}
