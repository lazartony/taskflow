using System.Globalization;
using Npgsql;

namespace TaskFlow.Api.Config;

/// <summary>
/// Runtime configuration, read from the environment.
/// </summary>
/// <remarks>
/// Every key here appears in the repository-root <c>.env.example</c>. Only the
/// subset the skeleton actually uses is parsed; the rest arrive in later phases.
/// </remarks>
public sealed class AppConfig
{
    public required int Port { get; init; }
    public required string Environment { get; init; }
    public required string ServiceName { get; init; }
    public required string ServiceVersion { get; init; }
    public required string LogLevel { get; init; }

    /// <summary>Npgsql key/value connection string, already carrying the pool settings.</summary>
    public required string ConnectionString { get; init; }

    public required int DatabasePoolSize { get; init; }
    public required TimeSpan ShutdownGracePeriod { get; init; }
    public required TimeSpan ShutdownPrestopDelay { get; init; }

    // TODO(Phase 1): JwtSecret, JwtIssuer, JwtAudience, JwtAccessExpiry,
    //   JwtRefreshExpiry, BcryptCost, CorsOrigins, MaxBodyBytes.
    // TODO(Phase 4): ValkeyUrl, CacheEnabled, RateLimit* keys.
    // TODO(Phase 6): KafkaBrokers, Outbox* keys.
    // TODO(Phase 10): S3Endpoint, S3Bucket, S3AccessKey, S3SecretKey.

    /// <summary>
    /// Reads the environment and throws on anything missing or malformed.
    /// Failing at startup beats failing on the first request that needs the value.
    /// </summary>
    public static AppConfig Load()
    {
        var poolSize = GetInt("DATABASE_POOL_SIZE", 10);
        var minIdle = GetInt("DATABASE_MIN_IDLE", 2);
        var acquireTimeoutMs = GetInt("DATABASE_ACQUIRE_TIMEOUT_MS", 2000);

        return new AppConfig
        {
            Port = GetInt("PORT", 8080),
            Environment = GetString("ENV", "development"),
            ServiceName = GetString("OTEL_SERVICE_NAME", "taskflow-csharp"),
            ServiceVersion = GetString("OTEL_SERVICE_VERSION", "1.0.0"),
            LogLevel = GetString("LOG_LEVEL", "info"),
            ConnectionString = BuildConnectionString(poolSize, minIdle, acquireTimeoutMs),
            DatabasePoolSize = poolSize,
            ShutdownGracePeriod = GetDuration("SHUTDOWN_GRACE_PERIOD", TimeSpan.FromSeconds(30)),
            ShutdownPrestopDelay = GetDuration("SHUTDOWN_PRESTOP_DELAY", TimeSpan.FromSeconds(5)),
        };
    }

    /// <summary>
    /// Produces an Npgsql connection string with the pool settings applied.
    /// </summary>
    /// <remarks>
    /// The other four services take <c>DATABASE_URL</c> directly, because their
    /// drivers parse the <c>postgresql://</c> URI form. Npgsql does not — it
    /// wants semicolon-delimited key/value pairs — so the URI is translated
    /// here. This is the single most common way this service ends up unable to
    /// connect while the other four are fine.
    ///
    /// <c>ConnectionStrings__DefaultConnection</c> wins when set, which is how
    /// docker-compose.yml configures this service.
    /// </remarks>
    private static string BuildConnectionString(int poolSize, int minIdle, int acquireTimeoutMs)
    {
        var native = System.Environment.GetEnvironmentVariable(
            "ConnectionStrings__DefaultConnection");

        NpgsqlConnectionStringBuilder builder;

        if (!string.IsNullOrEmpty(native))
        {
            builder = new NpgsqlConnectionStringBuilder(native);
        }
        else
        {
            var databaseUrl = System.Environment.GetEnvironmentVariable("DATABASE_URL");
            if (string.IsNullOrEmpty(databaseUrl))
            {
                throw new InvalidOperationException(
                    "DATABASE_URL (or ConnectionStrings__DefaultConnection) is required");
            }

            builder = FromUri(databaseUrl);
        }

        builder.MaxPoolSize = poolSize;
        builder.MinPoolSize = minIdle;

        // Npgsql's Timeout is the connect/acquire timeout, in whole seconds.
        builder.Timeout = Math.Max(1, (int)Math.Ceiling(acquireTimeoutMs / 1000.0));

        // TODO(Phase 3): ConnectionIdleLifetime / ConnectionLifetime from
        //   DATABASE_MAX_LIFETIME, and CommandTimeout from
        //   DATABASE_STATEMENT_TIMEOUT.

        return builder.ConnectionString;
    }

    private static NpgsqlConnectionStringBuilder FromUri(string databaseUrl)
    {
        var uri = new Uri(databaseUrl);
        var builder = new NpgsqlConnectionStringBuilder
        {
            Host = uri.Host,
            Port = uri.Port > 0 ? uri.Port : 5432,
            Database = uri.AbsolutePath.TrimStart('/'),
        };

        var userInfo = uri.UserInfo.Split(':', 2);
        if (userInfo.Length > 0 && userInfo[0].Length > 0)
        {
            builder.Username = Uri.UnescapeDataString(userInfo[0]);
        }

        if (userInfo.Length > 1 && userInfo[1].Length > 0)
        {
            builder.Password = Uri.UnescapeDataString(userInfo[1]);
        }

        return builder;
    }

    private static string GetString(string key, string fallback)
    {
        var value = System.Environment.GetEnvironmentVariable(key);
        return string.IsNullOrEmpty(value) ? fallback : value;
    }

    private static int GetInt(string key, int fallback)
    {
        var value = System.Environment.GetEnvironmentVariable(key);
        if (string.IsNullOrEmpty(value))
        {
            return fallback;
        }

        if (!int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed))
        {
            throw new InvalidOperationException($"{key} must be an integer, got '{value}'");
        }

        return parsed;
    }

    /// <summary>
    /// Parses a Go-style duration ("30s", "5m", "1500ms").
    /// </summary>
    /// <remarks>
    /// <c>.env.example</c> uses that format for the shutdown keys, so all five
    /// services have to understand it. An unparseable value falls back rather
    /// than failing startup — these are tuning knobs, not correctness-critical.
    /// </remarks>
    private static TimeSpan GetDuration(string key, TimeSpan fallback)
    {
        var raw = System.Environment.GetEnvironmentVariable(key)?.Trim();
        if (string.IsNullOrEmpty(raw))
        {
            return fallback;
        }

        string digits;
        double unitMilliseconds;

        if (raw.EndsWith("ms", StringComparison.Ordinal))
        {
            digits = raw[..^2];
            unitMilliseconds = 1;
        }
        // Single-character suffixes use the char overload: it needs no
        // StringComparison and skips the culture machinery entirely (CA1865).
        else if (raw.EndsWith('s'))
        {
            digits = raw[..^1];
            unitMilliseconds = 1_000;
        }
        else if (raw.EndsWith('m'))
        {
            digits = raw[..^1];
            unitMilliseconds = 60_000;
        }
        else if (raw.EndsWith('h'))
        {
            digits = raw[..^1];
            unitMilliseconds = 3_600_000;
        }
        else
        {
            return fallback;
        }

        return double.TryParse(digits, NumberStyles.Float, CultureInfo.InvariantCulture, out var n)
            ? TimeSpan.FromMilliseconds(n * unitMilliseconds)
            : fallback;
    }
}
