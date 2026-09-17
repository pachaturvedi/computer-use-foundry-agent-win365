using Microsoft.Agents.AI.Foundry.Hosting;
using Win365Agent;

var viewerMode = args.Contains("--viewer", StringComparer.Ordinal);
var cleanArgs = args.Where(argument => argument != "--viewer").ToArray();
var builder = WebApplication.CreateBuilder(cleanArgs);
var settings = new Settings(builder.Configuration);

ApplicationHosting.Configure(builder, settings, viewerMode);
settings.Validate(viewerMode);

if (!settings.Enabled)
{
    var bootstrap = builder.Build();
    BootstrapEndpoints.Map(bootstrap);
    bootstrap.Run();
    return;
}

builder.AddWin365Services(settings, viewerMode);
if (viewerMode)
{
    ViewerEndpoints.Configure(builder, settings);
    var viewer = builder.Build();
    ViewerEndpoints.Map(viewer, settings);
    viewer.Run();
    return;
}

builder.AddDesktopAgent(settings);
var app = builder.Build();
app.UseMiddleware<DesktopRequestMiddleware>();
app.MapFoundryResponses();
app.Run();

public partial class Program;
