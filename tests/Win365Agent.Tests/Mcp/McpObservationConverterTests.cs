using System.Text.Json;
using Microsoft.Extensions.AI;
using SkiaSharp;
using Win365Agent;

namespace Win365Agent.Tests;

public sealed class McpObservationConverterTests
{
    [Fact]
    public void ScreenshotBecomesBoundedImageAndReportsCoordinateScale()
    {
        using var bitmap = new SKBitmap(2000, 1000);
        bitmap.Erase(SKColors.White);
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        var result = JsonSerializer.SerializeToElement(new
        {
            content = new[]
            {
                new
                {
                    type = "image",
                    data = Convert.ToBase64String(data.ToArray()),
                    mimeType = "image/png"
                }
            }
        });
        var count = 0;

        var output = McpObservationConverter.Convert(result, ref count);

        Assert.Contains("2000x1000 to 1280x640", ((TextContent)output[0]).Text);
        var content = Assert.IsType<DataContent>(output[1]);
        Assert.Equal("image/jpeg", content.MediaType);
        Assert.True(content.Data.Length <= 128 * 1024);
        count = 4;
        Assert.Throws<InvalidOperationException>(
            () => McpObservationConverter.Convert(result, ref count));
    }
}
