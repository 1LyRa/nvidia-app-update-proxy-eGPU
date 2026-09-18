using System.Text.Json;
using System.Text.Json.Nodes;

namespace NvidiaAppOculinkShim;

internal sealed record RewriteResult(
    string Path,
    string Route,
    bool Changed,
    JsonObject? Before,
    JsonObject? After);

internal static class DriverRequestRewriter
{
    internal const string RecommendationEndpoint =
        "/nvidia_web_services/controller.gfeclientcontent.NG.php/" +
        "com.nvidia.services.GFEClientContent_NG.getDispDrvrByDevid/";
    internal const string DetailsEndpoint =
        "/nvidia_web_services/controller.gfeclientcontent.NG.php/" +
        "com.nvidia.services.GFEClientContent_NG.getDispDrvrDtlsByDevid/";

    private static readonly (string Prefix, string Route)[] DriverEndpoints =
    [
        (RecommendationEndpoint, "driver-recommendation"),
        (DetailsEndpoint, "driver-details"),
    ];

    internal static RewriteResult Rewrite(string rawPath)
    {
        var endpoint = DriverEndpoints.FirstOrDefault(item =>
            rawPath.StartsWith(item.Prefix, StringComparison.Ordinal));
        if (endpoint.Prefix is null)
            return new RewriteResult(rawPath, "metadata-pass-through", false, null, null);

        var encoded = rawPath[endpoint.Prefix.Length..];
        if (encoded.Length is 0 or > 128 * 1024 || encoded.Contains('/'))
            throw new InvalidDataException("Unexpected NVIDIA driver metadata path");

        var payload = JsonNode.Parse(Uri.UnescapeDataString(encoded)) as JsonObject
            ?? throw new InvalidDataException("Driver metadata payload must be an object");
        if (payload["dIDa"] is not JsonArray deviceIds ||
            deviceIds.Count is < 1 or > 32 ||
            deviceIds.Any(value =>
                value is not JsonValue jsonValue ||
                !jsonValue.TryGetValue<string>(out var id) ||
                id.Length > 256))
            throw new InvalidDataException("Driver metadata payload has invalid device IDs");

        var before = Snapshot(payload);
        if (NodeText(payload["iLp"]) == "1")
            payload["iLp"] = payload["iLp"]?.GetValueKind() == JsonValueKind.Number ? 0 : "0";


        var after = Snapshot(payload);
        var changed = before.ToJsonString() != after.ToJsonString();
        var rewritten = endpoint.Prefix + Uri.EscapeDataString(
            payload.ToJsonString(new JsonSerializerOptions { WriteIndented = false }));
        return new RewriteResult(rewritten, endpoint.Route, changed, before, after);
    }

    private static JsonObject Snapshot(JsonObject payload) => new()
    {
        ["iLp"] = payload["iLp"]?.DeepClone(),
        ["osC"] = payload["osC"]?.DeepClone(),
        ["osB"] = payload["osB"]?.DeepClone(),
    };

    private static string NodeText(JsonNode? node)
    {
        if (node is not JsonValue value)
            return "";
        if (value.TryGetValue<string>(out var text))
            return text;
        return value.ToJsonString();
    }
}
