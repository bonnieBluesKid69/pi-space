using System.Speech.Recognition;
using System.Text.RegularExpressions;

namespace PiSpace.Windows;

internal sealed class WindowsVoiceConversation : IDisposable
{
    private enum Mode { Idle, Conversation, Waiting, Speaking, Paused, Preview }

    private readonly WindowsKokoroService kokoro;
    private readonly object gate = new();
    private SpeechRecognitionEngine? recognizer;
    private CancellationTokenSource? silence;
    private readonly Queue<string> speechQueue = new();
    private Mode mode = Mode.Idle;
    private Mode pausedMode = Mode.Idle;
    private string transcript = "";
    private string speechBuffer = "";
    private string responseBuffer = "";
    private string lastResponse = "";
    private string lastSpoken = "";
    private bool responseFinished;
    private bool speaking;
    private bool muted;
    private int speechGeneration;

    internal event Action<string, string>? StateChanged;
    internal event Action<string, bool>? TranscriptChanged;
    internal event Action<string, bool>? PromptReady;
    internal event Action? AbortRequested;
    internal event Action? SettingsChanged;

    internal WindowsVoiceConversation(WindowsKokoroService kokoro)
    {
        this.kokoro = kokoro;
        Pace = ReadString("pace", "balanced");
        ResponseLength = ReadString("length", "concise");
    }

    internal string Pace { get; private set; }
    internal string ResponseLength { get; private set; }
    internal bool Muted => muted;
    internal bool Paused => mode == Mode.Paused;

    internal void Start()
    {
        lock (gate)
        {
            if (!kokoro.IsInstalled)
            {
                StateChanged?.Invoke("error", "Install the free Kokoro voice in Settings before starting a voice conversation.");
                return;
            }
            if (!EnsureRecognizer()) return;
            speechGeneration++;
            CancelSpeechAndRecognition();
            speechQueue.Clear();
            speechBuffer = responseBuffer = transcript = "";
            responseFinished = false;
            mode = Mode.Conversation;
            StateChanged?.Invoke("starting", "Preparing local Windows speech recognition.");
            if (!muted) StartRecognition();
        }
    }

    internal void End(bool abortResponse = true)
    {
        lock (gate)
        {
            var shouldAbort = abortResponse && mode is Mode.Waiting or Mode.Speaking;
            speechGeneration++;
            CancelSpeechAndRecognition();
            speechQueue.Clear();
            speechBuffer = responseBuffer = transcript = "";
            responseFinished = false;
            mode = Mode.Idle;
            TranscriptChanged?.Invoke("", false);
            StateChanged?.Invoke("idle", "");
            if (shouldAbort) AbortRequested?.Invoke();
        }
    }

    internal void SetMuted(bool value)
    {
        lock (gate)
        {
            muted = value;
            if (muted) StopRecognition();
            else if (mode == Mode.Conversation) StartRecognition();
            else if (mode == Mode.Speaking) StartRecognition();
            StateChanged?.Invoke(value ? "muted" : ModeState(mode), value ? "Microphone off" : "");
        }
        SettingsChanged?.Invoke();
    }

    internal void TogglePause()
    {
        lock (gate)
        {
            if (mode == Mode.Paused)
            {
                mode = pausedMode;
                if (!muted && mode is Mode.Conversation or Mode.Waiting or Mode.Speaking) StartRecognition();
                StateChanged?.Invoke(ModeState(mode), mode == Mode.Speaking ? lastSpoken : "");
                if (mode is Mode.Waiting or Mode.Conversation or Mode.Speaking) _ = PlayNextAsync();
            }
            else if (mode is Mode.Conversation or Mode.Waiting or Mode.Speaking)
            {
                pausedMode = mode;
                mode = Mode.Paused;
                speechGeneration++;
                if (speaking && !string.IsNullOrWhiteSpace(lastSpoken))
                {
                    var pending = speechQueue.ToArray();
                    speechQueue.Clear();
                    speechQueue.Enqueue(lastSpoken);
                    foreach (var item in pending) speechQueue.Enqueue(item);
                }
                StopRecognition();
                kokoro.Stop();
                speaking = false;
                StateChanged?.Invoke("paused", "Voice conversation paused");
            }
        }
        SettingsChanged?.Invoke();
    }

    internal void RepeatLastResponse()
    {
        lock (gate)
        {
            if (mode != Mode.Conversation || string.IsNullOrWhiteSpace(lastResponse)) return;
            StopRecognition();
            speechQueue.Clear();
            speechQueue.Enqueue(lastResponse);
            responseFinished = true;
            mode = Mode.Waiting;
        }
        _ = PlayNextAsync();
    }

    internal void SetPace(string value)
    {
        if (value is not ("fast" or "balanced" or "patient")) return;
        Pace = value;
        SaveSettings();
        SettingsChanged?.Invoke();
    }

    internal void SetResponseLength(string value)
    {
        if (value is not ("concise" or "normal" or "detailed")) return;
        ResponseLength = value;
        SaveSettings();
        SettingsChanged?.Invoke();
    }

    internal void ReceiveResponseChunk(string value)
    {
        lock (gate)
        {
            if (string.IsNullOrEmpty(value) || mode is not (Mode.Waiting or Mode.Speaking or Mode.Paused)) return;
            responseBuffer += value;
            speechBuffer += value;
            DrainSpeechBuffer(false);
        }
    }

    internal void FinishResponse(string fallback)
    {
        lock (gate)
        {
            if (mode is not (Mode.Waiting or Mode.Speaking or Mode.Paused)) return;
            if (string.IsNullOrEmpty(responseBuffer)) responseBuffer = fallback;
            if (string.IsNullOrEmpty(speechBuffer)) speechBuffer = fallback;
            lastResponse = CleanSpeech(responseBuffer);
            responseFinished = true;
            DrainSpeechBuffer(true);
        }
        _ = PlayNextAsync();
    }

    private bool EnsureRecognizer()
    {
        if (recognizer is not null) return true;
        try
        {
            var info = SpeechRecognitionEngine.InstalledRecognizers()
                .FirstOrDefault(item => item.Culture.Name.StartsWith("en", StringComparison.OrdinalIgnoreCase));
            if (info is null) throw new InvalidOperationException("No English Windows speech-recognition pack is installed.");
            recognizer = new SpeechRecognitionEngine(info);
            recognizer.SetInputToDefaultAudioDevice();
            recognizer.SpeechRecognized += Recognized;
            recognizer.SpeechRecognitionRejected += (_, _) => { };
            recognizer.RecognizeCompleted += (_, args) =>
            {
                lock (gate)
                {
                    if (args.Error is not null && mode is not (Mode.Idle or Mode.Paused))
                        StateChanged?.Invoke("error", $"Windows Speech Recognition stopped: {args.Error.Message}");
                }
            };
            return true;
        }
        catch (Exception error)
        {
            StateChanged?.Invoke("error", $"Windows voice needs an English speech-recognition pack and microphone access: {error.Message}");
            return false;
        }
    }

    private void StartRecognition()
    {
        if (muted || !EnsureRecognizer()) return;
        StopRecognition();
        try
        {
            recognizer!.UnloadAllGrammars();
            recognizer.LoadGrammar(new DictationGrammar { Name = "dictation" });
            recognizer.RecognizeAsync(RecognizeMode.Multiple);
            if (mode == Mode.Conversation) StateChanged?.Invoke("listening", "");
        }
        catch (Exception error) { StateChanged?.Invoke("error", $"Could not start the microphone: {error.Message}"); }
    }

    private void StopRecognition()
    {
        silence?.Cancel();
        silence?.Dispose();
        silence = null;
        try { recognizer?.RecognizeAsyncCancel(); } catch { }
    }

    private void Recognized(object? sender, SpeechRecognizedEventArgs args)
    {
        var clean = args.Result.Text.Trim();
        if (string.IsNullOrWhiteSpace(clean) || args.Result.Confidence < 0.35f) return;
        var normalized = Regex.Replace(clean.ToLowerInvariant(), "[^a-z0-9]+", " ").Trim();
        lock (gate)
        {
            if (mode == Mode.Speaking)
            {
                if (!LikelyEcho(normalized)) InterruptWith(clean);
                return;
            }
            if (mode != Mode.Conversation) return;
            transcript = clean;
            TranscriptChanged?.Invoke(clean, false);
            StateChanged?.Invoke("listening", "");
            ScheduleSend();
        }
    }

    private void ScheduleSend()
    {
        silence?.Cancel();
        silence?.Dispose();
        silence = new CancellationTokenSource();
        var expected = transcript;
        var delay = Pace == "fast" ? 800 : Pace == "patient" ? 2300 : 1500;
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(delay, silence.Token); }
            catch (OperationCanceledException) { return; }
            lock (gate)
            {
                if (mode != Mode.Conversation || transcript != expected) return;
                mode = Mode.Waiting;
                transcript = "";
                responseBuffer = speechBuffer = "";
                responseFinished = false;
                StopRecognition();
                TranscriptChanged?.Invoke(expected, true);
                StateChanged?.Invoke("thinking", "");
                PromptReady?.Invoke(expected, false);
                if (!muted) StartRecognition();
            }
        });
    }

    private void InterruptWith(string text)
    {
        CancelSpeechAndRecognition();
        speechQueue.Clear();
        speechBuffer = responseBuffer = "";
        responseFinished = false;
        mode = Mode.Waiting;
        TranscriptChanged?.Invoke(text, true);
        StateChanged?.Invoke("thinking", "Interrupted. Passing your new request to Pi.");
        AbortRequested?.Invoke();
        PromptReady?.Invoke(text, true);
        if (!muted) StartRecognition();
    }

    private bool LikelyEcho(string normalized)
    {
        var words = normalized.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length < 2) return true;
        var spoken = CleanSpeech(lastSpoken).ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries).ToHashSet();
        return words.Count(spoken.Contains) / (double)words.Length > 0.72;
    }

    private void DrainSpeechBuffer(bool flush)
    {
        while (Boundary(speechBuffer) is int index)
        {
            EnqueueSpeech(CleanSpeech(speechBuffer[..(index + 1)]));
            speechBuffer = speechBuffer[(index + 1)..];
        }
        if (flush)
        {
            EnqueueSpeech(CleanSpeech(speechBuffer));
            speechBuffer = "";
        }
        if (mode != Mode.Paused) _ = PlayNextAsync();
    }

    private void EnqueueSpeech(string value)
    {
        if (!string.IsNullOrWhiteSpace(value)) speechQueue.Enqueue(value);
    }

    private async Task PlayNextAsync()
    {
        string next;
        int generation;
        lock (gate)
        {
            if (speaking || mode == Mode.Paused) return;
            if (speechQueue.Count == 0)
            {
                if (responseFinished && mode is Mode.Waiting or Mode.Speaking)
                {
                    mode = Mode.Conversation;
                    if (!muted) StartRecognition();
                    StateChanged?.Invoke("listening", "");
                }
                return;
            }
            next = speechQueue.Dequeue();
            generation = speechGeneration;
            speaking = true;
            mode = Mode.Speaking;
            lastSpoken = next;
            StopRecognition();
            if (!muted) StartRecognition();
            StateChanged?.Invoke("speaking", next);
        }
        await kokoro.SpeakAsync(next, true);
        lock (gate)
        {
            if (generation != speechGeneration) return;
            speaking = false;
            if (mode == Mode.Speaking) mode = Mode.Waiting;
        }
        await PlayNextAsync();
    }

    private void CancelSpeechAndRecognition()
    {
        StopRecognition();
        kokoro.Stop();
        speaking = false;
    }

    private static int? Boundary(string value)
    {
        if (value.Length <= 24) return null;
        for (var i = 0; i < value.Length; i++)
        {
            if (".!?".Contains(value[i]) && (i + 1 == value.Length || char.IsWhiteSpace(value[i + 1]))) return i;
            if (i > 180 && ",;:".Contains(value[i]) && (i + 1 == value.Length || char.IsWhiteSpace(value[i + 1]))) return i;
        }
        return null;
    }

    private static string CleanSpeech(string value) => Regex.Replace(
        Regex.Replace(
            Regex.Replace(
                Regex.Replace(value, "```[\\s\\S]*?```", " Code omitted. "),
                "!?\\[([^]]+)\\]\\([^)]*\\)", "$1"),
            "https?://\\S+", ""),
        "[`*_#>|~]+|\\s+", " ").Trim();

    private static string ModeState(Mode value) => value switch
    {
        Mode.Conversation => "listening", Mode.Waiting => "thinking", Mode.Speaking => "speaking",
        Mode.Paused => "paused", _ => "idle",
    };

    private static string SettingsPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pi Space", "voice-settings.json");
    private static bool ReadBool(string name, bool fallback)
    {
        try { using var d = System.Text.Json.JsonDocument.Parse(File.ReadAllText(SettingsPath)); return d.RootElement.TryGetProperty(name, out var v) ? v.GetBoolean() : fallback; } catch { return fallback; }
    }
    private static string ReadString(string name, string fallback)
    {
        try { using var d = System.Text.Json.JsonDocument.Parse(File.ReadAllText(SettingsPath)); return d.RootElement.TryGetProperty(name, out var v) ? v.GetString() ?? fallback : fallback; } catch { return fallback; }
    }
    private void SaveSettings()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        var temp = SettingsPath + ".tmp";
        File.WriteAllText(temp, System.Text.Json.JsonSerializer.Serialize(new { pace = Pace, length = ResponseLength }));
        File.Move(temp, SettingsPath, true);
    }

    public void Dispose()
    {
        End(false);
        recognizer?.Dispose();
        silence?.Dispose();
    }
}
