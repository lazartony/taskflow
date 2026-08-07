using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json.Serialization;

namespace TaskFlow.Api.Http;

/// <summary>
/// The HTTP response envelope and the request-scoped identifiers every
/// TaskFlow response carries.
/// </summary>
/// <remarks>
/// The shape here is normative — the language-neutral conformance suite asserts
/// it across all five implementations. Do not change a field name without
/// changing the other four services too.
///
/// Property names are pinned with <see cref="JsonPropertyNameAttribute"/> rather
/// than relying on the default camelCase policy, so a change to the global
/// serializer options cannot silently break the contract.
/// </remarks>
public sealed record Meta(
    [property: JsonPropertyName("requestId")] string RequestId,
    [property: JsonPropertyName("timestamp")] string Timestamp,
    [property: JsonPropertyName("traceId")] string TraceId);

public sealed record SuccessEnvelope(
    [property: JsonPropertyName("success")] bool Success,
    [property: JsonPropertyName("data")] object Data,
    [property: JsonPropertyName("meta")] Meta Meta);

public sealed record ErrorBody(
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("message")] string Message,
    [property: JsonPropertyName("details")]
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    object? Details);

public sealed record ErrorEnvelope(
    [property: JsonPropertyName("success")] bool Success,
    [property: JsonPropertyName("error")] ErrorBody Error,
    [property: JsonPropertyName("meta")] Meta Meta);

public static class Envelope
{
    private const string Alphabet =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

    /// <summary>Key under which the request ID lives in <c>HttpContext.Items</c>.</summary>
    public const string RequestIdItemKey = "taskflow.requestId";

    /// <summary>Key under which the trace ID lives in <c>HttpContext.Items</c>.</summary>
    public const string TraceIdItemKey = "taskflow.traceId";

    /// <summary><c>req_</c> followed by 12 alphanumeric characters.</summary>
    public static string NewRequestId()
    {
        var chars = new char[12];
        for (var i = 0; i < chars.Length; i++)
        {
            chars[i] = Alphabet[RandomNumberGenerator.GetInt32(Alphabet.Length)];
        }

        return "req_" + new string(chars);
    }

    /// <summary>32 lowercase hex characters.</summary>
    /// <remarks>
    /// TODO(Phase 2): delete this. Once the OpenTelemetry SDK is wired up the
    /// trace ID must come from <c>Activity.Current</c>, or <c>meta.traceId</c>
    /// will not resolve in Tempo. Random is a placeholder that keeps the
    /// envelope shape correct in the meantime.
    /// </remarks>
    public static string NewTraceId()
    {
        var bytes = RandomNumberGenerator.GetBytes(16);
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    /// <summary>ISO-8601 with milliseconds and a literal Z suffix.</summary>
    public static string NowIso() =>
        DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture);

    public static Meta MetaFor(HttpContext context)
    {
        var requestId = context.Items.TryGetValue(RequestIdItemKey, out var rid) && rid is string r
            ? r
            : NewRequestId();
        var traceId = context.Items.TryGetValue(TraceIdItemKey, out var tid) && tid is string t
            ? t
            : NewTraceId();

        return new Meta(requestId, NowIso(), traceId);
    }

    /// <summary>Renders the <c>{success: true, data, meta}</c> envelope.</summary>
    public static IResult Success(HttpContext context, int statusCode, object data) =>
        Results.Json(
            new SuccessEnvelope(true, data, MetaFor(context)),
            statusCode: statusCode);

    /// <summary>Renders the <c>{success: false, error, meta}</c> envelope.</summary>
    public static IResult Failure(
        HttpContext context,
        int statusCode,
        string code,
        string message,
        object? details = null) =>
        Results.Json(
            new ErrorEnvelope(false, new ErrorBody(code, message, details), MetaFor(context)),
            statusCode: statusCode);

    /// <summary>
    /// The placeholder for every <c>/api/v1</c> route that is not built yet.
    /// </summary>
    /// <remarks>
    /// It exists so the conformance suite fails loudly and specifically rather
    /// than returning a confusing 404.
    ///
    /// TODO(Phase 1): as each endpoint group is implemented, map it in
    /// Program.cs. ASP.NET routing prefers the more specific route, so the
    /// catch-all yields automatically — no ordering to maintain. When this
    /// stops being reachable, Phase 1 is done.
    /// </remarks>
    public static IResult NotImplemented(HttpContext context) =>
        Failure(
            context,
            StatusCodes.Status501NotImplemented,
            "NOT_IMPLEMENTED",
            "Not implemented yet — see docs/learning-roadmap.md Phase 1");
}
