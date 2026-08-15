import AVFoundation
import AppKit
import Speech

final class WakeListener: NSObject, NSApplicationDelegate, NSSpeechSynthesizerDelegate {
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var statusItem: NSStatusItem!
  private let listeningPausedKey = "WakePiListeningPaused"
  private var paused = UserDefaults.standard.bool(forKey: "WakePiListeningPaused")
  private var restartWork: DispatchWorkItem?
  private var silenceWork: DispatchWorkItem?
  private var recognitionGeneration = 0
  private var restartScheduledGeneration: Int?
  private var speechFailureCount = 0
  private var lastTrigger = Date.distantPast
  private var voiceMode: VoiceMode = .wakeWord
  private var dictatedText = ""
  private var conversationText = ""
  private var lastResponse = ""
  private var voiceResponsePending = false
  private let speaker = NSSpeechSynthesizer()
  private enum VoiceMode { case wakeWord, dictation, conversationListening, conversationWaiting }
  private let voiceNotification = Notification.Name("com.olivergreen.pispace.voice")
  private let responseNotification = Notification.Name("com.olivergreen.pispace.voice.response")
  private let stateNotification = Notification.Name("com.olivergreen.pispace.voice.state")
  private let appCandidates = [
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Pi Space.app"),
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/Pi Space.app"),
    URL(fileURLWithPath: "/Applications/Pi Space.app"),
  ]

  private var appURL: URL? {
    appCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSLog("Wake Pi Listener launched")
    speaker.delegate = self
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(receiveVoiceResponse(_:)), name: responseNotification, object: nil)
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(receiveVoiceControl(_:)), name: voiceNotification, object: nil)
    buildMenu()
    if paused {
      NSLog("Wake Pi listening is disabled")
      updateMenu("Listening is off")
    } else {
      requestPermissions()
    }
  }

  private func buildMenu() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: paused ? "mic.slash.circle" : "waveform.circle",
      accessibilityDescription: paused ? "Wake Pi Listener off" : "Wake Pi Listener on")
    statusItem.button?.toolTip = paused ? "Wake Pi is not listening" : "Wake Pi is listening"
    updateMenu("Waiting for permission…")
  }

  private func updateMenu(_ state: String) {
    let conversationActive = voiceMode == .conversationListening || voiceMode == .conversationWaiting
    let icon = paused ? "mic.slash.circle" : (conversationActive ? "person.wave.2" : "waveform.circle")
    statusItem.button?.image = NSImage(
      systemSymbolName: icon,
      accessibilityDescription: paused ? "Wake Pi Listener off" : (conversationActive ? "Pi conversation active" : "Wake Pi Listener on"))
    statusItem.button?.toolTip = paused ? "Wake Pi is not listening" : (conversationActive ? "Voice conversation with Pi" : "Wake Pi is listening")
    let menu = NSMenu()
    let visibleState: String
    if paused { visibleState = "Microphone is off" }
    else if voiceMode == .dictation { visibleState = "Dictating… say send it or cancel" }
    else if voiceMode == .conversationListening { visibleState = "Conversation: listening…" }
    else if voiceMode == .conversationWaiting { visibleState = "Conversation: Pi is thinking…" }
    else { visibleState = state }
    let status = NSMenuItem(title: visibleState, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)
    menu.addItem(.separator())
    let open = NSMenuItem(title: "Open Pi Space", action: #selector(openPi), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    if voiceMode == .dictation {
      let cancel = NSMenuItem(
        title: "Cancel Dictation", action: #selector(cancelDictation), keyEquivalent: "")
      cancel.target = self
      menu.addItem(cancel)
    }
    let conversation = NSMenuItem(
      title: conversationActive ? "End Voice Conversation" : "Start Voice Conversation",
      action: conversationActive ? #selector(endConversation) : #selector(startConversation),
      keyEquivalent: "")
    conversation.target = self
    conversation.isEnabled = !paused
    menu.addItem(conversation)
    let toggle = NSMenuItem(
      title: "Listening Enabled", action: #selector(toggleListening), keyEquivalent: "")
    toggle.target = self
    toggle.state = paused ? .off : .on
    menu.addItem(toggle)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit Wake Listener", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    statusItem.menu = menu
  }

  private func requestPermissions() {
    SFSpeechRecognizer.requestAuthorization { [weak self] speech in
      guard let self else { return }
      AVCaptureDevice.requestAccess(for: .audio) { microphone in
        DispatchQueue.main.async {
          if speech == .authorized && microphone {
            NSLog("Speech and microphone permissions granted")
            self.startListening()
          } else {
            NSLog("Permissions unavailable: speech=%ld microphone=%@", speech.rawValue, microphone.description)
            self.updateMenu("Permissions required")
            self.showPermissionHelp()
          }
        }
      }
    }
  }

  private func showPermissionHelp() {
    let alert = NSAlert()
    alert.messageText = "Wake Pi needs permission"
    alert.informativeText =
      "Allow Microphone and Speech Recognition so ‘wake up Pi’ can open Pi Space. You can change these in System Settings → Privacy & Security."
    alert.addButton(withTitle: "Open Privacy Settings")
    alert.addButton(withTitle: "Not Now")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn,
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    {
      NSWorkspace.shared.open(url)
    }
  }

  private func startListening() {
    guard !paused else { return }
    restartWork?.cancel()
    recognitionGeneration += 1
    restartScheduledGeneration = nil
    let generation = recognitionGeneration
    stopRecognition()
    let node = engine.inputNode
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      scheduleRestart(after: 3)
      return
    }
    let nextRequest = SFSpeechAudioBufferRecognitionRequest()
    nextRequest.shouldReportPartialResults = true
    let acceptsFreeSpeech = voiceMode == .dictation || voiceMode == .conversationListening
    nextRequest.taskHint = acceptsFreeSpeech ? .dictation : .confirmation
    if voiceMode == .dictation {
      nextRequest.contextualStrings = ["send it", "cancel", "send", "cancel dictation"]
    } else if voiceMode == .conversationListening {
      nextRequest.contextualStrings = ["goodbye Pi", "end conversation", "stop conversation"]
    } else {
      nextRequest.contextualStrings = ["wake up Pi", "time for bed Pi", "stop Pi", "repeat that", "summarize this", "Pi Space"]
    }
    request = nextRequest
    node.removeTap(onBus: 0)
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      nextRequest.append(buffer)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      NSLog("Could not start microphone: %@", error.localizedDescription)
      updateMenu("Microphone unavailable")
      scheduleRestart(after: 4)
      return
    }
    NSLog("Speech recognition started in %@ mode", String(describing: voiceMode))
    if voiceMode == .conversationListening { publishVoiceState("listening", text: "") }
    updateMenu("Listening for “wake up Pi”")
    task = recognizer?.recognitionTask(with: nextRequest) { [weak self] result, error in
      guard let self, generation == self.recognitionGeneration else { return }
      if let result {
        let transcription = result.bestTranscription.formattedString
        if !transcription.isEmpty { self.speechFailureCount = 0 }
        if self.voiceMode == .conversationListening {
          self.inspectConversation(transcription, isFinal: result.isFinal)
        } else {
          self.inspect(transcription)
        }
      }
      if let error {
        let nsError = error as NSError
        self.speechFailureCount += 1
        let delay = min(60.0, max(2.0, pow(2.0, Double(min(self.speechFailureCount - 1, 5)) * 2.0)))
        NSLog("Speech recognition ended: %@ (%ld); retrying in %.1fs", nsError.domain, nsError.code, delay)
        self.scheduleRestart(after: delay, generation: generation)
      } else if result?.isFinal == true {
        self.speechFailureCount = 0
        NSLog("Speech recognition returned a final result")
        if self.voiceMode != .conversationWaiting {
          self.scheduleRestart(after: 0.8, generation: generation)
        }
      }
    }
  }

  private func inspect(_ transcription: String) {
    let normalized = transcription.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if voiceMode == .dictation {
      inspectDictation(normalized)
      return
    }
    let words = Set(normalized.split(separator: " ").map(String.init))
    let mentionsPi = words.contains("pi") || words.contains("pie") || normalized.contains("wakeupi")
    guard Date().timeIntervalSince(lastTrigger) > 3 else { return }
    if mentionsPi && normalized.contains("time for bed") {
      NSLog("Recognized time for bed Pi")
      lastTrigger = Date()
      closePi()
      scheduleRestart(after: 1.2)
      return
    }
    if mentionsPi && normalized.contains("stop pi") {
      lastTrigger = Date()
      sendVoiceAction("abort")
      speak("Stopped Pi.")
      return
    }
    if mentionsPi && (normalized.contains("repeat that") || normalized.contains("repeat")) {
      lastTrigger = Date()
      speak(lastResponse.isEmpty ? "There is no previous response to repeat." : lastResponse)
      return
    }
    if mentionsPi && (normalized.contains("summarize this") || normalized.contains("summarise this")) {
      lastTrigger = Date()
      voiceResponsePending = true
      sendVoiceAction("summarize")
      speak("I’m summarizing the current conversation.")
      return
    }
    guard mentionsPi && (normalized.contains("wake up") || normalized.contains("wakeupi")) else {
      return
    }
    lastTrigger = Date()
    NSLog("Recognized wake up Pi")
    openPi()
    beginDictation()
  }

  private func inspectDictation(_ normalized: String) {
    if normalized == "cancel" || normalized.contains("cancel dictation") {
      cancelDictation()
      return
    }
    if normalized == "send" || normalized == "send it" || normalized.contains("send it") {
      let beforeCommand = normalized.components(separatedBy: "send it").first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let text = (beforeCommand.isEmpty ? dictatedText : beforeCommand)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        speak("I didn’t hear a prompt.")
        beginDictation()
        return
      }
      sendVoicePrompt(text)
      return
    }
    dictatedText = normalized
    if !normalized.isEmpty { updateMenu("Dictating… say send it or cancel") }
  }

  private func inspectConversation(_ transcription: String, isFinal: Bool) {
    guard voiceMode == .conversationListening else { return }
    let text = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let normalized = text.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.contains("goodbye pi") || normalized.contains("good bye pi")
      || normalized.contains("end conversation") || normalized.contains("stop conversation")
    {
      endConversation()
      return
    }
    conversationText = text
    publishVoiceState("listening", text: text)
    updateMenu("Conversation: listening…")
    scheduleConversationSend(after: isFinal ? 0.35 : 1.5)
  }

  private func scheduleConversationSend(after delay: TimeInterval) {
    silenceWork?.cancel()
    let expectedText = conversationText
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.voiceMode == .conversationListening,
        self.conversationText == expectedText else { return }
      self.sendConversationPrompt(expectedText)
    }
    silenceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func sendConversationPrompt(_ text: String) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    silenceWork?.cancel()
    conversationText = ""
    voiceMode = .conversationWaiting
    voiceResponsePending = true
    recognitionGeneration += 1
    stopRecognition()
    publishVoiceState("thinking", text: "")
    updateMenu("Conversation: Pi is thinking…")
    sendVoiceAction("prompt", text: clean, conversation: true)
  }

  @objc private func startConversation() {
    guard !paused else { return }
    silenceWork?.cancel()
    dictatedText = ""
    conversationText = ""
    voiceResponsePending = false
    voiceMode = .conversationListening
    openPi()
    publishVoiceState("listening", text: "")
    speak("Voice conversation started. What would you like to talk about?")
  }

  @objc private func endConversation() {
    let wasActive = voiceMode == .conversationListening || voiceMode == .conversationWaiting
    guard wasActive else { return }
    silenceWork?.cancel()
    conversationText = ""
    voiceResponsePending = false
    voiceMode = .wakeWord
    recognitionGeneration += 1
    stopRecognition()
    publishVoiceState("idle", text: "")
    updateMenu("Listening for “wake up Pi”")
    scheduleRestart(after: 0.25)
  }

  private func beginDictation() {
    voiceMode = .dictation
    dictatedText = ""
    speak("I’m listening.")
  }

  @objc private func cancelDictation() {
    dictatedText = ""
    voiceMode = .wakeWord
    speak("Cancelled.")
  }

  private func sendVoicePrompt(_ text: String) {
    voiceMode = .wakeWord
    dictatedText = ""
    voiceResponsePending = true
    sendVoiceAction("prompt", text: text)
    speak("Sending.")
  }

  private func sendVoiceAction(_ action: String, text: String? = nil, conversation: Bool = false) {
    var info: [String: String] = ["action": action]
    if let text { info["text"] = text }
    if conversation { info["conversation"] = "true" }
    DistributedNotificationCenter.default().postNotificationName(
      voiceNotification, object: nil, userInfo: info, deliverImmediately: true)
  }

  private func publishVoiceState(_ state: String, text: String) {
    DistributedNotificationCenter.default().postNotificationName(
      stateNotification, object: nil, userInfo: ["state": state, "text": text], deliverImmediately: true)
  }

  @objc private func receiveVoiceControl(_ notification: Notification) {
    guard let info = notification.userInfo as? [String: String], let action = info["action"] else { return }
    if paused {
      publishVoiceState("disabled", text: "Enable Listening Enabled in the Wake Pi menu first.")
      return
    }
    if action == "start_conversation" {
      startConversation()
    } else if action == "end_conversation" {
      endConversation()
    }
  }

  @objc private func receiveVoiceResponse(_ notification: Notification) {
    guard let info = notification.userInfo as? [String: String], let text = info["text"], !text.isEmpty else { return }
    lastResponse = text
    if voiceResponsePending {
      voiceResponsePending = false
      speak(text)
    }
  }

  private func speak(_ text: String) {
    let cleaned = text.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
    guard !cleaned.isEmpty else { return }
    recognitionGeneration += 1
    restartWork?.cancel()
    stopRecognition()
    speaker.stopSpeaking()
    publishVoiceState("speaking", text: cleaned)
    speaker.startSpeaking(cleaned)
  }

  func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
    guard !paused else { return }
    if voiceMode == .conversationWaiting {
      voiceMode = .conversationListening
      conversationText = ""
      publishVoiceState("listening", text: "")
    } else if voiceMode == .conversationListening {
      publishVoiceState("listening", text: "")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, !self.engine.isRunning else { return }
      self.startListening()
    }
  }

  private func closePi() {
    sendVoiceAction("bed")
    let running = NSWorkspace.shared.runningApplications.filter {
      $0.localizedName == "Pi Space"
        || ($0.bundleIdentifier?.hasPrefix("com.pispace.app") == true)
        || ($0.bundleIdentifier?.hasPrefix("com.olivergreen.pispace") == true)
    }
    guard !running.isEmpty else {
      updateMenu("Pi Space is already asleep")
      return
    }
    for application in running { application.terminate() }
    updateMenu("Pi Space is asleep")
  }

  @objc private func openPi() {
    guard let appURL else {
      updateMenu("Pi Space not found in Applications")
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    configuration.createsNewApplicationInstance = false
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) {
      [weak self] application, error in
      DispatchQueue.main.async {
        application?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        self?.updateMenu(error == nil ? "Listening for “wake up Pi”" : "Could not open Pi Space")
      }
    }
  }

  @objc private func toggleListening() {
    paused.toggle()
    UserDefaults.standard.set(paused, forKey: listeningPausedKey)
    restartWork?.cancel()
    if paused {
      silenceWork?.cancel()
      voiceMode = .wakeWord
      dictatedText = ""
      conversationText = ""
      voiceResponsePending = false
      speaker.stopSpeaking()
      stopRecognition()
      NSLog("Wake Pi listening disabled")
      updateMenu("Listening is off")
    } else {
      NSLog("Wake Pi listening enabled")
      updateMenu("Starting listener…")
      requestPermissions()
    }
  }

  private func scheduleRestart(after delay: TimeInterval, generation: Int? = nil) {
    guard !paused, generation == nil || generation == recognitionGeneration else { return }
    let expectedGeneration = generation ?? recognitionGeneration
    guard restartScheduledGeneration != expectedGeneration else { return }
    restartScheduledGeneration = expectedGeneration
    restartWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, expectedGeneration == self.recognitionGeneration, !self.paused else { return }
      self.startListening()
    }
    restartWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func stopRecognition() {
    if engine.isRunning { engine.stop() }
    engine.inputNode.removeTap(onBus: 0)
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
  }

  @objc private func quit() {
    stopRecognition()
    NSApp.terminate(nil)
  }

  func applicationWillTerminate(_ notification: Notification) {
    silenceWork?.cancel()
    stopRecognition()
  }
}

let app = NSApplication.shared
let delegate = WakeListener()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
