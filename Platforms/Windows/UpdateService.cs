using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;

namespace PiSpace.Windows;

internal sealed class UpdateService
{
    private const string LatestReleaseUrl = "https://api.github.com/repos/bonnieBluesKid69/pi-space/releases/latest";
    private const string ArchiveName = "Pi-Space-Windows-x64.zip";
    private const string ChecksumName = "Pi-Space-Windows-x64.sha256";
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(5) };
    private ReleaseUpdate? available;

    public string CurrentVersion { get; }
    public event Action<object>? StateChanged;

    public UpdateService(string currentVersion)
    {
        CurrentVersion = NormalizeVersion(currentVersion);
        http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("Pi-Space", CurrentVersion));
        http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
    }

    public async Task CheckAsync(bool manual = false)
    {
        StateChanged?.Invoke(new { status = "checking", currentVersion = CurrentVersion, manual });
        try
        {
            using var response = await http.GetAsync(LatestReleaseUrl);
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
            {
                available = null;
                StateChanged?.Invoke(new { status = "current", currentVersion = CurrentVersion, manual });
                return;
            }
            response.EnsureSuccessStatusCode();
            using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var root = document.RootElement;
            var version = NormalizeVersion(root.GetProperty("tag_name").GetString() ?? "");
            var archiveUrl = AssetUrl(root, ArchiveName);
            var checksumUrl = AssetUrl(root, ChecksumName);
            if (!IsNewer(version, CurrentVersion) || archiveUrl is null || checksumUrl is null)
            {
                available = null;
                StateChanged?.Invoke(new { status = "current", currentVersion = CurrentVersion, manual });
                return;
            }
            available = new ReleaseUpdate(version, archiveUrl, checksumUrl, root.TryGetProperty("html_url", out var page) ? page.GetString() ?? "" : "");
            StateChanged?.Invoke(new { status = "available", currentVersion = CurrentVersion, version, releaseUrl = available.ReleaseUrl, manual });
        }
        catch (Exception error)
        {
            StateChanged?.Invoke(new { status = "error", currentVersion = CurrentVersion, message = $"Could not check for updates: {error.Message}", manual });
        }
    }

    public async Task InstallAsync()
    {
        if (available is null)
        {
            await CheckAsync(true);
            if (available is null) return;
        }

        var update = available;
        var temporaryRoot = Path.Combine(Path.GetTempPath(), "PiSpaceUpdate-" + Guid.NewGuid().ToString("N"));
        var archivePath = Path.Combine(temporaryRoot, ArchiveName);
        var stagePath = Path.Combine(temporaryRoot, "stage");
        Directory.CreateDirectory(stagePath);
        try
        {
            StateChanged?.Invoke(new { status = "downloading", currentVersion = CurrentVersion, version = update.Version });
            await DownloadAsync(update.ArchiveUrl, archivePath);
            var checksumText = await http.GetStringAsync(update.ChecksumUrl);
            var expected = ParseChecksum(checksumText, ArchiveName) ?? throw new InvalidDataException("The release checksum file is invalid.");
            await using var archive = File.OpenRead(archivePath);
            var actual = Convert.ToHexString(await SHA256.HashDataAsync(archive)).ToLowerInvariant();
            if (!CryptographicOperations.FixedTimeEquals(Convert.FromHexString(expected), Convert.FromHexString(actual))) throw new InvalidDataException("The downloaded update failed SHA-256 verification.");

            ExtractSafely(archivePath, stagePath);
            var stagedExecutable = Path.Combine(stagePath, "PiSpace.exe");
            if (!File.Exists(stagedExecutable) || !File.Exists(Path.Combine(stagePath, "Resources", "PiSpace.html"))) throw new InvalidDataException("The Windows release package is incomplete.");

            StateChanged?.Invoke(new { status = "installing", currentVersion = CurrentVersion, version = update.Version });
            LaunchInstaller(stagePath, AppContext.BaseDirectory, Environment.ProcessId);
            Application.Exit();
        }
        catch (Exception error)
        {
            try { Directory.Delete(temporaryRoot, true); } catch { }
            StateChanged?.Invoke(new { status = "error", currentVersion = CurrentVersion, version = update.Version, message = $"Update failed: {error.Message}", manual = true });
        }
    }

    private async Task DownloadAsync(Uri url, string path)
    {
        using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        response.EnsureSuccessStatusCode();
        await using var input = await response.Content.ReadAsStreamAsync();
        await using var output = File.Create(path);
        await input.CopyToAsync(output);
    }

    private static void ExtractSafely(string archivePath, string destination)
    {
        var root = Path.GetFullPath(destination) + Path.DirectorySeparatorChar;
        using var archive = ZipFile.OpenRead(archivePath);
        foreach (var entry in archive.Entries)
        {
            var target = Path.GetFullPath(Path.Combine(destination, entry.FullName));
            if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The update archive contains an unsafe path.");
            if (string.IsNullOrEmpty(entry.Name)) Directory.CreateDirectory(target);
            else
            {
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                entry.ExtractToFile(target, true);
            }
        }
    }

    private static void LaunchInstaller(string stagePath, string destination, int processId)
    {
        var scriptPath = Path.Combine(Path.GetDirectoryName(stagePath)!, "install-update.ps1");
        var script = "param([int]$HostProcessId,[string]$Source,[string]$Destination)\n" +
            "$ErrorActionPreference='Stop'\n" +
            "$exe=Join-Path $Destination 'PiSpace.exe'\n" +
            "$log=Join-Path $env:LOCALAPPDATA 'Pi Space\\update.log'\n" +
            "try {\n" +
            "  Wait-Process -Id $HostProcessId -ErrorAction SilentlyContinue\n" +
            "  Start-Sleep -Milliseconds 350\n" +
            "  Get-ChildItem -LiteralPath $Source -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force }\n" +
            "} catch {\n" +
            "  New-Item -ItemType Directory -Path (Split-Path $log -Parent) -Force | Out-Null\n" +
            "  $_ | Out-String | Set-Content -LiteralPath $log\n" +
            "}\n" +
            "if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }\n" +
            "Remove-Item -LiteralPath (Split-Path $Source -Parent) -Recurse -Force -ErrorAction SilentlyContinue\n";
        File.WriteAllText(scriptPath, script);
        var start = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", scriptPath, "-HostProcessId", processId.ToString(), "-Source", stagePath, "-Destination", Path.GetFullPath(destination) }) start.ArgumentList.Add(argument);
        Process.Start(start) ?? throw new InvalidOperationException("The update installer could not be started.");
    }

    private static Uri? AssetUrl(JsonElement release, string name)
    {
        if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) return null;
        foreach (var asset in assets.EnumerateArray())
        {
            if (asset.TryGetProperty("name", out var assetName) && assetName.GetString() == name && asset.TryGetProperty("browser_download_url", out var value) && Uri.TryCreate(value.GetString(), UriKind.Absolute, out var url) && url.Scheme == Uri.UriSchemeHttps && url.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)) return url;
        }
        return null;
    }

    internal static string? ParseChecksum(string text, string archiveName)
    {
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length >= 2 && parts[1].TrimStart('*') == archiveName && parts[0].Length == 64 && parts[0].All(Uri.IsHexDigit)) return parts[0].ToLowerInvariant();
        }
        return null;
    }

    internal static bool IsNewer(string candidate, string current)
    {
        return Version.TryParse(NormalizeVersion(candidate), out var next) && Version.TryParse(NormalizeVersion(current), out var installed) && next > installed;
    }

    internal static string NormalizeVersion(string value)
    {
        var clean = value.Trim().TrimStart('v', 'V');
        var suffix = clean.IndexOfAny(['-', '+']);
        return suffix >= 0 ? clean[..suffix] : clean;
    }

    private sealed record ReleaseUpdate(string Version, Uri ArchiveUrl, Uri ChecksumUrl, string ReleaseUrl);
}
