using Microsoft.Agents.AI.Foundry.Hosting;
using Win365Agent;

var builder = WebApplication.CreateBuilder(args);
var settings = new Settings(builder.Configuration);

ApplicationHosting.Configure(builder, settings, viewerMode: false);
settings.Validate();

if (!settings.Enabled)
{
    var bootstrap = builder.Build();
    BootstrapEndpoints.Map(bootstrap);
    bootstrap.Run();
    return;
}

builder.AddWin365Services(settings, viewerMode: false);
builder.AddDesktopAgent(settings);
var app = builder.Build();
app.UseMiddleware<DesktopRequestMiddleware>();
app.MapFoundryResponses();
app.Run();

public partial class Program;
