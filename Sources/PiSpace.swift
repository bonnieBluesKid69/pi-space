import AVFoundation
import AppKit
import CryptoKit
import Darwin
import Foundation
import Speech
import WebKit

final class RPC {
  var process: Process?, input: FileHandle?, buffer = Data()
  var event: (([String: Any]) -> Void)?, failure: ((String) -> Void)?

  private func executable(named name: String) -> String? {
    let fileManager = FileManager.default
    let home = NSHomeDirectory()
    let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    var candidates = environmentPath.split(separator: ":").map { "\($0)/\(name)" }
    candidates += [
      "/opt/homebrew/bin/\(name)",
      "/usr/local/bin/\(name)",
      "/usr/bin/\(name)",
      "\(home)/.local/bin/\(name)",
      "\(home)/.npm-global/bin/\(name)",
      "\(home)/.volta/bin/\(name)",
      "\(home)/.asdf/shims/\(name)",
      "\(home)/.local/share/mise/shims/\(name)",
    ]

    for root in ["\(home)/.nvm/versions/node", "\(home)/.local/share/fnm/node-versions"] {
      guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
      for version in versions.sorted().reversed() {
        candidates.append("\(root)/\(version)/bin/\(name)")
        candidates.append("\(root)/\(version)/installation/bin/\(name)")
      }
    }

    if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
      return path
    }

    // Finder-launched apps receive a minimal PATH. Ask the login shell as a final fallback.
    let lookup = Process()
    let output = Pipe()
    lookup.executableURL = URL(fileURLWithPath: "/bin/zsh")
    lookup.arguments = ["-lic", "command -v \(name)"]
    lookup.standardOutput = output
    lookup.standardError = FileHandle.nullDevice
    guard (try? lookup.run()) != nil else { return nil }
    lookup.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
    return lines.map(String.init).last(where: { fileManager.isExecutableFile(atPath: $0) })
  }

  func start(_ cwd: String, continuing: Bool = false, provider: String? = nil, model: String? = nil) {
    stop()
    let p = Process()
    let i = Pipe()
    let o = Pipe()
    let e = Pipe()
    guard let pi = executable(named: "pi") else {
      failure?("Pi was not found. Install it with: npm install -g @earendil-works/pi-coding-agent")
      return
    }
    p.executableURL = URL(fileURLWithPath: pi)
    p.arguments = ["--mode", "rpc"] + (continuing ? ["-c"] : [])
      + (provider.map { ["--provider", $0] } ?? [])
      + (model.map { ["--model", $0] } ?? [])
    var environment = ProcessInfo.processInfo.environment
    let piDirectory = URL(fileURLWithPath: pi).deletingLastPathComponent().path
    let inheritedPath = environment["PATH"] ?? ""
    let pathEntries =
      [piDirectory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
      + inheritedPath.split(separator: ":").map(String.init)
    environment["PATH"] = Array(NSOrderedSet(array: pathEntries))
      .compactMap { $0 as? String }.joined(separator: ":")
    environment["HOME"] = NSHomeDirectory()
    p.environment = environment
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    p.standardInput = i
    p.standardOutput = o
    p.standardError = e
    input = i.fileHandleForWriting
    o.fileHandleForReading.readabilityHandler = { [weak self] in self?.consume($0.availableData) }
    e.fileHandleForReading.readabilityHandler = { [weak self] h in
      let d = h.availableData
      if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
        DispatchQueue.main.async {
          self?.failure?(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      }
    }
    do {
      try p.run()
      process = p
      p.terminationHandler = { [weak self, weak p] process in
        guard let self, self.process === p else { return }
        DispatchQueue.main.async {
          guard self.process === p else { return }
          self.process = nil
          self.input = nil
          self.failure?("Pi exited unexpectedly (status \(process.terminationStatus)). Start a new session or check the selected provider.")
        }
      }
    } catch { failure?(error.localizedDescription) }
  }
  func send(_ x: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: x) else { return }
    var z = d
    z.append(10)
    try? input?.write(contentsOf: z)
  }
  func stop() {
    process?.terminationHandler = nil
    if process?.isRunning == true { process?.terminate() }
    process = nil
    input = nil
    buffer.removeAll()
  }
  func consume(_ d: Data) {
    guard !d.isEmpty else { return }
    buffer.append(d)
    while let n = buffer.firstIndex(of: 10) {
      let l = buffer.prefix(upTo: n)
      buffer.removeSubrange(...n)
      if let x = try? JSONSerialization.jsonObject(with: l) as? [String: Any] {
        DispatchQueue.main.async { [weak self] in self?.event?(x) }
      }
    }
  }
}

final class VoiceConversation: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
  var onState: ((String, String) -> Void)?
  var onTranscript: ((String, Bool) -> Void)?
  var onPrompt: ((String, Bool) -> Void)?
  var onAbort: (() -> Void)?
  var onWake: (() -> Void)?
  var onSettingsChanged: (() -> Void)?
  var onInstallState: ((String, String) -> Void)?

  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
  private let engine = AVAudioEngine()
  private let speaker = AVSpeechSynthesizer()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var silenceWork: DispatchWorkItem?
  private var restartWork: DispatchWorkItem?
  private var generation = 0
  private var transcript = ""
  private var tapInstalled = false
  private var kokoroProcess: Process?
  private var kokoroPlayer: AVAudioPlayer?
  private var kokoroAudioURL: URL?
  private var prefetchedKokoro: (text: String, url: URL)?
  private var prefetchClient: Process?
  private var prefetchText: String?
  private var prefetchGeneration = 0
  private var speechQueue = [String]()
  private var speechBuffer = ""
  private var responseTextBuffer = ""
  private var speechResponseFinished = false
  private var receivedStreamingSpeech = false
  private let kokoroRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Pi Space/kokoro")
  private enum Mode { case idle, wake, conversation, waiting, speaking, paused, preview }
  private enum ResponsePace: String {
    case fast, balanced, patient
    var pause: TimeInterval { switch self { case .fast: return 0.8; case .balanced: return 1.5; case .patient: return 2.3 } }
  }
  private var mode: Mode = .idle
  private var responsePace = ResponsePace(rawValue: UserDefaults.standard.string(forKey: "PiSpaceVoicePace") ?? "balanced") ?? .balanced
  private var responseLength = UserDefaults.standard.string(forKey: "PiSpaceVoiceLength") ?? "concise"
  private var microphoneMuted = false
  private var pausedMode: Mode?
  private var lastSpokenText = ""
  private var lastResponseText = ""
  private var lastSpeechNormalized = ""
  private let wakeKey = "PiSpaceWakePhrasesEnabled"
  private let voiceKey = "PiSpaceVoiceIdentifier"

  var wakeEnabled: Bool { false }
  var voicePace: String { responsePace.rawValue }
  var voiceLength: String { responseLength }
  var isMicrophoneMuted: Bool { microphoneMuted }
  var isPaused: Bool { pausedMode != nil }
  var selectedVoiceIdentifier: String {
    UserDefaults.standard.string(forKey: voiceKey) ?? preferredVoice()?.identifier ?? ""
  }

  var kokoroInstalled: Bool {
    let pythonPathURL = kokoroRoot.appendingPathComponent("python-path")
    guard FileManager.default.fileExists(atPath: kokoroRoot.appendingPathComponent("status").path),
      FileManager.default.fileExists(atPath: kokoroRoot.appendingPathComponent("tts-server.py").path),
      let pythonPath = try? String(contentsOf: pythonPathURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !pythonPath.isEmpty
    else { return false }
    return FileManager.default.isExecutableFile(atPath: pythonPath)
  }
  var kokoroVoice = UserDefaults.standard.string(forKey: "PiSpaceKokoroVoice") ?? "af_heart"

  override init() {
    super.init()
    speaker.delegate = self
  }

  func setKokoroVoice(_ voice: String) {
    kokoroVoice = voice
    UserDefaults.standard.set(voice, forKey: "PiSpaceKokoroVoice")
    onSettingsChanged?()
  }

  func setResponsePace(_ value: String) {
    guard let pace = ResponsePace(rawValue: value) else { return }
    responsePace = pace
    UserDefaults.standard.set(value, forKey: "PiSpaceVoicePace")
    onSettingsChanged?()
  }

  func setResponseLength(_ value: String) {
    guard ["concise", "normal", "detailed"].contains(value) else { return }
    responseLength = value
    UserDefaults.standard.set(value, forKey: "PiSpaceVoiceLength")
    onSettingsChanged?()
  }

  func setMicrophoneMuted(_ muted: Bool) {
    microphoneMuted = muted
    if muted {
      silenceWork?.cancel()
      transcript = ""
      stopRecognition()
      if mode == .conversation { onState?("muted", "Microphone off") }
    } else if mode == .conversation {
      startRecognition(.conversation)
    } else if mode == .speaking {
      startBargeInRecognition()
    }
    onSettingsChanged?()
  }

  func togglePause() {
    if let previous = pausedMode {
      pausedMode = nil
      mode = previous
      if previous == .speaking {
        if kokoroPlayer?.play() == true { startBargeInRecognition() }
        else { speaker.continueSpeaking() }
        onState?("speaking", lastSpokenText)
      } else if previous == .conversation {
        startRecognition(.conversation)
      } else if previous == .waiting {
        onState?("thinking", "Your request is with Pi now.")
        drainSpeechBuffer(flush: speechResponseFinished)
        if mode == .waiting, !speechResponseFinished { startRecognition(.waiting) }
      }
    } else if [.conversation, .waiting, .speaking].contains(mode) {
      pausedMode = mode
      if mode == .speaking {
        kokoroPlayer?.pause()
        speaker.pauseSpeaking(at: .immediate)
      }
      stopRecognition()
      mode = .paused
      onState?("paused", "Voice conversation paused")
      if !microphoneMuted { startRecognition(.paused) }
    }
    onSettingsChanged?()
  }

  func repeatLastResponse() {
    guard mode == .conversation, !lastResponseText.isEmpty else { return }
    stopRecognition()
    speechQueue = [lastResponseText]
    speechBuffer = ""
    speechResponseFinished = true
    mode = .waiting
    playNextSpeechIfNeeded()
  }

  func installKokoro() {
    guard kokoroProcess == nil else { return }
    guard let script = Bundle.main.path(forResource: "install-kokoro", ofType: "sh") else {
      onInstallState?("error", "The Kokoro installer is missing from this build.")
      return
    }
    onInstallState?("installing", "Installing the local model and voice dependencies. This can take several minutes.")
    let process = Process()
    let output = Pipe()
    var captured = Data()
    let captureQueue = DispatchQueue(label: "com.pispace.kokoro-installer-output")
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [script]
    process.standardOutput = output
    process.standardError = output
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty { captureQueue.sync { captured.append(data) } }
    }
    process.terminationHandler = { [weak self] process in
      output.fileHandleForReading.readabilityHandler = nil
      let tailData = output.fileHandleForReading.readDataToEndOfFile()
      let result = captureQueue.sync { () -> Data in
        captured.append(tailData)
        return captured
      }
      let text = String(data: result, encoding: .utf8) ?? ""
      let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Pi Space/kokoro-install.log")
      try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? text.write(to: logURL, atomically: true, encoding: .utf8)
      DispatchQueue.main.async {
        guard let self else { return }
        self.kokoroProcess = nil
        if process.terminationStatus == 0, self.kokoroInstalled {
          self.onInstallState?("ready", "Kokoro is installed and ready.")
          self.onSettingsChanged?()
        } else {
          let useful = text.split(separator: "\n").map(String.init)
            .last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Installation failed."
          self.onInstallState?("error", "\(useful) Log: ~/Library/Logs/Pi Space/kokoro-install.log")
        }
      }
    }
    do {
      try process.run()
      kokoroProcess = process
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      onInstallState?("error", "Could not start the Kokoro installer: \(error.localizedDescription)")
    }
  }

  func stopKokoro() {
    kokoroProcess?.terminate()
    kokoroProcess = nil
    kokoroPlayer?.stop()
    kokoroPlayer = nil
    clearKokoroPrefetch()
  }

  func shutdown() {
    mode = .idle
    generation += 1
    silenceWork?.cancel()
    restartWork?.cancel()
    stopRecognition()
    speaker.stopSpeaking(at: .immediate)
    kokoroPlayer?.stop()
    kokoroPlayer = nil
    clearKokoroPrefetch()
    if let kokoroAudioURL { try? FileManager.default.removeItem(at: kokoroAudioURL) }
    kokoroAudioURL = nil
    stopKokoroServer()
    kokoroProcess?.terminate()
    kokoroProcess = nil
  }

  func startWakeListenerIfEnabled() {}

  func setWakeEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(false, forKey: wakeKey)
    if mode == .wake {
      stopRecognition()
      mode = .idle
    }
    onSettingsChanged?()
  }

  func setVoice(identifier: String) {
    guard AVSpeechSynthesisVoice(identifier: identifier) != nil else { return }
    UserDefaults.standard.set(identifier, forKey: voiceKey)
    onSettingsChanged?()
  }

  func previewVoice() {
    guard mode == .idle || mode == .wake else { return }
    generation += 1
    stopRecognition()
    mode = .preview
    if kokoroInstalled {
      speakWithKokoro("Hi, I’m Pi. This is how I’ll sound during voice conversations.")
      return
    }
    let utterance = AVSpeechUtterance(string: "Kokoro is not installed yet. Install it for a natural local voice.")
    utterance.rate = 0.48
    utterance.voice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) ?? preferredVoice()
    speaker.speak(utterance)
  }

  func availableVoices() -> [[String: Any]] {
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
      .sorted {
        if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
    return voices.map { voice in
      let quality = voice.quality == .premium ? "Premium" : voice.quality == .enhanced ? "Enhanced" : "Standard"
      return ["id": voice.identifier, "name": "\(voice.name) · \(voice.language) · \(quality)"]
    }
  }

  func start() {
    guard mode == .idle || mode == .wake else { return }
    generation += 1
    stopRecognition()
    speechQueue.removeAll()
    speechBuffer = ""
    responseTextBuffer = ""
    speechResponseFinished = false
    receivedStreamingSpeech = false
    microphoneMuted = false
    pausedMode = nil
    lastResponseText = ""
    mode = .conversation
    onState?("starting", "Requesting microphone access…")
    if kokoroInstalled { startKokoroServer { _ in } }
    requestPermissions { [weak self] in self?.startRecognition(.conversation) }
  }

  func end(abortResponse: Bool = true) {
    let shouldAbort = (mode == .waiting || mode == .speaking || pausedMode == .waiting || pausedMode == .speaking) && abortResponse
    mode = .idle
    pausedMode = nil
    microphoneMuted = false
    transcript = ""
    onTranscript?("", false)
    speechQueue.removeAll()
    speechBuffer = ""
    responseTextBuffer = ""
    speechResponseFinished = false
    receivedStreamingSpeech = false
    generation += 1
    silenceWork?.cancel()
    restartWork?.cancel()
    silenceWork = nil
    restartWork = nil
    kokoroPlayer?.stop()
    kokoroPlayer = nil
    clearKokoroPrefetch()
    if let kokoroAudioURL { try? FileManager.default.removeItem(at: kokoroAudioURL) }
    kokoroAudioURL = nil
    stopKokoroServer()
    speaker.stopSpeaking(at: .immediate)
    stopRecognition()
    onState?("idle", "")
    if shouldAbort { onAbort?() }
  }

  func receiveResponse(_ text: String) {
    guard mode == .waiting || (mode == .paused && pausedMode == .waiting) else { return }
    receivedStreamingSpeech = false
    speechBuffer = text
    responseTextBuffer = text
    finishResponseStreaming(fallback: text)
  }

  func receiveResponseChunk(_ text: String) {
    guard !text.isEmpty,
      mode == .waiting || mode == .speaking || (mode == .paused && (pausedMode == .waiting || pausedMode == .speaking))
    else { return }
    receivedStreamingSpeech = true
    responseTextBuffer += text
    speechBuffer += text
    drainSpeechBuffer()
  }

  func finishResponseStreaming(fallback: String = "") {
    guard mode == .waiting || mode == .speaking || (mode == .paused && (pausedMode == .waiting || pausedMode == .speaking)) else { return }
    if !receivedStreamingSpeech && speechBuffer.isEmpty { speechBuffer = fallback }
    if responseTextBuffer.isEmpty { responseTextBuffer = fallback }
    lastResponseText = cleanSpeechText(responseTextBuffer)
    speechResponseFinished = true
    drainSpeechBuffer(flush: true)
    if speechQueue.isEmpty && mode == .waiting {
      mode = .conversation
      startRecognition(.conversation)
    }
  }

  private func drainSpeechBuffer(flush: Bool = false) {
    while let boundary = speechBoundary(in: speechBuffer) {
      let sentence = cleanSpeechText(String(speechBuffer[..<boundary]))
      speechBuffer = String(speechBuffer[speechBuffer.index(after: boundary)...])
      enqueueSpeech(sentence)
    }
    if flush {
      let remainder = cleanSpeechText(speechBuffer)
      speechBuffer = ""
      enqueueSpeech(remainder)
    }
    if mode != .paused { playNextSpeechIfNeeded() }
  }

  private func enqueueSpeech(_ text: String) {
    guard !text.isEmpty else { return }
    if text.count < 28, !speechQueue.isEmpty {
      speechQueue[speechQueue.count - 1] += " " + text
    } else {
      speechQueue.append(text)
    }
    if mode == .speaking, kokoroInstalled { prefetchNextKokoroIfNeeded() }
  }

  private func cleanSpeechText(_ raw: String) -> String {
    raw.replacingOccurrences(of: "```[\\s\\S]*?```", with: " Code omitted. ", options: .regularExpression)
      .replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
      .replacingOccurrences(of: "!?(?:\\[([^]]+)\\])\\([^)]*\\)", with: "$1", options: .regularExpression)
      .replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
      .replacingOccurrences(of: "[*_#>|~]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func speechBoundary(in text: String) -> String.Index? {
    guard text.count > 24 else { return nil }
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)
      if ".!?".contains(character), next == text.endIndex || text[next].isWhitespace { return index }
      if text.distance(from: text.startIndex, to: index) > 180,
        ",;:".contains(character), next == text.endIndex || text[next].isWhitespace { return index }
      index = next
    }
    return nil
  }

  private func playNextSpeechIfNeeded() {
    guard mode != .speaking && mode != .paused, let next = speechQueue.first else { return }
    speechQueue.removeFirst()
    generation += 1
    stopRecognition()
    mode = .speaking
    lastSpokenText = next
    lastSpeechNormalized = normalizeSpeech(next)
    if lastResponseText.isEmpty { lastResponseText = next }
    onState?("speaking", next)
    if kokoroInstalled {
      if let prefetched = prefetchedKokoro, prefetched.text == next {
        prefetchedKokoro = nil
        playKokoroFile(prefetched.url, fallbackText: next)
      } else if prefetchClient != nil, prefetchText == next {
        speechQueue.insert(next, at: 0)
        mode = .waiting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.playNextSpeechIfNeeded() }
        return
      } else {
        speakWithKokoro(next)
      }
      prefetchNextKokoroIfNeeded()
    } else { speakWithSystemVoice(next) }
    if !microphoneMuted { startBargeInRecognition(after: 0.55) }
  }

  private func speakWithSystemVoice(_ text: String) {
    speaker.stopSpeaking(at: .immediate)
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = 0.48
    utterance.voice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) ?? preferredVoice()
    speaker.speak(utterance)
  }

  private func startKokoroServer(_ completion: @escaping (Bool) -> Void) {
    let socket = kokoroRoot.appendingPathComponent("tts.sock")
    if kokoroProcess?.isRunning == true {
      pollKokoroSocket(socket, process: kokoroProcess!, completion: completion)
      return
    }
    guard let python = try? String(contentsOf: kokoroRoot.appendingPathComponent("python-path"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines), !python.isEmpty else { completion(false); return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: python)
    process.arguments = [kokoroRoot.appendingPathComponent("tts-server.py").path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try? FileManager.default.removeItem(at: socket)
      try process.run()
      kokoroProcess = process
    } catch { completion(false); return }
    pollKokoroSocket(socket, process: process, completion: completion)
  }

  private func pollKokoroSocket(_ socket: URL, process: Process, completion: @escaping (Bool) -> Void) {
    func poll(_ remaining: Int) {
      if FileManager.default.fileExists(atPath: socket.path) { completion(true); return }
      if remaining == 0 || process.isRunning == false { completion(false); return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { poll(remaining - 1) }
    }
    poll(80)
  }

  private func makeKokoroClient(_ text: String) -> (Process, Pipe)? {
    let request: [String: Any] = ["text": text, "voice": kokoroVoice, "speed": 1.0]
    guard let data = try? JSONSerialization.data(withJSONObject: request),
      let json = String(data: data, encoding: .utf8) else { return nil }
    let client = Process()
    let output = Pipe()
    client.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    client.arguments = ["-c", "import socket,sys;s=socket.socket(socket.AF_UNIX);s.settimeout(180);s.connect(sys.argv[1]);s.sendall((sys.argv[2]+'\\n').encode());d=b''\nwhile b'\\n' not in d:\n c=s.recv(4096)\n if not c: break\n d+=c\nprint(d.decode().strip())", kokoroRoot.appendingPathComponent("tts.sock").path, json]
    client.standardOutput = output
    client.standardError = FileHandle.nullDevice
    return (client, output)
  }

  private func kokoroOutputURL(_ output: Pipe) -> URL? {
    let result = output.fileHandleForReading.readDataToEndOfFile()
    guard let object = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
      object["status"] as? String == "ok", let path = object["audio_file"] as? String else { return nil }
    return URL(fileURLWithPath: path)
  }

  private func playKokoroFile(_ url: URL, fallbackText: String) {
    guard let player = try? AVAudioPlayer(contentsOf: url) else {
      try? FileManager.default.removeItem(at: url)
      speakWithSystemVoice(fallbackText)
      return
    }
    kokoroPlayer = player
    kokoroAudioURL = url
    player.delegate = self
    if mode != .paused { player.play() }
  }

  private func prefetchNextKokoroIfNeeded() {
    guard prefetchedKokoro == nil, prefetchClient == nil, let next = speechQueue.first else { return }
    let token = prefetchGeneration
    startKokoroServer { [weak self] ready in
      guard let self, ready, token == self.prefetchGeneration, self.mode == .speaking,
        let (client, output) = self.makeKokoroClient(next) else { return }
      self.prefetchClient = client
      self.prefetchText = next
      client.terminationHandler = { [weak self, weak client] _ in
        guard let self else { return }
        let url = self.kokoroOutputURL(output)
        DispatchQueue.main.async {
          let canUsePrefetch = self.mode == .speaking
            || (self.mode == .waiting && self.speechQueue.first == next)
          guard token == self.prefetchGeneration, canUsePrefetch,
            self.prefetchClient === client, let url else {
            if self.prefetchClient === client {
              self.prefetchClient = nil
              self.prefetchText = nil
            }
            if let url { try? FileManager.default.removeItem(at: url) }
            return
          }
          self.prefetchClient = nil
          self.prefetchText = nil
          self.prefetchedKokoro = (next, url)
          if self.mode == .waiting { self.playNextSpeechIfNeeded() }
        }
      }
      do { try client.run() } catch {
        self.prefetchClient = nil
        self.prefetchText = nil
      }
    }
  }

  private func clearKokoroPrefetch() {
    prefetchGeneration += 1
    if prefetchClient?.isRunning == true { prefetchClient?.terminate() }
    prefetchClient = nil
    prefetchText = nil
    if let url = prefetchedKokoro?.url { try? FileManager.default.removeItem(at: url) }
    prefetchedKokoro = nil
  }

  private func speakWithKokoro(_ text: String) {
    let expectedMode = mode
    startKokoroServer { [weak self] ready in
      guard let self, self.mode == expectedMode else { return }
      guard ready, let (client, output) = self.makeKokoroClient(text) else { self.speakWithSystemVoice(text); return }
      client.terminationHandler = { [weak self] _ in
        guard let self else { return }
        let url = self.kokoroOutputURL(output)
        DispatchQueue.main.async {
          guard self.mode == expectedMode || (self.mode == .paused && self.pausedMode == expectedMode) else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
          }
          guard let url else { self.speakWithSystemVoice(text); return }
          self.playKokoroFile(url, fallbackText: text)
        }
      }
      do { try client.run() } catch { self.speakWithSystemVoice(text) }
    }
  }

  private func stopKokoroServer() {
    kokoroProcess?.terminate()
    kokoroProcess = nil
    try? FileManager.default.removeItem(at: kokoroRoot.appendingPathComponent("tts.sock"))
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    if mode == .preview {
      kokoroPlayer = nil
      if let kokoroAudioURL { try? FileManager.default.removeItem(at: kokoroAudioURL) }
      kokoroAudioURL = nil
      stopKokoroServer()
      mode = .idle
      startWakeListenerIfEnabled()
      return
    }
    guard mode == .speaking else { return }
    stopRecognition()
    kokoroPlayer = nil
    if let kokoroAudioURL { try? FileManager.default.removeItem(at: kokoroAudioURL) }
    kokoroAudioURL = nil
    if !speechQueue.isEmpty {
      mode = .waiting
      playNextSpeechIfNeeded()
    } else if speechResponseFinished {
      mode = .conversation
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
        self?.startRecognition(.conversation)
      }
    } else {
      mode = .waiting
      if !microphoneMuted { startRecognition(.waiting) }
    }
  }

  private func preferredVoice() -> AVSpeechSynthesisVoice? {
    let preferredNames = ["Ava", "Samantha", "Karen", "Daniel"]
    return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.max {
      let left = ($0.quality.rawValue * 100) + (preferredNames.firstIndex(of: $0.name).map { 20 - $0 } ?? 0)
      let right = ($1.quality.rawValue * 100) + (preferredNames.firstIndex(of: $1.name).map { 20 - $0 } ?? 0)
      return left < right
    }
  }

  private func requestPermissions(_ completion: @escaping () -> Void) {
    SFSpeechRecognizer.requestAuthorization { speechStatus in
      AVCaptureDevice.requestAccess(for: .audio) { microphoneGranted in
        DispatchQueue.main.async {
          guard speechStatus == .authorized, microphoneGranted else {
            self.mode = .idle
            self.stopRecognition()
            self.onState?("error", "Allow Microphone and Speech Recognition for Pi Space in System Settings.")
            return
          }
          completion()
        }
      }
    }
  }

  private func startRecognition(_ targetMode: Mode) {
    let allowed = targetMode == .wake
      ? (wakeEnabled && (mode == .idle || mode == .wake))
      : targetMode == .conversation ? mode == .conversation
      : targetMode == .waiting ? mode == .waiting
      : targetMode == .paused ? mode == .paused
      : targetMode == .speaking && mode == .speaking
    guard allowed, !microphoneMuted else { return }
    generation += 1
    let currentGeneration = generation
    stopRecognition()
    transcript = ""
    if targetMode != .speaking && targetMode != .waiting { onTranscript?("", false) }
    mode = targetMode

    let node = engine.inputNode
    if targetMode == .speaking {
      try? node.setVoiceProcessingEnabled(true)
    } else if node.isVoiceProcessingEnabled {
      try? node.setVoiceProcessingEnabled(false)
    }
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      if targetMode == .conversation || targetMode == .speaking { onState?("error", "The microphone is not available.") }
      return
    }
    let nextRequest = SFSpeechAudioBufferRecognitionRequest()
    nextRequest.shouldReportPartialResults = true
    nextRequest.taskHint = .dictation
    nextRequest.contextualStrings = []
    request = nextRequest
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      nextRequest.append(buffer)
    }
    tapInstalled = true
    engine.prepare()
    do {
      try engine.start()
    } catch {
      stopRecognition()
      if targetMode == .conversation || targetMode == .speaking { onState?("error", "Could not start the microphone: \(error.localizedDescription)") }
      else { scheduleRestart(targetMode, after: 3) }
      return
    }
    if targetMode == .conversation { onState?("listening", "") }
    task = recognizer?.recognitionTask(with: nextRequest) { [weak self] result, error in
      DispatchQueue.main.async {
        guard let self, currentGeneration == self.generation, self.mode == targetMode else { return }
        if let result { self.receiveTranscription(result.bestTranscription.formattedString, final: result.isFinal) }
        if error != nil || result?.isFinal == true {
          if targetMode == .wake { self.scheduleRestart(targetMode, after: 1.2) }
          else if error != nil && self.mode == .conversation {
            self.stopRecognition()
            self.onState?("error", "Speech Recognition stopped. Click End conversation and try again.")
          } else if (error != nil || result?.isFinal == true) && self.mode == .speaking {
            self.scheduleBargeInRestart()
          } else if (error != nil || result?.isFinal == true) && self.mode == .waiting {
            self.startRecognition(.waiting)
          } else if (error != nil || result?.isFinal == true) && self.mode == .paused {
            self.startRecognition(.paused)
          }
        }
      }
    }
  }

  private func receiveTranscription(_ value: String, final: Bool) {
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    let normalized = clean.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if mode == .wake { return }
    if mode == .speaking {
      guard isLikelyBargeIn(normalized, final: final) else { return }
      interruptSpeech(with: clean)
      return
    }
    if mode == .waiting || mode == .paused { return }
    guard mode == .conversation else { return }
    transcript = clean
    onTranscript?(clean, final)
    onState?("listening", "")
    scheduleSend(after: final ? min(0.35, responsePace.pause) : responsePace.pause)
  }

  private func scheduleSend(after delay: TimeInterval) {
    silenceWork?.cancel()
    let expected = transcript
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.mode == .conversation, self.transcript == expected else { return }
      let clean = expected.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !clean.isEmpty else { return }
      self.mode = .waiting
      self.transcript = ""
      self.onTranscript?(clean, true)
      self.generation += 1
      self.stopRecognition()
      self.onState?("thinking", "")
      self.onPrompt?(clean, false)
      if !self.microphoneMuted { self.startRecognition(.waiting) }
    }
    silenceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func startBargeInRecognition(after delay: TimeInterval = 0) {
    guard mode == .speaking, !microphoneMuted else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.mode == .speaking, !self.microphoneMuted else { return }
      self.startRecognition(.speaking)
    }
    restartWork?.cancel()
    restartWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func scheduleBargeInRestart() {
    guard mode == .speaking else { return }
    startBargeInRecognition(after: 0.35)
  }

  private func normalizeSpeech(_ value: String) -> String {
    value.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func isLikelyBargeIn(_ normalized: String, final: Bool) -> Bool {
    let words = normalized.split(separator: " ").map(String.init)
    guard words.count >= 2, normalized.count >= 5 else { return false }
    let spokenWords = Set(lastSpeechNormalized.split(separator: " ").map(String.init))
    let overlap = words.filter { spokenWords.contains($0) }.count
    let overlapRatio = Double(overlap) / Double(max(words.count, 1))
    if overlapRatio > 0.72 { return false }
    return final || words.count >= 3
  }

  private func interruptSpeech(with text: String) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    generation += 1
    restartWork?.cancel()
    silenceWork?.cancel()
    stopRecognition()
    kokoroPlayer?.stop()
    kokoroPlayer = nil
    clearKokoroPrefetch()
    if let kokoroAudioURL { try? FileManager.default.removeItem(at: kokoroAudioURL) }
    kokoroAudioURL = nil
    speaker.stopSpeaking(at: .immediate)
    speechQueue.removeAll()
    speechBuffer = ""
    responseTextBuffer = ""
    speechResponseFinished = false
    receivedStreamingSpeech = false
    mode = .waiting
    transcript = ""
    onTranscript?(clean, true)
    onState?("thinking", "Interrupted. Passing your new request to Pi.")
    onAbort?()
    onPrompt?(clean, true)
  }

  private func scheduleRestart(_ targetMode: Mode, after delay: TimeInterval) {
    restartWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if targetMode == .wake, self.wakeEnabled, self.mode == .wake { self.startRecognition(.wake) }
    }
    restartWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func stopRecognition() {
    if engine.isRunning { engine.stop() }
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    request?.endAudio()
    request = nil
    task?.cancel()
    task = nil
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    if mode == .preview {
      mode = .idle
      startWakeListenerIfEnabled()
      return
    }
    guard mode == .speaking else { return }
    stopRecognition()
    if !speechQueue.isEmpty {
      mode = .waiting
      playNextSpeechIfNeeded()
    } else if speechResponseFinished {
      mode = .conversation
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.startRecognition(.conversation)
      }
    } else {
      mode = .waiting
    }
  }
}

final class MacUpdateService {
  var stateChanged: (([String: Any]) -> Void)?
  let currentVersion: String
  private let owner = "bonnieBluesKid69"
  private let repository = "pi-space"
  private let dmgAsset = "Pi-Space-macOS.dmg"
  private let checksumAsset = "Pi-Space-macOS.sha256"
  private var available: (version: String, dmg: URL, checksum: URL)?

  init() {
    currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  func check(manual: Bool) {
    emit("checking", ["manual": manual])
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!)
    request.setValue("Pi-Space-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      do {
        if let error { throw error }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
          throw NSError(domain: "PiSpaceUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "GitHub did not return a valid release."])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = json["tag_name"] as? String,
          let assets = json["assets"] as? [[String: Any]]
        else { throw NSError(domain: "PiSpaceUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "The release metadata is malformed."]) }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.compare(version, self.currentVersion) == .orderedDescending else {
          self.available = nil
          self.emit("current", ["manual": manual])
          return
        }
        func asset(_ name: String) -> URL? {
          guard let value = assets.first(where: { $0["name"] as? String == name })?["browser_download_url"] as? String else { return nil }
          return URL(string: value)
        }
        guard let dmg = asset(self.dmgAsset), let checksum = asset(self.checksumAsset) else {
          throw NSError(domain: "PiSpaceUpdate", code: 3, userInfo: [NSLocalizedDescriptionKey: "Pi Space \(version) does not include the required macOS DMG and checksum."])
        }
        self.available = (version, dmg, checksum)
        if self.canReplaceInstallation() {
          self.emit("available", ["manual": manual, "version": version])
        } else {
          self.emit("manual", [
            "manual": manual,
            "version": version,
            "message": self.manualInstallMessage(),
          ])
        }
      } catch { self.emit("error", ["manual": manual, "message": "Could not check for updates: \(error.localizedDescription)"]) }
    }.resume()
  }

  func install() {
    guard let release = available else {
      emit("error", ["manual": true, "message": "Check for updates before installing."])
      return
    }
    guard canReplaceInstallation() else {
      emit("manual", ["manual": true, "version": release.version, "message": manualInstallMessage()])
      return
    }
    emit("downloading", ["version": release.version])
    let group = DispatchGroup()
    var dmgData: Data?
    var checksumData: Data?
    var failure: Error?
    for (url, assign) in [(release.dmg, { dmgData = $0 }), (release.checksum, { checksumData = $0 })] {
      group.enter()
      var request = URLRequest(url: url)
      request.setValue("Pi-Space-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
      URLSession.shared.dataTask(with: request) { data, response, error in
        defer { group.leave() }
        if let error { failure = error; return }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
          failure = NSError(domain: "PiSpaceUpdate", code: 4, userInfo: [NSLocalizedDescriptionKey: "An update asset could not be downloaded."])
          return
        }
        assign(data)
      }.resume()
    }
    group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
      guard let self else { return }
      do {
        if let failure { throw failure }
        guard let dmgData, let checksumData, let checksumText = String(data: checksumData, encoding: .utf8) else {
          throw NSError(domain: "PiSpaceUpdate", code: 5, userInfo: [NSLocalizedDescriptionKey: "The downloaded update is incomplete."])
        }
        let expected = try self.parseChecksum(checksumText)
        let actual = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()
        guard self.hashesMatch(expected, actual) else {
          throw NSError(domain: "PiSpaceUpdate", code: 6, userInfo: [NSLocalizedDescriptionKey: "The macOS update checksum does not match. Nothing was installed."])
        }
        self.emit("installing", ["version": release.version])
        try self.stageAndLaunchInstaller(dmgData: dmgData, version: release.version)
      } catch { self.emit("error", ["manual": true, "phase": "install", "message": "Update failed: \(error.localizedDescription)"]) }
    }
  }

  private func parseChecksum(_ text: String) throws -> String {
    let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let first = fields.first else { throw NSError(domain: "PiSpaceUpdate", code: 7, userInfo: [NSLocalizedDescriptionKey: "The checksum file is empty."]) }
    let hash = String(first).lowercased()
    guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
      throw NSError(domain: "PiSpaceUpdate", code: 8, userInfo: [NSLocalizedDescriptionKey: "The checksum file is invalid."])
    }
    if fields.count > 1 {
      let filename = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
      guard filename == dmgAsset else { throw NSError(domain: "PiSpaceUpdate", code: 9, userInfo: [NSLocalizedDescriptionKey: "The checksum names an unexpected file."]) }
    }
    return hash
  }

  private func stageAndLaunchInstaller(dmgData: Data, version: String) throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("PiSpaceUpdate-\(UUID().uuidString)")
    let mount = root.appendingPathComponent("mount")
    let staged = root.appendingPathComponent("Pi Space.app")
    try fm.createDirectory(at: mount, withIntermediateDirectories: true)
    let dmg = root.appendingPathComponent(dmgAsset)
    try dmgData.write(to: dmg, options: .atomic)
    let attach = try run("/usr/bin/hdiutil", ["attach", dmg.path, "-mountpoint", mount.path, "-nobrowse", "-readonly"])
    guard attach == 0 else { throw NSError(domain: "PiSpaceUpdate", code: 10, userInfo: [NSLocalizedDescriptionKey: "The verified DMG could not be mounted."]) }
    defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
    let source = mount.appendingPathComponent("Pi Space.app")
    guard fm.fileExists(atPath: source.appendingPathComponent("Contents/MacOS/PiSpace").path) else {
      throw NSError(domain: "PiSpaceUpdate", code: 11, userInfo: [NSLocalizedDescriptionKey: "The DMG does not contain Pi Space.app."])
    }
    guard Bundle(url: source)?.bundleIdentifier == "com.pispace.app" else {
      throw NSError(domain: "PiSpaceUpdate", code: 12, userInfo: [NSLocalizedDescriptionKey: "The update has an unexpected bundle identifier."])
    }
    guard try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path]) == 0 else {
      throw NSError(domain: "PiSpaceUpdate", code: 13, userInfo: [NSLocalizedDescriptionKey: "The update application failed signature validation."])
    }
    guard try run("/usr/bin/ditto", [source.path, staged.path]) == 0 else {
      throw NSError(domain: "PiSpaceUpdate", code: 14, userInfo: [NSLocalizedDescriptionKey: "The update application could not be staged."])
    }
    let target = Bundle.main.bundleURL.standardizedFileURL
    guard canReplaceInstallation(), target.path.hasSuffix(".app") else {
      throw NSError(domain: "PiSpaceUpdate", code: 15, userInfo: [NSLocalizedDescriptionKey: manualInstallMessage()])
    }
    let log = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Pi Space/update.log")
    try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    let helper = root.appendingPathComponent("install-update.sh")
    let script = """
      #!/bin/bash
      set -u
      target=\(shellQuote(target.path))
      staged=\(shellQuote(staged.path))
      backup="${target}.previous"
      log=\(shellQuote(log.path))
      pid=\(ProcessInfo.processInfo.processIdentifier)
      while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
      rm -rf "$backup"
      if ! mv "$target" "$backup" >>"$log" 2>&1; then exit 1; fi
      if /usr/bin/ditto "$staged" "$target" >>"$log" 2>&1; then
        rm -rf "$backup"
        /usr/bin/open "$target"
        rm -rf \(shellQuote(root.path))
      else
        rm -rf "$target"
        mv "$backup" "$target"
        /usr/bin/open "$target"
        exit 1
      fi
      """
    try script.write(to: helper, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [helper.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    DispatchQueue.main.async { NSApp.terminate(nil) }
  }

  func openAvailableDMG() {
    guard let url = available?.dmg else {
      emit("error", ["manual": true, "message": "Check for updates before downloading the DMG."])
      return
    }
    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
  }

  private func canReplaceInstallation() -> Bool {
    let fm = FileManager.default
    let target = Bundle.main.bundleURL.standardizedFileURL
    guard target.path.hasSuffix(".app") else { return false }
    let parent = target.deletingLastPathComponent()
    let probe = parent.appendingPathComponent(".pi-space-update-write-test-\(UUID().uuidString)")
    do {
      try Data().write(to: probe, options: .atomic)
      try fm.removeItem(at: probe)
      return true
    } catch {
      try? fm.removeItem(at: probe)
      return false
    }
  }

  private func manualInstallMessage() -> String {
    let path = Bundle.main.bundleURL.standardizedFileURL.path
    if path.hasPrefix("/Volumes/") {
      return "Pi Space is running from a read-only DMG. Download the update, quit Pi Space, then drag it to Applications."
    }
    return "Pi Space cannot replace itself in \(path). Download the DMG and replace it manually, or move Pi Space to ~/Applications for future in-app updates."
  }

  private func hashesMatch(_ left: String, _ right: String) -> Bool {
    let a = Array(left.utf8)
    let b = Array(right.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in a.indices { difference |= a[index] ^ b[index] }
    return difference == 0
  }

  private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  private func emit(_ status: String, _ extra: [String: Any] = [:]) {
    var payload = extra
    payload["status"] = status
    payload["currentVersion"] = currentVersion
    DispatchQueue.main.async { [weak self] in self?.stateChanged?(payload) }
  }

  private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  static func compare(_ left: String, _ right: String) -> ComparisonResult {
    left.compare(right, options: .numeric)
  }
}

final class Controller: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
  let rpc = RPC()
  var web: WKWebView!
  var ready = false
  var queue = [[String: Any]]()
  var files = [URL]()
  var cwd = NSHomeDirectory()
  var selectedProvider = UserDefaults.standard.string(forKey: "PiSpaceProvider")
  var selectedModel = UserDefaults.standard.string(forKey: "PiSpaceModel")
  var pendingModel: (provider: String, model: String)?
  let voice = VoiceConversation()
  let updater = MacUpdateService()
  let kokoroSupported: Bool = {
    #if arch(arm64)
      return true
    #else
      return false
    #endif
  }()
  var pendingVoiceActions = [[String: String]]()
  let voiceNotification = Notification.Name("com.olivergreen.pispace.voice")
  let voiceResponseNotification = Notification.Name("com.olivergreen.pispace.voice.response")
  let modelsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent/models.json")
  let managedModels: [[String: Any]] = [
    ["choice": "ox-alpha", "variant": "Ox Alpha", "provider": "openrouter", "providerLabel": "OpenRouter", "id": "stealth/ox-alpha", "name": "stealth/ox-alpha", "contextWindow": 1_048_576, "maxOutputTokens": 131_072],
    ["choice": "gpt-5.6-sol", "variant": "GPT-5.6 Sol", "provider": "agentrouter", "providerLabel": "AgentRouter", "id": "gpt-5.6-sol", "name": "gpt-5.6-sol", "contextWindow": 128_000, "maxOutputTokens": 16_384],
    ["choice": "opus-5", "variant": "Claude Opus 5", "provider": "agentrouter", "providerLabel": "AgentRouter", "id": "claude-opus-5", "name": "claude-opus-5", "contextWindow": 128_000, "maxOutputTokens": 16_384],
    ["choice": "opus-5", "variant": "Claude Opus 5", "provider": "tabitoken", "providerLabel": "TabiToken", "id": "claude-opus-5", "name": "claude-opus-5", "contextWindow": 200_000, "maxOutputTokens": 32_768],
    ["choice": "opus-5-thinking", "variant": "Claude Opus 5 Thinking", "provider": "tabitoken", "providerLabel": "TabiToken", "id": "claude-opus-5-thinking", "name": "claude-opus-5-thinking", "contextWindow": 200_000, "maxOutputTokens": 32_768],
    ["choice": "opus-4.8", "variant": "Claude Opus 4.8", "provider": "agentrouter", "providerLabel": "AgentRouter", "id": "claude-opus-4-8", "name": "claude-opus-4-8", "contextWindow": 128_000, "maxOutputTokens": 16_384],
    ["choice": "opus-4.8", "variant": "Claude Opus 4.8", "provider": "tabitoken", "providerLabel": "TabiToken", "id": "claude-opus-4-8", "name": "claude-opus-4-8", "contextWindow": 200_000, "maxOutputTokens": 32_768],
    ["choice": "opus-4.8-thinking", "variant": "Claude Opus 4.8 Thinking", "provider": "tabitoken", "providerLabel": "TabiToken", "id": "claude-opus-4-8-thinking", "name": "claude-opus-4-8-thinking", "contextWindow": 200_000, "maxOutputTokens": 32_768],
    ["choice": "kimi-k3-free", "variant": "Kimi K3 Free", "provider": "tokenrouter", "providerLabel": "TokenRouter", "id": "moonshotai/kimi-k3-free", "name": "moonshotai/kimi-k3-free", "contextWindow": 200_000, "maxOutputTokens": 32_768],
  ]
  let defaultTabiTokenBaseURL = "https://api.tabitoken.com/v1"
  let defaultOpenRouterBaseURL = "https://openrouter.ai/api/v1"
  let instructionsURL = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".pi/agent/pi-space-instructions.txt")
  func instructions() -> String {
    (try? String(contentsOf: instructionsURL, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
  func saveInstructions(_ text: String) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    try? FileManager.default.createDirectory(
      at: instructionsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? clean.write(to: instructionsURL, atomically: true, encoding: .utf8)
    js("instructionsSaved", ["text": clean])
  }
  override func loadView() {
    let c = WKWebViewConfiguration()
    c.userContentController.add(self, name: "piSpace")
    web = WKWebView(frame: .zero, configuration: c)
    web.navigationDelegate = self
    web.setValue(false, forKey: "drawsBackground")
    view = web
  }
  override func viewDidLoad() {
    super.viewDidLoad()
    UserDefaults.standard.set(false, forKey: "PiSpaceWakePhrasesEnabled")
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(receiveVoiceAction(_:)), name: voiceNotification, object: nil)
    voice.onState = { [weak self] state, text in self?.js("voiceState", ["state": state, "text": text]) }
    voice.onInstallState = { [weak self] state, text in self?.js("kokoroInstallState", ["state": state, "text": text]) }
    updater.stateChanged = { [weak self] state in self?.js("updateState", state) }
    voice.onTranscript = { [weak self] text, final in self?.js("voiceTranscript", ["text": text, "final": final]) }
    voice.onPrompt = { [weak self] text, interrupt in
      self?.js("voicePrompt", ["text": text, "conversation": true, "interrupt": interrupt])
    }
    voice.onAbort = { [weak self] in self?.rpc.send(["type": "abort"]) }
    voice.onWake = { [weak self] in
      self?.view.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    voice.onSettingsChanged = { [weak self] in
      guard let self else { return }
      self.syncProviderSettings()
      self.js("voiceSettings", [
        "pace": self.voice.voicePace,
        "length": self.voice.voiceLength,
        "muted": self.voice.isMicrophoneMuted,
        "paused": self.voice.isPaused,
      ])
    }
    rpc.event = { [weak self] in self?.forward($0) }
    rpc.failure = { [weak self] in self?.js("appError", ["message": $0]) }
    guard let path = Bundle.main.path(forResource: "PiSpace", ofType: "html"),
      let html = try? String(contentsOfFile: path, encoding: .utf8)
    else {
      web.loadHTMLString("<h2>Pi Space resources are missing.</h2>", baseURL: nil)
      return
    }
    web.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
  }
  @objc func receiveVoiceAction(_ notification: Notification) {
    guard let info = notification.userInfo as? [String: String], info["action"] != nil else { return }
    if !ready {
      pendingVoiceActions.append(info)
      return
    }
    handleVoiceAction(info)
  }

  private func handleVoiceAction(_ info: [String: String]) {
    guard let action = info["action"] else { return }
    switch action {
    case "prompt":
      if let text = info["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        js("voicePrompt", ["text": text, "conversation": info["conversation"] == "true"])
      }
    case "abort": rpc.send(["type": "abort"])
    case "bed": rpc.send(["type": "abort"])
    default: break
    }
  }

  func publishVoiceResponse(_ text: String) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    voice.receiveResponse(clean)
    DistributedNotificationCenter.default().postNotificationName(
      voiceResponseNotification, object: nil, userInfo: ["text": clean], deliverImmediately: true)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
  {
    guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url
    else {
      decisionHandler(.allow)
      return
    }
    if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
      NSWorkspace.shared.open(url)
    }
    decisionHandler(.cancel)
  }
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
    ready = true
    js("hostCapabilities", [
      "bridgeVersion": 1,
      "platform": "macos",
      "voice": true,
      "wakePhrases": false,
      "kokoro": kokoroSupported,
      "fileDialogs": true,
      "secureProviderConfig": true,
      "updates": true,
      "appVersion": updater.currentVersion,
    ])
    queue.forEach(forward)
    queue.removeAll()
    pendingVoiceActions.forEach(handleVoiceAction)
    pendingVoiceActions.removeAll()
    js("workspaceChosen", ["path": cwd])
    js("instructionsLoaded", ["text": instructions()])
    ensureManagedModels()
    chooseInitialModel()
    syncProviderSettings()
    voice.startWakeListenerIfEnabled()
    rpc.start(cwd, continuing: false, provider: selectedProvider, model: selectedModel)
    if selectedProvider == "openrouter", selectedModel == "stealth/ox-alpha" {
      rpc.send(["type": "set_thinking_level", "level": "minimal"])
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.updater.check(manual: false) }
  }
  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    guard let b = m.body as? [String: Any], let a = b["action"] as? String else { return }
    switch a {
    case "voiceStart": voice.start()
    case "voiceEnd": voice.end()
    case "voiceMute":
      if let muted = b["muted"] as? Bool { voice.setMicrophoneMuted(muted) }
    case "voicePause": voice.togglePause()
    case "voiceRepeat": voice.repeatLastResponse()
    case "setVoicePace":
      if let value = b["value"] as? String { voice.setResponsePace(value) }
    case "setVoiceLength":
      if let value = b["value"] as? String { voice.setResponseLength(value) }
    case "setWakePhrases":
      if let enabled = b["enabled"] as? Bool { voice.setWakeEnabled(enabled) }
    case "setVoice":
      if let identifier = b["identifier"] as? String { voice.setVoice(identifier: identifier) }
    case "setKokoroVoice":
      if let identifier = b["identifier"] as? String { voice.setKokoroVoice(identifier) }
    case "installKokoro": voice.installKokoro()
    case "openKokoroLog":
      let log = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Pi Space/kokoro-install.log")
      if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.open(log) }
    case "checkForUpdates": updater.check(manual: true)
    case "installUpdate": updater.install()
    case "openUpdateDMG": updater.openAvailableDMG()
    case "openVoiceSettings":
      if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Spoken_Content") {
        NSWorkspace.shared.open(url)
      }
    case "previewVoice": voice.previewVoice()
    case "prompt":
      if let t = b["text"] as? String {
        let custom = instructions()
        let supplied = b["attachments"] as? [[String: Any]] ?? []
        var images = [[String: Any]]()
        var fileContext = [String]()
        for attachment in supplied.prefix(5) {
          guard let name = attachment["name"] as? String,
            let mimeType = attachment["mimeType"] as? String,
            let data = attachment["data"] as? String
          else { continue }
          if mimeType == "application/x-directory", let decoded = Data(base64Encoded: data),
            let path = String(data: decoded, encoding: .utf8)
          {
            fileContext.append("Attached local folder: \(path). Inspect it with the available tools.")
          } else if mimeType.hasPrefix("image/") {
            images.append(["type": "image", "data": data, "mimeType": mimeType])
          } else if let decoded = Data(base64Encoded: data), decoded.count <= 1_000_000,
            let content = String(data: decoded, encoding: .utf8)
          {
            fileContext.append("""
              <attached_file name="\(name)" mime_type="\(mimeType)">
              \(content)
              </attached_file>
              """)
          } else {
            fileContext.append("Attached binary file: \(name) (\(mimeType)).")
          }
        }
        let userText = ([t] + fileContext).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let conversation = b["conversation"] as? Bool ?? false
        let persistentBlock = custom.isEmpty
          ? ""
          : """
            <persistent_user_instructions>
            Follow these preferences throughout this response unless they conflict with safety, system, or developer requirements:
            \(custom)
            </persistent_user_instructions>

            """
        let voiceBlock = conversation
          ? """
            <voice_response_instructions>
            Respond conversationally for spoken delivery. Do not use Markdown, code blocks, raw links, or long lists unless explicitly requested. Response length: \(voice.voiceLength). Concise means a few natural sentences, normal means a short complete explanation, and detailed means a fuller spoken answer without unnecessary repetition.
            </voice_response_instructions>

            """
          : ""
        let message = (persistentBlock + voiceBlock).isEmpty
          ? userText
          : """
            \(persistentBlock)\(voiceBlock)<user_message>
            \(userText)
            </user_message>
            """
        var command: [String: Any] = [
          "type": "prompt", "message": message, "streamingBehavior": "steer",
        ]
        if !images.isEmpty { command["images"] = images }
        rpc.send(command)
      }
    case "abort": rpc.send(["type": "abort"])
    case "chooseAttachments": chooseAttachments()
    case "copyText":
      if let text = b["text"] as? String {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      }
    case "newSession": rpc.send(["type": "new_session"])
    case "sessionTree": rpc.send(["type": "get_fork_messages"])
    case "forkSession":
      if let entryID = b["entryId"] as? String { rpc.send(["type": "fork", "entryId": entryID]) }
    case "compact": rpc.send(["type": "compact"])
    case "rpcCommand":
      guard let command = b["command"] as? String,
        ["abort", "abort_retry", "abort_bash", "clone", "export_html"].contains(command)
      else { return }
      var request: [String: Any] = ["type": command]
      if command == "export_html", let outputPath = b["outputPath"] as? String, !outputPath.isEmpty {
        request["outputPath"] = NSString(string: outputPath).expandingTildeInPath
      }
      rpc.send(request)
    case "rpcToggle":
      guard let command = b["command"] as? String,
        ["set_auto_compaction", "set_auto_retry"].contains(command),
        let enabled = b["enabled"] as? Bool
      else { return }
      rpc.send(["type": command, "enabled": enabled])
    case "refresh": refresh()
    case "sessions": sessions()
    case "switchSession":
      if let i = b["index"] as? Int, files.indices.contains(i) {
        rpc.send(["type": "switch_session", "sessionPath": files[i].path])
      }
    case "chooseWorkspace": choose()
    case "chooseAndApplyWorkspace": choose(applySelection: true)
    case "applyWorkspace": if let p = b["path"] as? String { apply(p) }
    case "setModel":
      if let provider = b["provider"] as? String, let model = b["model"] as? String {
        selectModel(provider: provider, model: model)
      }
    case "saveProviderKeys":
      saveProviderKeys(
        agentRouterKey: b["agentRouterKey"] as? String,
        tokenRouterKey: b["tokenRouterKey"] as? String,
        tabiTokenKey: b["tabiTokenKey"] as? String,
        openRouterKey: b["openRouterKey"] as? String,
        tabiTokenBaseURL: b["tabiTokenBaseURL"] as? String)
    case "updateProviderKey":
      guard let provider = b["provider"] as? String, let key = b["key"] as? String else { return }
      switch provider.lowercased() {
      case "agentrouter":
        saveProviderKeys(agentRouterKey: key, tokenRouterKey: nil, tabiTokenKey: nil, openRouterKey: nil, tabiTokenBaseURL: nil)
      case "tokenrouter":
        saveProviderKeys(agentRouterKey: nil, tokenRouterKey: key, tabiTokenKey: nil, openRouterKey: nil, tabiTokenBaseURL: nil)
      case "openrouter":
        saveProviderKeys(agentRouterKey: nil, tokenRouterKey: nil, tabiTokenKey: nil, openRouterKey: key, tabiTokenBaseURL: nil)
      case "tabitoken":
        saveProviderKeys(agentRouterKey: nil, tokenRouterKey: nil, tabiTokenKey: key, openRouterKey: nil, tabiTokenBaseURL: nil)
      default:
        js("commandResult", ["success": false, "message": "Unknown provider: \(provider)"])
      }
    case "saveInstructions":
      if let text = b["text"] as? String { saveInstructions(text) }
    case "setThinking":
      if let l = b["level"] as? String { rpc.send(["type": "set_thinking_level", "level": l]) }
    case "extensionUIResponse":
      var response: [String: Any] = ["type": "extension_ui_response"]
      for key in ["id", "value", "confirmed", "cancelled"] {
        if let value = b[key] { response[key] = value }
      }
      rpc.send(response)
    default: break
    }
  }
  func readModelsConfig() -> [String: Any] {
    guard let data = try? Data(contentsOf: modelsURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return ["providers": [String: Any]()] }
    return object
  }
  func providerConfigured(_ name: String, config: [String: Any]) -> Bool {
    guard let providers = config["providers"] as? [String: Any],
      let provider = providers[name] as? [String: Any],
      (provider["apiKey"] as? String)?.isEmpty == false
    else { return false }
    if name == "tabitoken" {
      guard let value = provider["baseUrl"] as? String, let url = URL(string: value),
        url.scheme?.lowercased() == "https", url.host?.isEmpty == false
      else { return false }
    }
    return true
  }
  func providerLabel(_ name: String) -> String {
    ["agentrouter": "AgentRouter", "openrouter": "OpenRouter", "tokenrouter": "TokenRouter", "tabitoken": "TabiToken"][name]
      ?? name
  }
  func chooseInitialModel() {
    if selectedProvider == "agentrouter", selectedModel == "claude-opus-4.8" {
      selectedModel = "claude-opus-4-8"
      UserDefaults.standard.set(selectedModel, forKey: "PiSpaceModel")
    }
    guard selectedProvider == nil || selectedModel == nil else { return }
    let config = readModelsConfig()
    if providerConfigured("openrouter", config: config) {
      selectedProvider = "openrouter"
      selectedModel = "stealth/ox-alpha"
    } else if providerConfigured("agentrouter", config: config) {
      selectedProvider = "agentrouter"
      selectedModel = "gpt-5.6-sol"
    } else if providerConfigured("tokenrouter", config: config) {
      selectedProvider = "tokenrouter"
      selectedModel = "moonshotai/kimi-k3-free"
    } else { return }
    UserDefaults.standard.set(selectedProvider, forKey: "PiSpaceProvider")
    UserDefaults.standard.set(selectedModel, forKey: "PiSpaceModel")
  }
  func modelPresentation(_ model: [String: Any]) -> [String: Any] {
    var value = model
    let provider = model["provider"] as? String ?? ""
    let id = model["id"] as? String ?? ""
    value["contextWindow"] = model["contextWindow"] as? Int ?? 128_000
    value["maxOutputTokens"] = model["maxOutputTokens"] as? Int ?? 16_384
    value["reasoning"] = provider != "tabitoken" || id.hasSuffix("-thinking")
    value["inputModes"] = ["Text", "Images"]
    return value
  }

  func syncProviderSettings(message: String? = nil, success: Bool = true) {
    let config = readModelsConfig()
    var payload: [String: Any] = [
      "models": managedModels.map(modelPresentation),
      "agentRouterConfigured": providerConfigured("agentrouter", config: config),
      "openRouterConfigured": providerConfigured("openrouter", config: config),
      "tokenRouterConfigured": providerConfigured("tokenrouter", config: config),
      "tabiTokenConfigured": providerConfigured("tabitoken", config: config),
      "tabiTokenBaseURL": ((config["providers"] as? [String: Any])?["tabitoken"] as? [String: Any])?["baseUrl"] as? String ?? defaultTabiTokenBaseURL,
      "selectedProvider": selectedProvider ?? "",
      "selectedModel": selectedModel ?? "",
      "wakePhrasesEnabled": voice.wakeEnabled,
      "voicePace": voice.voicePace,
      "voiceLength": voice.voiceLength,
      "voiceIdentifier": voice.selectedVoiceIdentifier,
      "voices": voice.availableVoices(),
      "kokoroInstalled": voice.kokoroInstalled,
      "kokoroVoice": voice.kokoroVoice,
      "kokoroVoices": [
        ["name": "Heart — warm", "id": "af_heart"], ["name": "Bella — soft", "id": "af_bella"],
        ["name": "Nova — confident", "id": "af_nova"], ["name": "Sarah — gentle", "id": "af_sarah"],
        ["name": "Sky — bright", "id": "af_sky"], ["name": "Adam — deep", "id": "am_adam"],
        ["name": "Echo — clear", "id": "am_echo"], ["name": "Eric — steady", "id": "am_eric"],
        ["name": "Michael — warm", "id": "am_michael"], ["name": "Lily — British, bright", "id": "bf_lily"],
        ["name": "Emma — British, warm", "id": "bf_emma"], ["name": "George — British, deep", "id": "bm_george"],
      ],
      "success": success,
    ]
    if let message { payload["message"] = message }
    js("providerSettingsLoaded", payload)
  }
  func managedProvider(existing: [String: Any]?, name: String, key: String?, baseURL: String? = nil) -> [String: Any] {
    var provider = existing ?? [:]
    if name == "agentrouter" {
      provider["baseUrl"] = "https://agentrouter.org/v1"
    } else if name == "tokenrouter" {
      provider["baseUrl"] = "https://api.tokenrouter.io/v1"
    } else if name == "openrouter" {
      provider["baseUrl"] = defaultOpenRouterBaseURL
    } else if let baseURL, !baseURL.isEmpty {
      provider["baseUrl"] = baseURL
    }
    if name == "tabitoken" {
      provider["api"] = "anthropic-messages"
      provider.removeValue(forKey: "authHeader")
      provider.removeValue(forKey: "compat")
    } else {
      provider["api"] = "openai-completions"
      provider["authHeader"] = true
    }
    if let key, !key.isEmpty { provider["apiKey"] = key }
    if name == "agentrouter" {
      provider["headers"] = [
        "Originator": "codex_cli_rs", "User-Agent": "codex_cli_rs/0.101.0 (Pi Space; macOS)",
        "Version": "0.101.0",
      ]
      provider["compat"] = ["supportsDeveloperRole": false, "supportsReasoningEffort": false]
    }
    provider["models"] = managedModels.filter { $0["provider"] as? String == name }.map {
      let id = $0["id"] as! String
      let contextWindow = $0["contextWindow"] as? Int ?? 128_000
      let maxTokens = $0["maxOutputTokens"] as? Int ?? 16_384
      return [
        "id": id, "name": $0["name"]!,
        "reasoning": name == "agentrouter" || name == "tokenrouter" || name == "openrouter" || id.hasSuffix("-thinking"),
        "input": ["text", "image"], "contextWindow": contextWindow, "maxTokens": maxTokens,
      ]
    }
    return provider
  }
  func writeModelsConfig(_ config: [String: Any], createBackup: Bool = true) throws {
    try FileManager.default.createDirectory(
      at: modelsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if createBackup, FileManager.default.fileExists(atPath: modelsURL.path) {
      let backup = modelsURL.appendingPathExtension("backup")
      try? FileManager.default.removeItem(at: backup)
      try FileManager.default.copyItem(at: modelsURL, to: backup)
    }
    let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: modelsURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: modelsURL.path)
  }
  func ensureManagedModels() {
    var config = readModelsConfig()
    var providers = config["providers"] as? [String: Any] ?? [:]
    providers["agentrouter"] = managedProvider(
      existing: providers["agentrouter"] as? [String: Any], name: "agentrouter", key: nil)
    providers["tokenrouter"] = managedProvider(
      existing: providers["tokenrouter"] as? [String: Any], name: "tokenrouter", key: nil)
    providers["openrouter"] = managedProvider(
      existing: providers["openrouter"] as? [String: Any], name: "openrouter", key: nil)
    if let existing = providers["tabitoken"] as? [String: Any],
      (existing["baseUrl"] as? String)?.isEmpty == false
    {
      providers["tabitoken"] = managedProvider(existing: existing, name: "tabitoken", key: nil)
    }
    config["providers"] = providers
    do {
      try writeModelsConfig(config)
    } catch {
      syncProviderSettings(message: "Could not update models.json: \(error.localizedDescription)", success: false)
    }
  }
  func saveProviderKeys(agentRouterKey: String?, tokenRouterKey: String?, tabiTokenKey: String?,
    openRouterKey: String?, tabiTokenBaseURL: String?)
  {
    let agentKey = agentRouterKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    let tokenKey = tokenRouterKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let agentKey, !agentKey.isEmpty, !agentKey.hasPrefix("sk-") {
      syncProviderSettings(message: "AgentRouter keys must begin with sk-.", success: false)
      return
    }
    if let tokenKey, !tokenKey.isEmpty,
      !tokenKey.hasPrefix("tr_"), !tokenKey.hasPrefix("sk-")
    {
      syncProviderSettings(message: "TokenRouter keys must begin with sk- or tr_.", success: false)
      return
    }
    let openKey = openRouterKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let openKey, !openKey.isEmpty, !openKey.hasPrefix("sk-or-") {
      syncProviderSettings(message: "OpenRouter keys must begin with sk-or-.", success: false)
      return
    }
    let tabiKey = tabiTokenKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    let enteredTabiURL = tabiTokenBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let existingTabi = (readModelsConfig()["providers"] as? [String: Any])?["tabitoken"] as? [String: Any]
    let effectiveTabiKey = (tabiKey?.isEmpty == false ? tabiKey : existingTabi?["apiKey"] as? String) ?? ""
    let savedTabiURL = existingTabi?["baseUrl"] as? String ?? ""
    let rawTabiURL = !enteredTabiURL.isEmpty ? enteredTabiURL : (!savedTabiURL.isEmpty ? savedTabiURL : defaultTabiTokenBaseURL)
    let effectiveTabiURL = rawTabiURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if !effectiveTabiKey.isEmpty || !effectiveTabiURL.isEmpty {
      guard !effectiveTabiKey.isEmpty else {
        syncProviderSettings(message: "Enter the TabiToken API key.", success: false)
        return
      }
      guard let url = URL(string: effectiveTabiURL), url.scheme?.lowercased() == "https",
        url.host?.isEmpty == false
      else {
        syncProviderSettings(message: "Enter the HTTPS Base URL shown in your TabiToken dashboard.", success: false)
        return
      }
    }
    var config = readModelsConfig()
    var providers = config["providers"] as? [String: Any] ?? [:]
    providers["agentrouter"] = managedProvider(
      existing: providers["agentrouter"] as? [String: Any], name: "agentrouter", key: agentKey)
    providers["tokenrouter"] = managedProvider(
      existing: providers["tokenrouter"] as? [String: Any], name: "tokenrouter", key: tokenKey)
    providers["openrouter"] = managedProvider(
      existing: providers["openrouter"] as? [String: Any], name: "openrouter", key: openKey)
    if !effectiveTabiKey.isEmpty {
      providers["tabitoken"] = managedProvider(
        existing: providers["tabitoken"] as? [String: Any], name: "tabitoken",
        key: tabiKey, baseURL: effectiveTabiURL)
    }
    config["providers"] = providers
    do {
      try writeModelsConfig(config)
      syncProviderSettings(message: "Provider configuration saved. TabiToken is ready.")
      rpc.start(cwd, continuing: true, provider: selectedProvider, model: selectedModel)
      if selectedProvider == "openrouter", selectedModel == "stealth/ox-alpha" {
        rpc.send(["type": "set_thinking_level", "level": "minimal"])
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.refresh() }
    } catch {
      syncProviderSettings(message: "Could not save models.json: \(error.localizedDescription)", success: false)
    }
  }
  func selectModel(provider: String, model: String) {
    guard managedModels.contains(where: {
      $0["provider"] as? String == provider && $0["id"] as? String == model
    }) else {
      syncProviderSettings(message: "That model is not managed by Pi Space.", success: false)
      return
    }
    let config = readModelsConfig()
    guard providerConfigured(provider, config: config) else {
      syncProviderSettings(
        message: "Save the \(providerLabel(provider)) API key and endpoint first.",
        success: false)
      return
    }
    pendingModel = (provider, model)
    rpc.send(["type": "set_model", "provider": provider, "modelId": model])
    syncProviderSettings(message: "Switching to \(model)...")
  }
  func chooseAttachments() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    var attachments = [[String: Any]]()
    for url in panel.urls.prefix(5) {
      var isDirectory: ObjCBool = false
      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      if isDirectory.boolValue {
        attachments.append([
          "name": url.lastPathComponent, "mimeType": "application/x-directory",
          "data": Data(url.path.utf8).base64EncodedString(),
        ])
        continue
      }
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
        (values.fileSize ?? 0) <= 8 * 1_024 * 1_024,
        let data = try? Data(contentsOf: url)
      else {
        js("appError", ["message": "\(url.lastPathComponent) is larger than 8 MB or unreadable."])
        continue
      }
      let mimeTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "txt": "text/plain", "md": "text/markdown",
        "json": "application/json", "js": "text/javascript", "ts": "text/typescript",
        "swift": "text/x-swift", "py": "text/x-python", "sh": "text/x-shellscript",
        "html": "text/html", "css": "text/css", "csv": "text/csv", "xml": "application/xml",
        "yml": "text/yaml", "yaml": "text/yaml",
      ]
      attachments.append([
        "name": url.lastPathComponent,
        "mimeType": mimeTypes[url.pathExtension.lowercased()] ?? "application/octet-stream",
        "data": data.base64EncodedString(),
      ])
    }
    js("attachmentsChosen", ["attachments": attachments])
  }
  func refresh() {
    ["get_state", "get_messages", "get_available_models", "get_available_thinking_levels", "get_session_stats"].forEach {
      rpc.send(["type": $0])
    }
    sessions()
  }
  func loadSession(_ url: URL) {
    guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
    else {
      js("appError", ["message": "The selected session could not be read."])
      return
    }
    var messages = [[String: String]]()
    for line in text.split(separator: "\n") {
      guard let lineData = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
        object["type"] as? String == "message",
        let message = object["message"] as? [String: Any],
        let role = message["role"] as? String,
        role == "user" || role == "assistant"
      else { continue }
      var parts = [String]()
      if let content = message["content"] as? String {
        parts.append(content)
      } else if let content = message["content"] as? [[String: Any]] {
        for item in content {
          if item["type"] as? String == "text", let value = item["text"] as? String {
            parts.append(value)
          }
        }
      }
      let body = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !body.isEmpty { messages.append(["role": role, "text": body]) }
    }
    js("sessionHistoryLoaded", ["messages": messages])
  }
  func sessionSummary(_ url: URL) -> (String, String) {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return ("New chat", "No messages yet")
    }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 262_144)) ?? Data()
    guard let text = String(data: data, encoding: .utf8) else {
      return ("New chat", "No messages yet")
    }
    for line in text.split(separator: "\n") {
      guard let lineData = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
        object["type"] as? String == "message",
        let message = object["message"] as? [String: Any],
        message["role"] as? String == "user"
      else { continue }
      var prompt = ""
      if let content = message["content"] as? String {
        prompt = content
      } else if let content = message["content"] as? [[String: Any]] {
        prompt = content.compactMap { $0["text"] as? String }.joined(separator: " ")
      }
      prompt = prompt.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !prompt.isEmpty else { continue }
      let words = prompt.split(separator: " ")
      var title = words.prefix(7).joined(separator: " ")
      if title.count > 58 { title = String(title.prefix(58)) }
      if words.count > 7 || prompt.count > title.count { title += "…" }
      let summary = prompt.count > 125 ? String(prompt.prefix(125)) + "…" : prompt
      return (title, summary)
    }
    return ("New chat", "No messages yet")
  }
  func sessions() {
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent/sessions")
    let xs =
      (FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []).filter {
        $0.pathExtension == "jsonl"
      }
    files = xs.sorted {
      ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast)
        > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast)
    }
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    let list = files.enumerated().map { i, u -> [String: Any] in
      let d =
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? Date()
      let summary = sessionSummary(u)
      return [
        "index": i, "name": summary.0, "summary": summary.1,
        "date": f.string(from: d),
      ]
    }
    js("sessionsLoaded", ["sessions": list])
  }
  func choose(applySelection: Bool = false) {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    if p.runModal() == .OK, let path = p.url?.path {
      if applySelection { apply(path) } else { js("workspaceChosen", ["path": path]) }
    }
  }
  func apply(_ raw: String) {
    let p = NSString(string: raw).expandingTildeInPath
    var d: ObjCBool = false
    guard FileManager.default.fileExists(atPath: p, isDirectory: &d), d.boolValue else {
      js("appError", ["message": "That workspace folder does not exist."])
      return
    }
    cwd = p
    js("workspaceRestarting", ["path": p])
    rpc.start(cwd, continuing: false, provider: selectedProvider, model: selectedModel)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.refresh() }
  }
  func forward(_ x: [String: Any]) {
    guard ready else {
      queue.append(x)
      return
    }
    js("rpcEvent", x)
    let eventType = x["type"] as? String
    if eventType == "agent_settled" || eventType == "compaction_end" {
      rpc.send(["type": "get_session_stats"])
    }
    if eventType == "message_update",
      let update = x["assistantMessageEvent"] as? [String: Any],
      update["type"] as? String == "text_delta",
      let delta = update["delta"] as? String
    {
      voice.receiveResponseChunk(delta)
    }
    if eventType == "agent_end",
      let message = (x["messages"] as? [[String: Any]])?.last(where: { $0["role"] as? String == "assistant" })
    {
      let text: String
      if let content = message["content"] as? String {
        text = content
      } else if let content = message["content"] as? [[String: Any]] {
        text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
      } else { text = "" }
      voice.finishResponseStreaming(fallback: text)
    }
    if x["type"] as? String == "response", x["command"] as? String == "set_model",
      x["success"] as? Bool == false
    {
      pendingModel = nil
      syncProviderSettings(message: x["error"] as? String ?? "Model switch failed.", success: false)
      return
    }
    guard x["type"] as? String == "response", x["success"] as? Bool != false,
      let command = x["command"] as? String
    else { return }
    if command == "switch_session" {
      let cancelled = (x["data"] as? [String: Any])?["cancelled"] as? Bool ?? false
      if !cancelled {
        rpc.send(["type": "get_messages"])
        rpc.send(["type": "get_state"])
        rpc.send(["type": "get_session_stats"])
      }
    } else if command == "new_session" {
      let cancelled = (x["data"] as? [String: Any])?["cancelled"] as? Bool ?? false
      if !cancelled {
        rpc.send(["type": "get_messages"])
        rpc.send(["type": "get_state"])
        rpc.send(["type": "get_session_stats"])
      }
    } else if command == "fork" {
      let cancelled = (x["data"] as? [String: Any])?["cancelled"] as? Bool ?? false
      if !cancelled {
        rpc.send(["type": "get_messages"])
        rpc.send(["type": "get_state"])
        rpc.send(["type": "get_session_stats"])
        js("conversationTreeClosed", [:])
      }
    } else if command == "compact" {
      rpc.send(["type": "get_messages"])
      rpc.send(["type": "get_session_stats"])
    } else if ["set_model", "set_thinking_level"].contains(command) {
      if command == "set_model", let pending = pendingModel {
        selectedProvider = pending.provider
        selectedModel = pending.model
        UserDefaults.standard.set(pending.provider, forKey: "PiSpaceProvider")
        UserDefaults.standard.set(pending.model, forKey: "PiSpaceModel")
        pendingModel = nil
        syncProviderSettings(message: "Active model: \(pending.model)")
      }
      rpc.send(["type": "get_state"])
      rpc.send(["type": "get_available_thinking_levels"])
      rpc.send(["type": "get_session_stats"])
    }
  }
  func voiceSettingsDidChangeExternally() {
    syncProviderSettings()
  }

  func js(_ f: String, _ x: [String: Any]) {
    guard ready, let data = try? JSONSerialization.data(withJSONObject: x),
      let payload = String(data: data, encoding: .utf8)
    else { return }
    let script = "window.PiSpaceBridge.receive(\(String(reflecting: f)), \(payload));"
    web.evaluateJavaScript(script)
  }
  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    voice.shutdown()
    rpc.stop()
  }
}
final class Delegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  func applicationDidFinishLaunching(_ n: Notification) {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "Pi Space"
    window.setFrameAutosaveName("PiSpaceMainWindow")
    window.minSize = NSSize(width: 900, height: 620)
    window.contentViewController = Controller()
    if !window.setFrameUsingName("PiSpaceMainWindow") {
      window.center()
    }
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return true
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    (window.contentViewController as? Controller)?.voiceSettingsDidChangeExternally()
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
