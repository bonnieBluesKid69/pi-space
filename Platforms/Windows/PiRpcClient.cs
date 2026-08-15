using System.Diagnostics;
using System.Text.Json;

namespace PiSpace.Windows;

internal sealed class PiRpcClient : IDisposable
{
    private readonly object gate = new();
    private Process? process;

    public event Action<JsonElement>? EventReceived;
    public event Action<string>? Failed;

    public void Start(string workspace, bool continuing, string? provider, string? model)
    {
        DisposeProcess();
        var arguments = new List<string> { "--mode", "rpc" };
        if (continuing) arguments.Add("-c");
        if (!string.IsNullOrWhiteSpace(provider)) { arguments.Add("--provider"); arguments.Add(provider); }
        if (!string.IsNullOrWhiteSpace(model)) { arguments.Add("--model"); arguments.Add(model); }

        var pi = FindPi();
        var start = new ProcessStartInfo
        {
            FileName = pi.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)
                ? Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe"
                : pi,
            WorkingDirectory = workspace,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        if (pi.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase))
        {
            start.ArgumentList.Add("/d");
            start.ArgumentList.Add("/s");
            start.ArgumentList.Add("/c");
            start.ArgumentList.Add(pi);
        }
        foreach (var argument in arguments) start.ArgumentList.Add(argument);

        var next = new Process { StartInfo = start, EnableRaisingEvents = true };
        next.Exited += (_, _) =>
        {
            lock (gate)
            {
                if (!ReferenceEquals(process, next)) return;
                process = null;
            }
            Failed?.Invoke($"Pi exited unexpectedly (status {next.ExitCode}). Start a new session or check the selected provider.");
        };
        if (!next.Start()) throw new InvalidOperationException("Pi could not be started.");
        lock (gate) process = next;
        _ = ReadOutput(next);
        _ = ReadErrors(next);
    }

    public void Send(object command)
    {
        Process? active;
        lock (gate) active = process;
        if (active is null || active.HasExited) return;
        var line = JsonSerializer.Serialize(command);
        lock (gate)
        {
            try { active.StandardInput.WriteLine(line); active.StandardInput.Flush(); }
            catch (Exception error) { Failed?.Invoke(error.Message); }
        }
    }

    private async Task ReadOutput(Process active)
    {
        try
        {
            while (!active.HasExited)
            {
                var line = await active.StandardOutput.ReadLineAsync();
                if (line is null) break;
                using var document = JsonDocument.Parse(line);
                EventReceived?.Invoke(document.RootElement.Clone());
            }
        }
        catch (Exception error) when (error is not ObjectDisposedException) { Failed?.Invoke(error.Message); }
    }

    private async Task ReadErrors(Process active)
    {
        try
        {
            while (!active.HasExited)
            {
                var line = await active.StandardError.ReadLineAsync();
                if (line is null) break;
                if (!string.IsNullOrWhiteSpace(line)) Failed?.Invoke(line.Trim());
            }
        }
        catch (Exception error) when (error is not ObjectDisposedException) { Failed?.Invoke(error.Message); }
    }

    private static string FindPi()
    {
        var candidates = new List<string>();
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        candidates.AddRange(path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).Select(directory => Path.Combine(directory.Trim('"'), "pi.cmd")));
        candidates.AddRange(path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).Select(directory => Path.Combine(directory.Trim('"'), "pi.exe")));
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        candidates.Add(Path.Combine(appData, "npm", "pi.cmd"));
        var found = candidates.FirstOrDefault(File.Exists);
        return found ?? throw new FileNotFoundException("Pi was not found. Install Node.js, then run: npm install -g @earendil-works/pi-coding-agent");
    }

    private void DisposeProcess()
    {
        Process? old;
        lock (gate) { old = process; process = null; }
        if (old is null) return;
        try { if (!old.HasExited) old.Kill(true); } catch { }
        old.Dispose();
    }

    public void Dispose() => DisposeProcess();
}
