using System.Text.Json;
using Microsoft.Extensions.AI;
using SkiaSharp;

namespace Win365Agent;

/// <summary>Converts bounded MCP text and screenshot observations into content suitable for the agent model.</summary>
public static class McpObservationConverter
{
    /// <summary>Converts MCP content blocks while enforcing per-observation and per-task limits.</summary>
    /// <param name="result">The MCP tool result containing a <c>content</c> array.</param>
    /// <param name="images">The task-wide screenshot count, incremented for each image block encountered.</param>
    /// <param name="maxImages">The maximum number of screenshot observations allowed for the task.</param>
    /// <returns>Text content and normalized JPEG image content.</returns>
    /// <exception cref="InvalidOperationException">
    /// Content is missing, unsupported, oversized, undecodable, or exceeds the screenshot task budget.
    /// </exception>
    public static IList<AIContent> Convert(JsonElement result, ref int images, int maxImages = 4)
    {
        var contents = new List<AIContent>();
        if (!result.TryGetProperty("content", out var blocks))
        {
            throw new InvalidOperationException("Missing MCP content.");
        }

        foreach (var block in blocks.EnumerateArray())
        {
            switch (block.GetProperty("type").GetString())
            {
                case "text":
                    var text = block.GetProperty("text").GetString()!;
                    if (text.Length > 16_000)
                    {
                        throw new InvalidOperationException("Observation exceeds 16000 characters. Request a narrower observation.");
                    }

                    contents.Add(new TextContent(text));
                    break;
                case "image":
                    if (++images > maxImages)
                    {
                        throw new InvalidOperationException(
                            $"{maxImages}-screenshot task budget exhausted. Complete the task with existing observations or start a new task.");
                    }

                    var bytes = System.Convert.FromBase64String(block.GetProperty("data").GetString()!);
                    // Read image metadata first to reject decompression bombs before allocating the decoded bitmap.
                    using (var codec = SKCodec.Create(new SKMemoryStream(bytes)))
                    {
                        if (codec is null || codec.Info.Width > 8192 || codec.Info.Height > 8192)
                        {
                            throw new InvalidOperationException("Invalid or excessive screenshot dimensions.");
                        }
                    }
                    using (var original = SKBitmap.Decode(bytes))
                    {
                        if (original is null)
                        {
                            throw new InvalidOperationException("Screenshot could not be decoded.");
                        }

                        var scale = Math.Min(1.0, 1280.0 / Math.Max(original.Width, original.Height));
                        using var resized = original.Resize(new SKImageInfo(
                            Math.Max(1, (int)(original.Width * scale)), Math.Max(1, (int)(original.Height * scale))),
                            new SKSamplingOptions(SKFilterMode.Linear));
                        using var image = SKImage.FromBitmap(resized);
                        using var encoded = image.Encode(SKEncodedImageFormat.Jpeg, 65);
                        if (encoded.Size > 128 * 1024)
                        {
                            throw new InvalidOperationException("Screenshot exceeds compressed budget. Use accessibility observations.");
                        }

                        contents.Add(new TextContent($"Screenshot resized from {original.Width}x{original.Height} to {resized.Width}x{resized.Height}. Mouse coordinates must use ORIGINAL screen pixels."));
                        contents.Add(new DataContent(encoded.ToArray(), "image/jpeg"));
                    }
                    break;
                default:
                    throw new InvalidOperationException("Unsupported MCP observation content type.");
            }
        }
        return contents;
    }
}
