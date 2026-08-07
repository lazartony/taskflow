using Npgsql;
using TaskFlow.Api.Http;

namespace TaskFlow.Api.Endpoints;

/// <summary>
/// The three health probes (OBS5).
/// </summary>
/// <remarks>
/// Why three endpoints: a single <c>/health</c> that checks the database is the
/// most common self-inflicted outage in production. The database blips, every
/// replica fails its *liveness* probe at once, the orchestrator kills them all,
/// and a recoverable dependency blip becomes a total outage. Liveness answers
/// only "is this process wedged". Readiness answers "should I get traffic now".
/// </remarks>
public sealed class HealthChecker
{
    /// <summary>OBS5.4 — a probe that hits the database on every call is itself a risk.</summary>
    private static readonly TimeSpan CacheTtl = TimeSpan.FromSeconds(1);

    /// <summary>OBS5.4 — hard ceiling on the dependency check.</summary>
    private static readonly TimeSpan CheckTimeout = TimeSpan.FromSeconds(2);

    private readonly NpgsqlDataSource _dataSource;
    private readonly object _gate = new();

    private DateTime _checkedAtUtc = DateTime.MinValue;
    private bool _healthy;

    public HealthChecker(NpgsqlDataSource dataSource) => _dataSource = dataSource;

    /// <summary>Runs <c>SELECT 1</c>, memoising the result for <see cref="CacheTtl"/>.</summary>
    public async Task<bool> IsReadyAsync(CancellationToken cancellationToken)
    {
        // The lock is released before the await. Holding a lock across an await
        // is not even legal here, and doing the equivalent with a semaphore
        // would serialise every probe behind one database round trip.
        lock (_gate)
        {
            if (DateTime.UtcNow - _checkedAtUtc < CacheTtl)
            {
                return _healthy;
            }
        }

        bool healthy;
        try
        {
            using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutSource.CancelAfter(CheckTimeout);

            using var command = _dataSource.CreateCommand("SELECT 1");
            await command.ExecuteScalarAsync(timeoutSource.Token).ConfigureAwait(false);
            healthy = true;
        }
        catch (Exception)
        {
            // Deliberately broad: a readiness probe must report "not ready" for
            // any failure, not throw a 500 and leave the orchestrator guessing.
            healthy = false;
        }

        lock (_gate)
        {
            _checkedAtUtc = DateTime.UtcNow;
            _healthy = healthy;
        }

        return healthy;
    }
}

public static class HealthEndpoints
{
    public static void MapHealthEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/v1/health");

        // OBS5.1 — liveness. No dependency checks, ever.
        group.MapGet("/live", (HttpContext context) =>
            Envelope.Success(context, StatusCodes.Status200OK, new { status = "alive" }));

        // OBS5.2 — readiness.
        group.MapGet("/ready", ReadyAsync);

        // OBS5.5 — /api/v1/health stays as an alias of /health/ready.
        //
        // Registered ONCE. Inside a group, `MapGet("")` and `MapGet("/")` both
        // resolve to the template `/api/v1/health/`, so mapping both produced two
        // identical endpoints and every request to /api/v1/health died with
        // AmbiguousMatchException — a 500 with an empty body, which is also why it
        // did not look like a routing problem. The single registration already
        // answers both /api/v1/health and /api/v1/health/.
        group.MapGet("", ReadyAsync);

        // OBS5.3 — startup. The data source is created and pinged before the
        // host starts accepting, so reaching this handler means startup succeeded.
        //
        // TODO(Phase 3): also assert the expected schema_migrations version,
        // so a replica pointed at an un-migrated database never reports started.
        group.MapGet("/startup", (HttpContext context) =>
            Envelope.Success(context, StatusCodes.Status200OK, new { status = "started" }));
    }

    /// <remarks>
    /// TODO(Phase 4): add the Valkey PING here.
    /// TODO(Phase 6): add the Kafka broker metadata check here.
    /// </remarks>
    private static async Task<IResult> ReadyAsync(HttpContext context, HealthChecker checker)
    {
        var healthy = await checker.IsReadyAsync(context.RequestAborted).ConfigureAwait(false);

        if (!healthy)
        {
            // The envelope invariant is absolute: a >=400 status carries
            // success:false and error.code. The detail travels in error.details
            // so an operator still sees which dependency failed.
            return Envelope.Failure(
                context,
                StatusCodes.Status503ServiceUnavailable,
                "SERVICE_UNAVAILABLE",
                "One or more dependencies are unavailable",
                new { status = "not_ready", checks = new { database = "down" } });
        }

        return Envelope.Success(
            context,
            StatusCodes.Status200OK,
            new { status = "ready", checks = new { database = "up" } });
    }
}
