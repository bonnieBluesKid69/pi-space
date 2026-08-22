using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PiSpace.Windows;

internal sealed class ProviderConfig
{
    private static readonly string DefaultConfigPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".pi", "agent", "models.json");
    private readonly JsonObject root;

    private ProviderConfig(JsonObject root) => this.root = root;

    public static ProviderConfig Load(string? configPath = null)
    {
        try { return new ProviderConfig(JsonNode.Parse(File.ReadAllText(configPath ?? DefaultConfigPath))?.AsObject() ?? new JsonObject()); }
        catch { return new ProviderConfig(new JsonObject()); }
    }

    public bool IsConfigured(string name) => Provider(name)?["apiKey"]?.GetValue<string>() is { Length: > 0 };
    public string? BaseUrl(string name) => Provider(name)?["baseUrl"]?.GetValue<string>();

    private JsonObject? Provider(string name) => root["providers"]?[name] as JsonObject;

    public static void Save(string agentRouterKey, string tokenRouterKey, string tabiTokenKey, string tabiTokenBaseUrl, string? configPath = null, bool restrictAccess = true, string openRouterKey = "")
    {
        configPath ??= DefaultConfigPath;
        agentRouterKey = agentRouterKey.Trim();
        tokenRouterKey = tokenRouterKey.Trim();
        tabiTokenKey = tabiTokenKey.Trim();
        tabiTokenBaseUrl = tabiTokenBaseUrl.Trim();
        openRouterKey = openRouterKey.Trim();
        if (openRouterKey.Length > 0 && !openRouterKey.StartsWith("sk-or-")) throw new InvalidOperationException("OpenRouter keys must begin with sk-or-.");

        if (agentRouterKey.Length > 0 && !agentRouterKey.StartsWith("sk-")) throw new InvalidOperationException("AgentRouter keys must begin with sk-.");
        if (tokenRouterKey.Length > 0 && !tokenRouterKey.StartsWith("sk-") && !tokenRouterKey.StartsWith("tr_")) throw new InvalidOperationException("TokenRouter keys must begin with sk- or tr_.");

        var current = Load(configPath);
        var providers = current.root["providers"] as JsonObject ?? new JsonObject();
        current.root["providers"] = providers;
        providers["agentrouter"] = ManagedProvider(providers["agentrouter"] as JsonObject, "agentrouter", agentRouterKey, null);
        providers["tokenrouter"] = ManagedProvider(providers["tokenrouter"] as JsonObject, "tokenrouter", tokenRouterKey, null);
        providers["openrouter"] = ManagedProvider(providers["openrouter"] as JsonObject, "openrouter", openRouterKey, null);

        var existingTabi = providers["tabitoken"] as JsonObject;
        var existingTabiKey = existingTabi?["apiKey"]?.GetValue<string>()?.Trim() ?? "";
        var effectiveTabiKey = tabiTokenKey.Length > 0 ? tabiTokenKey : existingTabiKey;
        if (effectiveTabiKey.Length > 0)
        {
            var savedTabiUrl = existingTabi?["baseUrl"]?.GetValue<string>()?.Trim() ?? "";
            var effectiveTabiUrl = (tabiTokenBaseUrl.Length > 0 ? tabiTokenBaseUrl : savedTabiUrl).TrimEnd('/');
            if (!Uri.TryCreate(effectiveTabiUrl, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps || string.IsNullOrWhiteSpace(uri.Host)) throw new InvalidOperationException("Enter the HTTPS Base URL shown in your TabiToken dashboard.");
            providers["tabitoken"] = ManagedProvider(existingTabi, "tabitoken", tabiTokenKey, effectiveTabiUrl);
        }

        Directory.CreateDirectory(Path.GetDirectoryName(configPath)!);
        var backup = configPath + ".backup";
        if (File.Exists(configPath)) File.Copy(configPath, backup, true);
        var temporary = configPath + ".tmp";
        File.WriteAllText(temporary, current.root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, configPath, true);
        if (restrictAccess) RestrictToCurrentUser(configPath);
    }

    private static JsonObject ManagedProvider(JsonObject? existing, string name, string key, string? baseUrl)
    {
        var provider = existing?.DeepClone().AsObject() ?? new JsonObject();
        provider["baseUrl"] = name switch
        {
            "agentrouter" => "https://agentrouter.org/v1",
            "tokenrouter" => "https://api.tokenrouter.io/v1",
            "openrouter" => "https://openrouter.ai/api/v1",
            _ => baseUrl ?? provider["baseUrl"]?.GetValue<string>(),
        };
        provider["api"] = name == "tabitoken" ? "anthropic-messages" : "openai-completions";
        if (name != "tabitoken") provider["authHeader"] = true;
        else { provider.Remove("authHeader"); provider.Remove("compat"); provider.Remove("headers"); }
        if (key.Length > 0) provider["apiKey"] = key;
        if (name == "agentrouter")
        {
            provider["headers"] = new JsonObject
            {
                ["Originator"] = "codex_cli_rs",
                ["User-Agent"] = "codex_cli_rs/0.101.0 (Pi Space; Windows)",
                ["Version"] = "0.101.0",
            };
            provider["compat"] = new JsonObject
            {
                ["supportsDeveloperRole"] = false,
                ["supportsReasoningEffort"] = false,
            };
        }
        provider["models"] = Models(name);
        return provider;
    }

    private static JsonArray Models(string provider)
    {
        var ids = provider switch
        {
            "agentrouter" => new[] { "gpt-5.6-sol", "claude-opus-5", "claude-opus-4-8" },
            "openrouter" => new[] { "stealth/ox-alpha" },
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
                ["contextWindow"] = provider == "agentrouter" ? 128000 : provider == "openrouter" ? 1048576 : 200000,
                ["maxTokens"] = provider == "agentrouter" ? 16384 : provider == "openrouter" ? 131072 : 32768,
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
