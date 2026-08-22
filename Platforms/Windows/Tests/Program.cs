using System.Text.Json.Nodes;
using PiSpace.Windows;

var directory = Path.Combine(Path.GetTempPath(), "pi-space-provider-config-" + Guid.NewGuid().ToString("N"));
var configPath = Path.Combine(directory, "models.json");
Directory.CreateDirectory(directory);

try
{
    ProviderConfig.Save("  sk-agent-test  ", "", "", "https://api.tabitoken.com/v1", configPath, restrictAccess: false);
    var config = ProviderConfig.Load(configPath);
    Assert(config.IsConfigured("agentrouter"), "AgentRouter-only Settings save did not configure AgentRouter.");
    Assert(!config.IsConfigured("openrouter"), "OpenRouter was unexpectedly configured.");

    var root = JsonNode.Parse(File.ReadAllText(configPath))!.AsObject();
    var providers = root["providers"]!.AsObject();
    var agent = providers["agentrouter"]!.AsObject();
    Assert(agent["apiKey"]!.GetValue<string>() == "sk-agent-test", "AgentRouter key was not trimmed before saving.");
    Assert(agent["baseUrl"]!.GetValue<string>() == "https://agentrouter.org/v1", "AgentRouter Base URL is incorrect.");
    Assert(agent["api"]!.GetValue<string>() == "openai-completions", "AgentRouter API type is incorrect.");
    Assert(agent["authHeader"]!.GetValue<bool>(), "AgentRouter authHeader is not enabled.");
    Assert(agent["headers"]?["Originator"]?.GetValue<string>() == "codex_cli_rs", "AgentRouter Originator header is missing.");
    Assert(agent["headers"]?["User-Agent"]?.GetValue<string>()?.Contains("Pi Space; Windows") == true, "AgentRouter Windows User-Agent is missing.");
    Assert(agent["compat"]?["supportsDeveloperRole"]?.GetValue<bool>() == false, "AgentRouter developer-role compatibility is incorrect.");
    Assert(agent["compat"]?["supportsReasoningEffort"]?.GetValue<bool>() == false, "AgentRouter reasoning compatibility is incorrect.");

    ProviderConfig.Save("", "", "", "https://api.tabitoken.com/v1", configPath, restrictAccess: false, openRouterKey: "sk-or-test");
    config = ProviderConfig.Load(configPath);
    Assert(config.IsConfigured("openrouter"), "OpenRouter key was not saved.");
    Assert(config.BaseUrl("openrouter") == "https://openrouter.ai/api/v1", "OpenRouter Base URL is incorrect.");

    Assert(!config.IsConfigured("tabitoken"), "Default TabiToken URL created a false TabiToken configuration.");
    Assert(config.IsConfigured("tokenrouter"), "TokenRouter key was not saved.");
    Assert(!config.IsConfigured("tabitoken"), "Untouched TabiToken became configured.");

    ProviderConfig.Save("", "", "sk-tabi-test", "https://example.com/v1/", configPath, restrictAccess: false);
    config = ProviderConfig.Load(configPath);
    Assert(config.IsConfigured("tabitoken"), "TabiToken key was not saved.");
    Assert(config.BaseUrl("tabitoken") == "https://example.com/v1", "TabiToken Base URL was not normalized.");

    Assert(UpdateService.IsNewer("v5.0", "4.9.3"), "The major voice release was not detected as newer.");
    Assert(!UpdateService.IsNewer("v5.0", "5.0"), "The installed release was treated as newer.");
    Assert(!UpdateService.IsNewer("v4.9.3", "5.0"), "An older release was treated as newer.");
    var checksum = new string('a', 64);
    Assert(UpdateService.ParseChecksum($"{checksum}  Pi-Space-Windows-x64.zip\n", "Pi-Space-Windows-x64.zip") == checksum, "The release checksum could not be parsed.");
    Assert(UpdateService.ParseChecksum($"{checksum}  another.zip\n", "Pi-Space-Windows-x64.zip") is null, "A checksum for the wrong asset was accepted.");

    Assert(WindowsKokoroService.IsVoiceSupported("af_heart"), "The default Kokoro voice is not supported.");
    Assert(!WindowsKokoroService.IsVoiceSupported("unsupported"), "An unknown Kokoro voice was accepted.");
    Assert(WindowsKokoroService.PinnedAssetHashes.Count == 4, "The Windows Kokoro asset contract is incomplete.");
    Assert(WindowsKokoroService.PinnedAssetHashes.All(item => item.Value.Length == 64 && item.Value.All(Uri.IsHexDigit)), "A pinned Kokoro asset hash is invalid.");
    var incompleteKokoro = Path.Combine(directory, "kokoro-runtime");
    Directory.CreateDirectory(incompleteKokoro);
    File.WriteAllText(Path.Combine(incompleteKokoro, "status.json"), "{}");
    Assert(!WindowsKokoroService.ValidateInstallation(incompleteKokoro), "An incomplete Kokoro runtime was treated as installed.");

    Console.WriteLine("Windows provider, update, and Kokoro checks passed.");
}
finally
{
    try { Directory.Delete(directory, true); } catch { }
}

static void Assert(bool condition, string message)
{
    if (!condition) throw new InvalidOperationException(message);
}
