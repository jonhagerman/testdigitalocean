using System.Reflection;
using System.Runtime.InteropServices;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddHealthChecks();

var app = builder.Build();

var version = Assembly.GetExecutingAssembly()
    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "unknown";
var commit = Environment.GetEnvironmentVariable("APP_COMMIT") ?? "unknown";
var startedUtc = DateTime.UtcNow;

app.MapGet("/", () => Results.Ok(new
{
    message = "Hello from TestDigitalOcean on App Platform",
    version,
    commit,
    startedUtc,
    uptime = (DateTime.UtcNow - startedUtc).ToString(@"d\.hh\:mm\:ss"),
    environment = app.Environment.EnvironmentName,
    machine = Environment.MachineName,
    os = RuntimeInformation.OSDescription,
    architecture = RuntimeInformation.OSArchitecture.ToString(),
    framework = RuntimeInformation.FrameworkDescription,
    utcNow = DateTime.UtcNow
}));

app.MapHealthChecks("/healthz");

app.Run();
