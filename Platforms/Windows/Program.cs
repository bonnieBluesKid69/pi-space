using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace PiSpace.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}

internal sealed class MainForm : Form
{
    private readonly WebView2 web = new() { Dock = DockStyle.Fill };
    private readonly PiRpcClient rpc = new();
    private readonly UpdateService updater = new(Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0");
    private readonly WindowsKokoroService kokoro = new(Path.Combine(AppContext.BaseDirectory, "Resources", "kokoro-windows-synthesize.py"));
    private readonly WindowsVoiceConversation voice;
    private readonly JsonSerializerOptions json = new(JsonSerializerDefaults.Web);
    private readonly List<string> sessions = [];
    private string workspace = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    private string? selectedProvider;
    private string? selectedModel;
    private bool ready;

    private static readonly object[] ManagedModels =
    [
        new { choice = "ox-alpha", variant = "Ox Alpha", provider = "openrouter", providerLabel = "OpenRouter", id = "stealth/ox-alpha", name = "stealth/ox-alpha", contextWindow = 1048576, maxOutputTokens = 131072, reasoning = true, inputModes = new[] { "Text", "Images", "Video" } },
        new { choice = "opus-5", variant = "Claude Opus 5", provider = "agentrouter", providerLabel = "AgentRouter", id = "claude-opus-5", name = "claude-opus-5", contextWindow = 128000, maxOutputTokens = 16384, reasoning = true, inputModes = new[] { "Text", "Images" } },
        new { choice = "opus-5", variant = "Claude Opus 5", provider = "tabitoken", providerLabel = "TabiToken", id = "claude-opus-5", name = "claude-opus-5", contextWindow = 200000, maxOutputTokens = 32768, reasoning = false, inputModes = new[] { "Text", "Images" } },
        new { choice = "opus-5-thinking", variant = "Claude Opus 5 Thinking", provider = "tabitoken", providerLabel = "TabiToken", id = "claude-opus-5-thinking", name = "claude-opus-5-thinking", contextWindow = 200000, maxOutputTokens = 32768, reasoning = true, inputModes = new[] { "Text", "Images" } },
        new { choice = "opus-4.8", variant = "Claude Opus 4.8", provider = "agentrouter", providerLabel = "AgentRouter", id = "claude-opus-4-8", name = "claude-opus-4-8", contextWindow = 128000, maxOutputTokens = 16384, reasoning = true, inputModes = new[] { "Text", "Images" } },
        new { choice = "opus-4.8", variant = "Claude Opus 4.8", provider = "tabitoken", providerLabel = "TabiToken", id = "claude-opus-4-8", name = "claude-opus-4-8", contextWindow = 200000, maxOutputTokens = 32768, reasoning = false, inputModes = new[] { "Text", "Images" } },
        new { choice = "opus-4.8-thinking", variant = "Claude Opus 4.8 Thinking", provider = "tabitoken", providerLabel = "TabiToken", id = "claude-opus-4-8-thinking", name = "claude-opus-4-8-thinking", contextWindow = 200000, maxOutputTokens = 32768, reasoning = true, inputModes = new[] { "Text", "Images" } },
        new { choice = "kimi-k3-free", variant = "Kimi K3 Free", provider = "tokenrouter", providerLabel = "TokenRouter", id = "moonshotai/kimi-k3-free", name = "moonshotai/kimi-k3-free", contextWindow = 200000, maxOutputTokens = 32768, reasoning = true, inputModes = new[] { "Text", "Images" } },
    ];

    public MainForm()
    {
        voice = new WindowsVoiceConversation(kokoro);
        Text = "Pi Space";
        MinimumSize = new Size(900, 620);
        Size = new Size(1120, 760);
        StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(web);
        rpc.EventReceived += ForwardRpc;
        rpc.Failed += message => Ui(() => Emit("appError", new { message }));
        updater.StateChanged += state => Ui(() => Emit("updateState", state));
        kokoro.InstallStateChanged += (state, text) => Ui(() => { Emit("kokoroInstallState", new { state, text }); SyncProviderSettings(); });
        voice.StateChanged += (state, text) => Ui(() =>
        {
            Emit("voiceState", new { state, text });
            if (state == "error" && text.Contains("speech-recognition pack", StringComparison.OrdinalIgnoreCase))
                Emit("appError", new { message = text + " Open Windows Settings → Time & language → Speech to install one." });
        });
        voice.TranscriptChanged += (text, final) => Ui(() => Emit("voiceTranscript", new { text, final }));
        voice.PromptReady += (text, interrupt) => Ui(() => Emit("voicePrompt", new { text, conversation = true, interrupt }));
        voice.AbortRequested += () => rpc.Send(new { type = "abort" });
        voice.SettingsChanged += () => Ui(() => { SyncProviderSettings(); EmitVoiceSettings(); });
        Load += async (_, _) => await InitializeAsync();
        FormClosed += (_, _) => { voice.Dispose(); kokoro.Dispose(); rpc.Dispose(); };
    }

    private async Task InitializeAsync()
    {
        try
        {
            await web.EnsureCoreWebView2Async();
            web.CoreWebView2.Settings.AreDevToolsEnabled = false;
            web.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
            web.CoreWebView2.WebMessageReceived += OnWebMessage;
            web.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
            var resources = Path.Combine(AppContext.BaseDirectory, "Resources");
            web.CoreWebView2.SetVirtualHostNameToFolderMapping("app.pispace.local", resources, CoreWebView2HostResourceAccessKind.DenyCors);
            web.Source = new Uri("https://app.pispace.local/PiSpace.html");
        }
        catch (Exception error)
        {
            MessageBox.Show($"Pi Space could not start WebView2. Install the Microsoft Edge WebView2 Runtime.\n\n{error.Message}", "Pi Space", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Close();
        }
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!e.IsSuccess) return;
        ready = true;
        Emit("hostCapabilities", new { bridgeVersion = 1, platform = "windows", voice = true, wakePhrases = false, kokoro = true, fileDialogs = true, secureProviderConfig = true, updates = true, appVersion = updater.CurrentVersion });
        Emit("workspaceChosen", new { path = workspace });
        Emit("instructionsLoaded", new { text = ReadInstructions() });
        ChooseInitialModel();
        SyncProviderSettings();
        StartRpc(false);
        _ = updater.CheckAsync();
    }

    private void StartRpc(bool continuing)
    {
        try
        {
            rpc.Start(workspace, continuing, selectedProvider, selectedModel);
            _ = Task.Delay(900).ContinueWith(_ => Ui(Refresh));
        }
        catch (Exception error) { Emit("appError", new { message = error.Message }); }
    }

    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var document = JsonDocument.Parse(e.WebMessageAsJson);
            HandleAction(document.RootElement);
        }
        catch (Exception error) { Emit("appError", new { message = error.Message }); }
    }

    private void HandleAction(JsonElement body)
    {
        var action = String(body, "action");
        switch (action)
        {
            case "prompt": SendPrompt(body); break;
            case "abort": voice.End(false); rpc.Send(new { type = "abort" }); break;
            case "newSession": voice.End(false); rpc.Send(new { type = "new_session" }); break;
            case "compact": rpc.Send(new { type = "compact" }); break;
            case "refresh": Refresh(); break;
            case "sessions": LoadSessions(); break;
            case "switchSession": SwitchSession(Int(body, "index")); break;
            case "chooseWorkspace": ChooseWorkspace(false); break;
            case "chooseAndApplyWorkspace": ChooseWorkspace(true); break;
            case "applyWorkspace": ApplyWorkspace(String(body, "path")); break;
            case "chooseAttachments": ChooseAttachments(); break;
            case "copyText": Clipboard.SetText(String(body, "text")); break;
            case "setThinking": rpc.Send(new { type = "set_thinking_level", level = String(body, "level") }); break;
            case "setModel": SetModel(String(body, "provider"), String(body, "model")); break;
            case "saveInstructions": SaveInstructions(String(body, "text")); break;
            case "saveProviderKeys": SaveProviderKeys(body); break;
            case "updateProviderKey": UpdateProviderKey(String(body, "provider"), String(body, "key")); break;
            case "checkForUpdates": _ = updater.CheckAsync(true); break;
            case "installUpdate": _ = updater.InstallAsync(); break;
            case "rpcCommand": SendRpcCommand(body); break;
            case "rpcToggle": rpc.Send(new { type = String(body, "command"), enabled = Bool(body, "enabled") }); break;
            case "extensionUIResponse": SendExtensionUiResponse(body); break;
            case "voiceStart": voice.Start(); break;
            case "voiceEnd": voice.End(); break;
            case "voiceMute": voice.SetMuted(Bool(body, "muted")); break;
            case "voicePause": voice.TogglePause(); break;
            case "voiceRepeat": voice.RepeatLastResponse(); break;
            case "setVoicePace": voice.SetPace(String(body, "value")); break;
            case "setVoiceLength": voice.SetResponseLength(String(body, "value")); break;
            case "setWakePhrases": break;
            case "setKokoroVoice":
                try { kokoro.SetVoice(String(body, "identifier")); SyncProviderSettings(); }
                catch (Exception error) { Emit("appError", new { message = error.Message }); }
                break;
            case "installKokoro": _ = kokoro.InstallAsync(); break;
            case "openKokoroLog": kokoro.OpenLog(); break;
            case "openVoiceSettings": Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); break;
            case "previewVoice": _ = kokoro.PreviewAsync(); break;
            case "setVoice": break;
        }
    }

    private void SendPrompt(JsonElement body)
    {
        var text = String(body, "text");
        var custom = ReadInstructions();
        var context = new List<string>();
        var images = new List<object>();
        if (body.TryGetProperty("attachments", out var attachments) && attachments.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in attachments.EnumerateArray().Take(5))
            {
                var name = String(item, "name");
                var mime = String(item, "mimeType");
                var data = String(item, "data");
                if (mime == "application/x-directory") context.Add($"Attached local folder: {System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(data))}. Inspect it with the available tools.");
                else if (mime.StartsWith("image/")) images.Add(new { type = "image", data, mimeType = mime });
                else
                {
                    var bytes = Convert.FromBase64String(data);
                    if (bytes.Length <= 1_000_000) context.Add($"<attached_file name=\"{name}\" mime_type=\"{mime}\">\n{System.Text.Encoding.UTF8.GetString(bytes)}\n</attached_file>");
                    else context.Add($"Attached binary file: {name} ({mime}).");
                }
            }
        }
        var userText = string.Join("\n\n", new[] { text }.Concat(context).Where(value => !string.IsNullOrWhiteSpace(value)));
        var message = string.IsNullOrWhiteSpace(custom) ? userText : $"<persistent_user_instructions>\n{custom}\n</persistent_user_instructions>\n\n<user_message>\n{userText}\n</user_message>";
        rpc.Send(new Dictionary<string, object?> { ["type"] = "prompt", ["message"] = message, ["images"] = images, ["streamingBehavior"] = "steer" });
    }

    private void Refresh()
    {
        foreach (var command in new[] { "get_state", "get_messages", "get_available_models", "get_available_thinking_levels", "get_session_stats" }) rpc.Send(new { type = command });
        LoadSessions();
    }

    private void ForwardRpc(JsonElement message)
    {
        var type = String(message, "type");
        if (type == "message_update" && message.TryGetProperty("assistantMessageEvent", out var update) && String(update, "type") == "text_delta")
            voice.ReceiveResponseChunk(String(update, "delta"));
        if (type == "agent_end")
        {
            var fallback = "";
            if (message.TryGetProperty("messages", out var messages) && messages.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in messages.EnumerateArray().Reverse())
                {
                    if (String(item, "role") != "assistant") continue;
                    fallback = MessageText(item);
                    break;
                }
            }
            voice.FinishResponse(fallback);
        }

        Ui(() =>
        {
            EmitRaw("rpcEvent", message.GetRawText());
            if (String(message, "type") == "agent_settled" || String(message, "type") == "compaction_end") rpc.Send(new { type = "get_session_stats" });
            if (String(message, "type") != "response" || !Bool(message, "success", true)) return;
            var command = String(message, "command");
            if (command is "switch_session" or "new_session")
            {
                rpc.Send(new { type = "get_messages" });
                rpc.Send(new { type = "get_state" });
                rpc.Send(new { type = "get_session_stats" });
            }
            else if (command == "compact")
            {
                rpc.Send(new { type = "get_messages" });
                rpc.Send(new { type = "get_session_stats" });
            }
            else if (command is "set_model" or "set_thinking_level")
            {
                rpc.Send(new { type = "get_state" });
                rpc.Send(new { type = "get_available_thinking_levels" });
                rpc.Send(new { type = "get_session_stats" });
            }
        });
    }

    private void LoadSessions()
    {
        sessions.Clear();
        var root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".pi", "agent", "sessions");
        if (Directory.Exists(root)) sessions.AddRange(Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories).OrderByDescending(File.GetLastWriteTimeUtc));
        var list = sessions.Select((path, index) =>
        {
            var (name, summary) = SessionSummary(path);
            return new { index, name, summary, date = File.GetLastWriteTime(path).ToString("g") };
        });
        Emit("sessionsLoaded", new { sessions = list });
    }

    private static (string, string) SessionSummary(string path)
    {
        try
        {
            foreach (var line in File.ReadLines(path).Take(500))
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (String(root, "type") != "message" || !root.TryGetProperty("message", out var message) || String(message, "role") != "user") continue;
                var prompt = MessageText(message).Replace("\r", " ").Replace("\n", " ").Trim();
                if (prompt.Length == 0) continue;
                var words = prompt.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var title = string.Join(" ", words.Take(7));
                if (title.Length > 58) title = title[..58];
                if (words.Length > 7 || prompt.Length > title.Length) title += "...";
                return (title, prompt.Length > 125 ? prompt[..125] + "..." : prompt);
            }
        }
        catch { }
        return ("New chat", "No messages yet");
    }

    private void SwitchSession(int index)
    {
        if (index < 0 || index >= sessions.Count) return;
        rpc.Send(new { type = "switch_session", sessionPath = sessions[index] });
    }

    private void ChooseWorkspace(bool apply)
    {
        using var dialog = new FolderBrowserDialog { SelectedPath = workspace, UseDescriptionForTitle = true, Description = "Choose the folder Pi should use" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        if (apply) ApplyWorkspace(dialog.SelectedPath); else Emit("workspaceChosen", new { path = dialog.SelectedPath });
    }

    private void ApplyWorkspace(string path)
    {
        path = Environment.ExpandEnvironmentVariables(path.Replace("~", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)));
        if (!Directory.Exists(path)) { Emit("appError", new { message = "That workspace folder does not exist." }); return; }
        workspace = Path.GetFullPath(path);
        Emit("workspaceRestarting", new { path = workspace });
        StartRpc(false);
    }

    private void ChooseAttachments()
    {
        using var dialog = new OpenFileDialog { Multiselect = true, CheckFileExists = true, Title = "Attach files to Pi Space" };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        var attachments = new List<object>();
        foreach (var path in dialog.FileNames.Take(5))
        {
            var info = new FileInfo(path);
            if (info.Length > 8 * 1024 * 1024) { Emit("appError", new { message = $"{info.Name} is larger than 8 MB." }); continue; }
            attachments.Add(new { name = info.Name, mimeType = MimeType(info.Extension), data = Convert.ToBase64String(File.ReadAllBytes(path)) });
        }
        Emit("attachmentsChosen", new { attachments });
    }

    private void SetModel(string provider, string model)
    {
        selectedProvider = provider;
        selectedModel = model;
        rpc.Send(new { type = "set_model", provider, modelId = model });
        SyncProviderSettings($"Switching to {model}...");
    }

    private void SendRpcCommand(JsonElement body)
    {
        var command = String(body, "command");
        if (command == "export_html" && body.TryGetProperty("outputPath", out var output)) rpc.Send(new { type = command, outputPath = output.GetString() });
        else rpc.Send(new { type = command });
    }

    private void SendExtensionUiResponse(JsonElement body)
    {
        var response = new Dictionary<string, object?> { ["type"] = "extension_ui_response" };
        foreach (var property in new[] { "id", "value", "confirmed", "cancelled" })
        {
            if (body.TryGetProperty(property, out var value)) response[property] = JsonSerializer.Deserialize<object>(value.GetRawText(), json);
        }
        rpc.Send(response);
    }

    private void ChooseInitialModel()
    {
        if (!string.IsNullOrWhiteSpace(selectedProvider) && !string.IsNullOrWhiteSpace(selectedModel)) return;
        var config = ProviderConfig.Load();
        if (config.IsConfigured("openrouter")) { selectedProvider = "openrouter"; selectedModel = "stealth/ox-alpha"; }
        else if (config.IsConfigured("agentrouter")) { selectedProvider = "agentrouter"; selectedModel = "gpt-5.6-sol"; }
        else if (config.IsConfigured("tokenrouter")) { selectedProvider = "tokenrouter"; selectedModel = "moonshotai/kimi-k3-free"; }
        else if (config.IsConfigured("tabitoken")) { selectedProvider = "tabitoken"; selectedModel = "claude-opus-5"; }
    }

    private void SyncProviderSettings(string? message = null, bool success = true)
    {
        var config = ProviderConfig.Load();
        Emit("providerSettingsLoaded", new
        {
            models = ManagedModels,
            agentRouterConfigured = config.IsConfigured("agentrouter"),
            openRouterConfigured = config.IsConfigured("openrouter"),
            tokenRouterConfigured = config.IsConfigured("tokenrouter"),
            tabiTokenConfigured = config.IsConfigured("tabitoken"),
            tabiTokenBaseURL = config.BaseUrl("tabitoken") ?? "https://api.tabitoken.com/v1",
            selectedProvider = selectedProvider ?? "",
            selectedModel = selectedModel ?? "",
            wakePhrasesEnabled = false,
            voicePace = voice.Pace,
            voiceLength = voice.ResponseLength,
            kokoroInstalled = kokoro.IsInstalled,
            kokoroVoice = kokoro.SelectedVoice,
            kokoroVoices = WindowsKokoroService.Voices.Select(item => new { id = item.Id, name = item.Name }),
            success,
            message,
        });
    }

    private void SaveProviderKeys(JsonElement body)
    {
        try
        {
            ProviderConfig.Save(String(body, "agentRouterKey"), String(body, "tokenRouterKey"), String(body, "tabiTokenKey"), String(body, "tabiTokenBaseURL"), openRouterKey: String(body, "openRouterKey"));
            SyncProviderSettings("Provider configuration saved.");
            StartRpc(true);
        }
        catch (Exception error) { SyncProviderSettings(error.Message, false); }
    }

    private void UpdateProviderKey(string provider, string key)
    {
        var agent = provider == "agentrouter" ? key : "";
        var open = provider == "openrouter" ? key : "";
        var token = provider == "tokenrouter" ? key : "";
        var tabi = provider == "tabitoken" ? key : "";
        try { ProviderConfig.Save(agent, token, tabi, "", openRouterKey: open); SyncProviderSettings("Provider configuration saved."); StartRpc(true); }
        catch (Exception error) { SyncProviderSettings(error.Message, false); }
    }

    private void EmitVoiceSettings() => Emit("voiceSettings", new
    {
        pace = voice.Pace,
        length = voice.ResponseLength,
        muted = voice.Muted,
        paused = voice.Paused,
    });

    private static string InstructionsPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".pi", "agent", "pi-space-instructions.txt");
    private static string ReadInstructions() => File.Exists(InstructionsPath) ? File.ReadAllText(InstructionsPath).Trim() : "";
    private void SaveInstructions(string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(InstructionsPath)!);
        File.WriteAllText(InstructionsPath, text.Trim());
        Emit("instructionsSaved", new { text = text.Trim() });
    }

    private void Emit(string name, object payload) => EmitRaw(name, JsonSerializer.Serialize(payload, json));
    private void EmitRaw(string name, string payloadJson)
    {
        if (!ready) return;
        using var document = JsonDocument.Parse(payloadJson);
        web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(new { @event = name, payload = document.RootElement }, json));
    }

    private void Ui(Action action)
    {
        if (IsDisposed) return;
        if (InvokeRequired) BeginInvoke(action); else action();
    }

    private static string MessageText(JsonElement message)
    {
        if (!message.TryGetProperty("content", out var content)) return "";
        if (content.ValueKind == JsonValueKind.String) return content.GetString() ?? "";
        if (content.ValueKind != JsonValueKind.Array) return "";
        return string.Join("\n", content.EnumerateArray().Where(item => String(item, "type") == "text").Select(item => String(item, "text")));
    }

    private static string MimeType(string extension) => extension.ToLowerInvariant() switch
    {
        ".png" => "image/png", ".jpg" or ".jpeg" => "image/jpeg", ".gif" => "image/gif", ".webp" => "image/webp",
        ".txt" => "text/plain", ".md" => "text/markdown", ".json" => "application/json", ".js" => "text/javascript",
        ".ts" => "text/typescript", ".py" => "text/x-python", ".sh" => "text/x-shellscript", ".html" => "text/html",
        ".css" => "text/css", ".csv" => "text/csv", ".xml" => "application/xml", ".yml" or ".yaml" => "text/yaml",
        _ => "application/octet-stream",
    };

    internal static string String(JsonElement value, string property) => value.TryGetProperty(property, out var child) && child.ValueKind == JsonValueKind.String ? child.GetString() ?? "" : "";
    private static int Int(JsonElement value, string property) => value.TryGetProperty(property, out var child) && child.TryGetInt32(out var number) ? number : -1;
    private static bool Bool(JsonElement value, string property, bool fallback = false) => value.TryGetProperty(property, out var child) && child.ValueKind is JsonValueKind.True or JsonValueKind.False ? child.GetBoolean() : fallback;
}
