using System.Diagnostics;
using System.IO.Compression;
using System.Media;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PiSpace.Windows;

internal sealed class WindowsKokoroService : IDisposable
{
    internal sealed record Voice(string Id, string Name);
    private sealed record Asset(string Name, string Url, string Sha256);

    internal static readonly Voice[] Voices =
    [
        new("af_heart", "Heart · warm American"),
        new("af_sarah", "Sarah · clear American"),
        new("af_nicole", "Nicole · calm American"),
        new("am_adam", "Adam · balanced American"),
        new("am_michael", "Michael · warm American"),
        new("bf_emma", "Emma · clear British"),
        new("bm_george", "George · balanced British"),
    ];

    private static readonly Asset Python = new(
        "python-3.12.10-embed-amd64.zip",
        "https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip",
        "4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3");
    private static readonly Asset Pip = new(
        "get-pip.py",
        "https://bootstrap.pypa.io/get-pip.py",
        "fb24e693bab954209a063d90953621412ccad4a500905a726286e038f508ddf6");
    private static readonly Asset Model = new(
        "kokoro-v1.0.int8.onnx",
        "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx",
        "6e742170d309016e5891a994e1ce1559c702a2ccd0075e67ef7157974f6406cb");
    private static readonly Asset VoiceData = new(
        "voices-v1.0.bin",
        "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin",
        "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d");

    private static readonly string Root = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pi Space", "kokoro");
    private static readonly string Active = Path.Combine(Root, "runtime");
    private static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pi Space", "kokoro-install.log");
    private static readonly string SettingsPath = Path.Combine(Root, "settings.json");
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(20) };
    private readonly string helperPath;
    private CancellationTokenSource? installOperation;
    private CancellationTokenSource? speechOperation;
    private SoundPlayer? player;
    private bool installing;

    internal event Action<string, string>? InstallStateChanged;
    internal event Action<string, string>? SpeechStateChanged;

    internal WindowsKokoroService(string helperPath) => this.helperPath = helperPath;

    internal bool IsInstalled => ValidateInstallation(Active);
    internal bool ReadResponses { get; private set; }
    internal string SelectedVoice { get; private set; } = "af_heart";

    internal void LoadSettings()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return;
            using var document = JsonDocument.Parse(File.ReadAllText(SettingsPath));
            var root = document.RootElement;
            ReadResponses = root.TryGetProperty("readResponses", out var read) && read.ValueKind == JsonValueKind.True;
            if (root.TryGetProperty("voice", out var voice)) SetVoice(voice.GetString() ?? "af_heart", false);
        }
        catch { }
    }

    internal void SetReadResponses(bool enabled)
    {
        ReadResponses = enabled;
        SaveSettings();
        if (!enabled) Stop();
    }

    internal void SetVoice(string voice, bool save = true)
    {
        if (!IsVoiceSupported(voice)) throw new ArgumentException("That Kokoro voice is not supported.");
        SelectedVoice = voice;
        if (save) SaveSettings();
    }

    internal async Task InstallAsync()
    {
        if (installing) return;
        installing = true;
        installOperation = new CancellationTokenSource();
        var staging = Path.Combine(Root, "runtime-installing");
        var backup = Path.Combine(Root, "runtime.previous");
        try
        {
            Directory.CreateDirectory(Root);
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            await LogAsync($"[{DateTime.UtcNow:O}] Starting Windows Kokoro installation");
            InstallStateChanged?.Invoke("installing", "Installing the local Windows Kokoro runtime and model. This can take several minutes.");
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
            Directory.CreateDirectory(staging);

            await DownloadAndVerifyAsync(Python, Path.Combine(staging, Python.Name), installOperation.Token);
            ZipFile.ExtractToDirectory(Path.Combine(staging, Python.Name), Path.Combine(staging, "python"));
            File.Delete(Path.Combine(staging, Python.Name));
            EnableEmbeddedSitePackages(Path.Combine(staging, "python"));
            await DownloadAndVerifyAsync(Pip, Path.Combine(staging, Pip.Name), installOperation.Token);
            await RunAsync(Path.Combine(staging, "python", "python.exe"), [Path.Combine(staging, Pip.Name), "--disable-pip-version-check"], staging, installOperation.Token);
            await RunAsync(Path.Combine(staging, "python", "python.exe"), ["-m", "pip", "install", "--disable-pip-version-check", "--no-warn-script-location", "kokoro-onnx==0.5.0", "soundfile==0.13.1"], staging, installOperation.Token);
            await DownloadAndVerifyAsync(Model, Path.Combine(staging, Model.Name), installOperation.Token);
            await DownloadAndVerifyAsync(VoiceData, Path.Combine(staging, VoiceData.Name), installOperation.Token);
            File.Copy(helperPath, Path.Combine(staging, "synthesize.py"), true);
            await RunAsync(Path.Combine(staging, "python", "python.exe"), ["-c", "import kokoro_onnx, soundfile, onnxruntime"], staging, installOperation.Token);
            File.WriteAllText(Path.Combine(staging, "status.json"), JsonSerializer.Serialize(new { version = 1, model = Model.Name }));

            if (Directory.Exists(backup)) Directory.Delete(backup, true);
            if (Directory.Exists(Active)) Directory.Move(Active, backup);
            try { Directory.Move(staging, Active); }
            catch
            {
                if (Directory.Exists(backup) && !Directory.Exists(Active)) Directory.Move(backup, Active);
                throw;
            }
            if (Directory.Exists(backup)) Directory.Delete(backup, true);
            await LogAsync($"[{DateTime.UtcNow:O}] Windows Kokoro installation completed");
            InstallStateChanged?.Invoke("ready", "Kokoro is installed and ready on Windows.");
        }
        catch (OperationCanceledException)
        {
            await LogAsync($"[{DateTime.UtcNow:O}] Windows Kokoro installation cancelled");
            InstallStateChanged?.Invoke("error", "Kokoro installation was cancelled.");
        }
        catch (Exception error)
        {
            await LogAsync($"[{DateTime.UtcNow:O}] ERROR {error}");
            InstallStateChanged?.Invoke("error", $"Kokoro installation failed: {UsefulError(error.Message)}");
        }
        finally
        {
            installing = false;
            installOperation?.Dispose();
            installOperation = null;
            try { if (Directory.Exists(staging)) Directory.Delete(staging, true); } catch { }
        }
    }

    internal async Task PreviewAsync() => await SpeakAsync("Hello. This is your local Kokoro voice in Pi Space.", true);

    internal async Task SpeakAsync(string text, bool force = false)
    {
        if ((!ReadResponses && !force) || string.IsNullOrWhiteSpace(text)) return;
        if (!IsInstalled)
        {
            SpeechStateChanged?.Invoke("error", "Install Kokoro in Settings before using Windows speech.");
            return;
        }
        Stop();
        speechOperation = new CancellationTokenSource();
        var output = Path.Combine(Path.GetTempPath(), $"pi-space-kokoro-{Guid.NewGuid():N}.wav");
        try
        {
            SpeechStateChanged?.Invoke("starting", "Generating speech locally with Kokoro.");
            var python = Path.Combine(Active, "python", "python.exe");
            var arguments = new[]
            {
                Path.Combine(Active, "synthesize.py"), "--model", Path.Combine(Active, Model.Name),
                "--voices", Path.Combine(Active, VoiceData.Name), "--voice", SelectedVoice,
                "--output", output, "--speed", "1.0",
            };
            await RunAsync(python, arguments, Active, speechOperation.Token, JsonSerializer.Serialize(new { text }));
            speechOperation.Token.ThrowIfCancellationRequested();
            player = new SoundPlayer(output);
            player.Load();
            SpeechStateChanged?.Invoke("speaking", text);
            await Task.Run(player.PlaySync, speechOperation.Token);
            SpeechStateChanged?.Invoke("idle", "");
        }
        catch (OperationCanceledException) { SpeechStateChanged?.Invoke("idle", ""); }
        catch (Exception error) { SpeechStateChanged?.Invoke("error", $"Kokoro could not speak: {UsefulError(error.Message)}"); }
        finally
        {
            player?.Dispose();
            player = null;
            speechOperation?.Dispose();
            speechOperation = null;
            try { File.Delete(output); } catch { }
        }
    }

    internal void Stop()
    {
        try { speechOperation?.Cancel(); } catch { }
        try { player?.Stop(); } catch { }
    }

    internal void OpenLog()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
        if (!File.Exists(LogPath)) File.WriteAllText(LogPath, "No Kokoro installation has been attempted yet.\r\n");
        Process.Start(new ProcessStartInfo(LogPath) { UseShellExecute = true });
    }

    internal static bool IsVoiceSupported(string voice) => Voices.Any(item => item.Id == voice);

    internal static bool ValidateInstallation(string path) =>
        File.Exists(Path.Combine(path, "python", "python.exe")) &&
        File.Exists(Path.Combine(path, "synthesize.py")) &&
        File.Exists(Path.Combine(path, Model.Name)) &&
        File.Exists(Path.Combine(path, VoiceData.Name)) &&
        File.Exists(Path.Combine(path, "status.json"));

    internal static IReadOnlyDictionary<string, string> PinnedAssetHashes => new Dictionary<string, string>
    {
        [Python.Name] = Python.Sha256,
        [Pip.Name] = Pip.Sha256,
        [Model.Name] = Model.Sha256,
        [VoiceData.Name] = VoiceData.Sha256,
    };

    internal static async Task<string> Sha256FileAsync(string path, CancellationToken cancellation = default)
    {
        await using var stream = File.OpenRead(path);
        return Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellation)).ToLowerInvariant();
    }

    private async Task DownloadAndVerifyAsync(Asset asset, string destination, CancellationToken cancellation)
    {
        await LogAsync($"Downloading {asset.Name}");
        using var response = await http.GetAsync(asset.Url, HttpCompletionOption.ResponseHeadersRead, cancellation);
        response.EnsureSuccessStatusCode();
        await using (var source = await response.Content.ReadAsStreamAsync(cancellation))
        await using (var target = File.Create(destination)) await source.CopyToAsync(target, cancellation);
        var actual = await Sha256FileAsync(destination, cancellation);
        if (!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(actual), Encoding.ASCII.GetBytes(asset.Sha256)))
            throw new InvalidDataException($"The checksum for {asset.Name} did not match.");
        await LogAsync($"Verified {asset.Name}");
    }

    private async Task RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, CancellationToken cancellation, string? input = null)
    {
        var start = new ProcessStartInfo(executable) { WorkingDirectory = workingDirectory, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = input is not null, CreateNoWindow = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start };
        process.Start();
        if (input is not null) { await process.StandardInput.WriteAsync(input); process.StandardInput.Close(); }
        var stdout = process.StandardOutput.ReadToEndAsync(cancellation);
        var stderr = process.StandardError.ReadToEndAsync(cancellation);
        try { await process.WaitForExitAsync(cancellation); }
        catch { try { process.Kill(true); } catch { } throw; }
        var output = (await stdout + "\n" + await stderr).Trim();
        if (!string.IsNullOrWhiteSpace(output)) await LogAsync(output);
        if (process.ExitCode != 0) throw new InvalidOperationException(LastUsefulLine(output, $"{Path.GetFileName(executable)} exited with code {process.ExitCode}."));
    }

    private static void EnableEmbeddedSitePackages(string pythonDirectory)
    {
        var pth = Directory.EnumerateFiles(pythonDirectory, "python*._pth").Single();
        var lines = File.ReadAllLines(pth).Select(line => line.Trim() == "#import site" ? "import site" : line).ToList();
        if (!lines.Any(line => line.Equals("Lib\\site-packages", StringComparison.OrdinalIgnoreCase))) lines.Insert(Math.Max(0, lines.Count - 1), "Lib\\site-packages");
        File.WriteAllLines(pth, lines);
    }

    private void SaveSettings()
    {
        Directory.CreateDirectory(Root);
        var temp = SettingsPath + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(new { voice = SelectedVoice, readResponses = ReadResponses }));
        File.Move(temp, SettingsPath, true);
    }

    private static string UsefulError(string text) => LastUsefulLine(text, "Review the Kokoro installation log for details.");
    private static string LastUsefulLine(string text, string fallback) => text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).Select(value => value.Trim()).LastOrDefault(value => !string.IsNullOrWhiteSpace(value)) ?? fallback;
    private static Task LogAsync(string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
        return File.AppendAllTextAsync(LogPath, text + Environment.NewLine);
    }

    public void Dispose()
    {
        try { installOperation?.Cancel(); } catch { }
        Stop();
        http.Dispose();
        player?.Dispose();
    }
}
