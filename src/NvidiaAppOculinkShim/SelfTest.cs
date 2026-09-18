using System.Text.Json.Nodes;

namespace NvidiaAppOculinkShim;

internal static class SelfTest
{
    public static int Run()
    {
        var payload = new JsonObject
        {
            ["dIDa"] = new JsonArray("2D04_10DE_2D04_6688_1"),
            ["iLp"] = "1",
            ["osC"] = "10.0.26200",
            ["osB"] = "8973",
            ["GFPV"] = "610.74",
        };
        var path = DriverRequestRewriter.RecommendationEndpoint +
            Uri.EscapeDataString(payload.ToJsonString());
        var result = DriverRequestRewriter.Rewrite(path);

        Require(result.Changed, "expected request to change");
        Require(result.Route == "driver-recommendation", "unexpected route");
        Require(result.After?["iLp"]?.GetValue<string>() == "0", "iLp was not normalized");
        Require(result.After?["osC"]?.GetValue<string>() == "10.0.26200", "osC was modified");
        Require(result.After?["osB"]?.GetValue<string>() == "8973", "osB was modified");
        Require(result.Path.Contains("610.74", StringComparison.Ordinal),
            "unrelated GFPV field was not preserved");

        payload["iLp"] = 1;
        var numeric = DriverRequestRewriter.Rewrite(
            DriverRequestRewriter.DetailsEndpoint +
            Uri.EscapeDataString(payload.ToJsonString()));
        Require(numeric.After?["iLp"]?.GetValue<int>() == 0,
            "numeric iLp type was not preserved");

        var passThrough = DriverRequestRewriter.Rewrite(
            "/nvidia_web_services/controller.gfeclientaffinity.php/example");
        Require(!passThrough.Changed && passThrough.Route == "metadata-pass-through",
            "non-driver metadata should pass through unchanged");

        Console.WriteLine("Self-test passed: driver classification normalization is scoped.");
        return 0;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }
}
