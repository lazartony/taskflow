// TaskFlow C# API.
//
// This is a SKELETON. It starts, connects to Postgres, serves the three health
// probes for real, and answers 501 NOT_IMPLEMENTED for every other /api/v1
// route. Everything else is a TODO pointing at the roadmap phase that builds it.

using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Npgsql;
using TaskFlow.Api.Config;
using TaskFlow.Api.Endpoints;
using TaskFlow.Api.Http;

// The container HEALTHCHECK re-invokes this same executable with --healthcheck.
// The runtime image is chiselled: no shell, no curl, no wget. Shipping a second
// binary just to make an HTTP call would mean a second runtime to keep patched.
if (args.Length > 0 && args[0] == "--healthcheck")
{
    return await HealthCheckCommand.RunAsync().ConfigureAwait(false);
}

// Config failures are a startup contract, not a crash. Letting the exception go
// unhandled looked like it worked — the runtime prints a stack trace — but on the
// chiselled runtime the process then span at 100% CPU instead of exiting, so a
// misconfigured container stayed "running" forever and compose never noticed. The
// other four implementations all exit 1 here, and the READMEs promise it.
//
// Emitted as JSON by hand because AppLog is not configured yet: the whole point
// of the logging contract is that there is no plain-text line on stdout, and
// startup failures are exactly when someone is grepping the logs.
AppConfig config;
try
{
    config = AppConfig.Load();
}
catch (Exception ex)
{
    var fatal = JsonSerializer.Serialize(new Dictionary<string, object?>
    {
        ["timestamp"] = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture),
        ["level"] = "error",
        ["message"] = "fatal: invalid configuration",
        ["error"] = ex.Message,
    });
    Console.Error.WriteLine(fatal);
    return 1;
}

AppLog.Configure(config.ServiceName, config.ServiceVersion);

var builder = WebApplication.CreateBuilder(args);

// PORT is the single source of truth across all five services, so this wins
// over ASPNETCORE_URLS if both are set.
builder.WebHost.ConfigureKestrel(options => options.ListenAnyIP(config.Port));

// Framework logs (Kestrel, routing) go out as JSON too, so nothing on stdout is
// plain text for Loki to choke on.
//
// TODO(Phase 2): replace both this and AppLog with OpenTelemetry logging, which
// attaches the service resource once and adds trace_id/span_id from Activity.
builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole();
builder.Logging.SetMinimumLevel(config.LogLevel.ToLowerInvariant() switch
{
    "debug" => LogLevel.Debug,
    "warn" or "warning" => LogLevel.Warning,
    "error" => LogLevel.Error,
    _ => LogLevel.Information,
});

// Npgsql owns its own pool; MaxPoolSize/MinPoolSize are baked into the
// connection string by AppConfig.
var dataSource = new NpgsqlDataSourceBuilder(config.ConnectionString).Build();
builder.Services.AddSingleton(dataSource);
builder.Services.AddSingleton<HealthChecker>();
builder.Services.AddSingleton(config);

// The host waits this long for in-flight requests before it stops hard.
builder.Services.Configure<HostOptions>(options =>
    options.ShutdownTimeout = config.ShutdownGracePeriod);

var app = builder.Build();

// Fail fast: a service that cannot reach its database should not start.
using (var probe = dataSource.CreateCommand("SELECT 1"))
{
    await probe.ExecuteScalarAsync().ConfigureAwait(false);
}

AppLog.Info("database pool ready", new Dictionary<string, object?>
{
    ["max_conns"] = config.DatabasePoolSize,
});

// ── Middleware ────────────────────────────────────────────────────────────
// TODO(Phase 1): security headers, CORS, body limit, auth middleware.
// TODO(Phase 2): OTel ASP.NET Core instrumentation.
// TODO(Phase 4): valkey-backed rate limiting.
// TODO(Phase 5): concurrency limiter for load shedding.
app.Use(async (context, next) =>
{
    var requestId = Envelope.NewRequestId();
    context.Items[Envelope.RequestIdItemKey] = requestId;
    context.Items[Envelope.TraceIdItemKey] = Envelope.NewTraceId();

    // Set before calling next: once the response has started, headers are frozen.
    //
    // TODO(Phase 1): honour a well-formed inbound X-Request-Id so a caller can
    // correlate across a retry.
    // TODO(Phase 2): extract the W3C traceparent header instead of minting one.
    context.Response.Headers["X-Request-Id"] = requestId;

    var start = Stopwatch.GetTimestamp();
    await next(context).ConfigureAwait(false);
    var elapsed = Stopwatch.GetElapsedTime(start);

    // TODO(Phase 2): use the matched route template, never the raw path
    // (OBS3.5), plus trace_id, span_id and user.id.
    AppLog.Info("http request completed", new Dictionary<string, object?>
    {
        ["http"] = new Dictionary<string, object?>
        {
            ["request"] = new Dictionary<string, object?> { ["method"] = context.Request.Method },
            ["route"] = context.GetEndpoint()?.DisplayName ?? context.Request.Path.Value,
            ["response"] = new Dictionary<string, object?>
            {
                ["status_code"] = context.Response.StatusCode,
            },
        },
        ["url"] = new Dictionary<string, object?> { ["path"] = context.Request.Path.Value },
        ["duration_ms"] = Math.Round(elapsed.TotalMilliseconds, 3),
        ["request_id"] = requestId,
    });
});

// ── Routes ────────────────────────────────────────────────────────────────
app.MapHealthEndpoints();

// TODO(Phase 1):  app.MapAuthEndpoints();
// TODO(Phase 1):  app.MapTaskEndpoints();
// TODO(Phase 10): app.MapAttachmentEndpoints();

// Everything else is deliberately 501. ASP.NET routing prefers the more
// specific route, so this catch-all yields as soon as a real endpoint exists —
// there is no registration order to maintain, unlike the other four services.
app.Map("/api/v1/{**rest}", (HttpContext context) => Envelope.NotImplemented(context));

// ── Graceful shutdown ─────────────────────────────────────────────────────
app.Lifetime.ApplicationStopping.Register(() =>
{
    AppLog.Info("shutdown signal received", null);

    // ApplicationStopping fires BEFORE Kestrel stops accepting, so blocking
    // here is the pre-stop delay: the load balancer notices we are going away
    // while we are still serving. Without it, in-flight routing sends requests
    // to a socket that is already closed.
    //
    // TODO(if you deploy this): flip readiness to "not ready" here as well, so an
    // orchestrator pulls this instance out of rotation during the delay. Kubernetes
    // itself is off the roadmap on purpose — see "Cut: Kubernetes deployment" in
    // docs/learning-roadmap.md.
    Thread.Sleep(config.ShutdownPrestopDelay);
});

app.Lifetime.ApplicationStopped.Register(() => AppLog.Info("shutdown complete", null));

AppLog.Info("http server listening", new Dictionary<string, object?>
{
    ["addr"] = $":{config.Port}",
    ["env"] = config.Environment,
});

await app.RunAsync().ConfigureAwait(false);

// TODO(Phase 6): drain the outbox relay and the Kafka consumer here, before the
// data source is disposed — they hold connections too.
await dataSource.DisposeAsync().ConfigureAwait(false);

return 0;

/// <summary>
/// Minimal structured JSON logger writing to stdout.
/// </summary>
/// <remarks>
/// Deliberately not built on <c>ILogger</c>: attaching constant resource fields
/// (<c>service.name</c>) to every line through the built-in JSON console
/// formatter needs a custom <c>ConsoleFormatter</c>, which is more moving parts
/// than a skeleton warrants. Phase 2 replaces this wholesale with OTel logging.
/// </remarks>
internal static class AppLog
{
    private static readonly object Gate = new();
    private static Dictionary<string, object?> _service = new()
    {
        ["name"] = "taskflow-csharp",
        ["version"] = "1.0.0",
    };

    public static void Configure(string serviceName, string serviceVersion) =>
        _service = new Dictionary<string, object?>
        {
            ["name"] = serviceName,
            ["version"] = serviceVersion,
        };

    public static void Info(string message, IDictionary<string, object?>? fields) =>
        Write("info", message, fields);

    public static void Error(string message, IDictionary<string, object?>? fields) =>
        Write("error", message, fields);

    private static void Write(string level, string message, IDictionary<string, object?>? fields)
    {
        var payload = new Dictionary<string, object?>
        {
            ["timestamp"] = Envelope.NowIso(),
            ["level"] = level,
            ["message"] = message,
            ["service"] = _service,
        };

        if (fields is not null)
        {
            foreach (var (key, value) in fields)
            {
                payload[key] = value;
            }
        }

        // Console.Out is thread-safe per call, but two writers can still
        // interleave a line; the lock keeps each JSON object on its own line.
        lock (Gate)
        {
            Console.Out.WriteLine(JsonSerializer.Serialize(payload));
        }
    }
}

/// <summary>
/// Container HEALTHCHECK, invoked as <c>TaskFlow.Api --healthcheck</c>.
/// </summary>
/// <remarks>
/// Probes LIVE, not READY — see Endpoints/HealthEndpoints.cs for why that
/// distinction matters (OBS5.1).
/// </remarks>
internal static class HealthCheckCommand
{
    public static async Task<int> RunAsync()
    {
        var port = Environment.GetEnvironmentVariable("PORT");
        if (string.IsNullOrEmpty(port))
        {
            port = "8080";
        }

        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
            using var response = await client
                .GetAsync(new Uri($"http://127.0.0.1:{port}/api/v1/health/live"))
                .ConfigureAwait(false);

            return response.IsSuccessStatusCode ? 0 : 1;
        }
        catch (Exception)
        {
            return 1;
        }
    }
}
