using System.Text.Json;
using Microsoft.Extensions.AI;
using SkiaSharp;

namespace Win365Agent;

public static class Observations
{
    public static IList<AIContent> Convert(JsonElement result, ref int images)
    {
        var contents = new List<AIContent>();
        if (!result.TryGetProperty("content", out var blocks)) throw new InvalidOperationException("Missing MCP content.");
        foreach (var block in blocks.EnumerateArray())
        {
            switch (block.GetProperty("type").GetString())
            {
                case "text":
                    var text = block.GetProperty("text").GetString()!;
                    if (text.Length > 16_000) throw new InvalidOperationException("Observation exceeds 16000 characters. Request a narrower observation.");
                    contents.Add(new TextContent(text));
                    break;
                case "image":
                    if (++images > 4) throw new InvalidOperationException("Four-screenshot task budget exhausted. Use accessibility observations or start a new task.");
                    var bytes = System.Convert.FromBase64String(block.GetProperty("data").GetString()!);
                    using (var codec = SKCodec.Create(new SKMemoryStream(bytes)))
                    {
                        if (codec is null || codec.Info.Width > 8192 || codec.Info.Height > 8192)
                            throw new InvalidOperationException("Invalid or excessive screenshot dimensions.");
                    }
                    using (var original = SKBitmap.Decode(bytes))
                    {
                        if (original is null) throw new InvalidOperationException("Screenshot could not be decoded.");
                        var scale = Math.Min(1.0, 1280.0 / Math.Max(original.Width, original.Height));
                        using var resized = original.Resize(new SKImageInfo(
                            Math.Max(1, (int)(original.Width * scale)), Math.Max(1, (int)(original.Height * scale))),
                            new SKSamplingOptions(SKFilterMode.Linear));
                        using var image = SKImage.FromBitmap(resized);
                        using var encoded = image.Encode(SKEncodedImageFormat.Jpeg, 65);
                        if (encoded.Size > 128 * 1024) throw new InvalidOperationException("Screenshot exceeds compressed budget. Use accessibility observations.");
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
