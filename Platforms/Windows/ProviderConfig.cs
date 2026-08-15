using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PiSpace.Windows;

internal sealed class ProviderConfig
{
    private static readonly string ConfigPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".pi", "agent", "models.json");
    private readonly JsonObject root;

    private ProviderConfig(JsonObject root) => this.root = root;

    public static ProviderConfig Load()
    {
        try { return new ProviderConfig(JsonNode.Parse(File.ReadAllText(ConfigPath))?.AsObject() ?? new JsonObject()); }
        catch { return new ProviderConfig(new JsonObject()); }
    }

    public bool IsConfigured(string name) => Provider(name)?["apiKey"]?.GetValue<string>() is { Length: > 0 };
    public string? BaseUrl(string name) => Provider(name)?["baseUrl"]?.GetValue<string>();

    private JsonObject? Provider(string name) => root["providers"]?[name] as JsonObject;

    public static void Save(string agentRouterKey, string tokenRouterKey, string tabiTokenKey, string tabiTokenBaseUrl)
    {
        if (agentRouterKey.Length > 0 && !agentRouterKey.StartsWith("sk-")) throw new InvalidOperationException("AgentRouter keys must begin with sk-.");
        if (tokenRouterKey.Length > 0 && !tokenRouterKey.StartsWith("sk-") && !tokenRouterKey.StartsWith("tr_")) throw new InvalidOperationException("TokenRouter keys must begin with sk- or tr_.");

        var current = Load();
        var providers = current.root["providers"] as JsonObject ?? new JsonObject();
        current.root["providers"] = providers;
        providers["agentrouter"] = ManagedProvider(providers["agentrouter"] as JsonObject, "agentrouter", agentRouterKey, null);
        providers["tokenrouter"] = ManagedProvider(providers["tokenrouter"] as JsonObject, "tokenrouter", tokenRouterKey, null);

        var existingTabi = providers["tabitoken"] as JsonObject;
        var effectiveTabiKey = tabiTokenKey.Length > 0 ? tabiTokenKey : existingTabi?["apiKey"]?.GetValue<string>() ?? "";
        var effectiveTabiUrl = tabiTokenBaseUrl.Length > 0 ? tabiTokenBaseUrl : existingTabi?["baseUrl"]?.GetValue<string>() ?? "";
        if (effectiveTabiKey.Length > 0 || effectiveTabiUrl.Length > 0)
        {
            if (effectiveTabiKey.Length == 0) throw new InvalidOperationException("Enter the TabiToken API key.");
            if (!Uri.TryCreate(effectiveTabiUrl, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps) throw new InvalidOperationException("Enter the HTTPS Base URL shown in your TabiToken dashboard.");
            providers["tabitoken"] = ManagedProvider(existingTabi, "tabitoken", tabiTokenKey, effectiveTabiUrl.TrimEnd('/'));
        }

        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
        var backup = ConfigPath + ".backup";
        if (File.Exists(ConfigPath)) File.Copy(ConfigPath, backup, true);
        var temporary = ConfigPath + ".tmp";
        File.WriteAllText(temporary, current.root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, ConfigPath, true);
        RestrictToCurrentUser(ConfigPath);
    }

    private static JsonObject ManagedProvider(JsonObject? existing, string name, string key, string? baseUrl)
    {
        var provider = existing?.DeepClone().AsObject() ?? new JsonObject();
        provider["baseUrl"] = name switch
        {
            "agentrouter" => "https://agentrouter.org/v1",
            "tokenrouter" => "https://api.tokenrouter.io/v1",
            _ => baseUrl ?? provider["baseUrl"]?.GetValue<string>(),
        };
        provider["api"] = name == "tabitoken" ? "anthropic-messages" : "openai-completions";
        if (name != "tabitoken") provider["authHeader"] = true;
        else { provider.Remove("authHeader"); provider.Remove("compat"); }
        if (key.Length > 0) provider["apiKey"] = key;
        provider["models"] = Models(name);
        return provider;
    }

    private static JsonArray Models(string provider)
    {
        var ids = provider switch
        {
            "agentrouter" => new[] { "gpt-5.6-sol", "claude-opus-5", "claude-opus-4-8" },
            "tokenrouter" => new[] { "moonshotai/kimi-k3-free" },
            _ => new[] { "claude-opus-5", "claude-opus-5-thinking", "claude-opus-4-8", "claude-opus-4-8-thinking" },
        };
        var result = new JsonArray();
        foreach (var id in ids)
        {
            result.Add(new JsonObject
            {
                ["id"] = id, ["name"] = id,
                ["reasoning"] = provider != "tabitoken" || id.EndsWith("-thinking"),
                ["input"] = new JsonArray("text", "image"),
                ["contextWindow"] = provider == "agentrouter" ? 128000 : 200000,
                ["maxTokens"] = provider == "agentrouter" ? 16384 : 32768,
            });
        }
        return result;
    }

    private static void RestrictToCurrentUser(string path)
    {
        var identity = WindowsIdentity.GetCurrent().User ?? throw new InvalidOperationException("Could not determine the current Windows user.");
        var security = new FileSecurity();
        security.SetOwner(identity);
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new FileSystemAccessRule(identity, FileSystemRights.FullControl, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }
}
