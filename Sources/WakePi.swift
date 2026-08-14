import AVFoundation
import AppKit
import Speech

final class WakeListener: NSObject, NSApplicationDelegate {
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var statusItem: NSStatusItem!
  private var paused = false
  private var restartWork: DispatchWorkItem?
  private var lastTrigger = Date.distantPast
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
    buildMenu()
    requestPermissions()
  }

  private func buildMenu() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "waveform.circle", accessibilityDescription: "Wake Pi Listener")
    statusItem.button?.toolTip = "Wake Pi Listener"
    updateMenu("Waiting for permission…")
  }

  private func updateMenu(_ state: String) {
    let menu = NSMenu()
    let status = NSMenuItem(title: state, action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)
    menu.addItem(.separator())
    let open = NSMenuItem(title: "Open Pi Space", action: #selector(openPi), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    let toggle = NSMenuItem(
      title: paused ? "Resume Listening" : "Pause Listening", action: #selector(toggleListening),
      keyEquivalent: "")
    toggle.target = self
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
    stopRecognition()
    let node = engine.inputNode
    let format = node.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      scheduleRestart(after: 3)
      return
    }
    let nextRequest = SFSpeechAudioBufferRecognitionRequest()
    nextRequest.shouldReportPartialResults = true
    nextRequest.taskHint = .confirmation
    nextRequest.contextualStrings = ["wake up Pi", "time for bed Pi", "Pi Space"]
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
    NSLog("Speech recognition started")
    updateMenu("Listening for “wake up Pi”")
    task = recognizer?.recognitionTask(with: nextRequest) { [weak self] result, error in
      guard let self else { return }
      if let result {
        self.inspect(result.bestTranscription.formattedString)
      }
      if let error {
        let nsError = error as NSError
        NSLog("Speech recognition ended: %@ (%ld)", nsError.domain, nsError.code)
        self.scheduleRestart(after: nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 ? 0.8 : 2.0)
      } else if result?.isFinal == true {
        NSLog("Speech recognition returned a final result")
        self.scheduleRestart(after: 0.8)
      }
    }
  }

  private func inspect(_ transcription: String) {
    let normalized = transcription.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
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
    guard mentionsPi && (normalized.contains("wake up") || normalized.contains("wakeupi")) else {
      return
    }
    lastTrigger = Date()
    NSLog("Recognized wake up Pi")
    openPi()
    scheduleRestart(after: 1.2)
  }

  private func closePi() {
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
    restartWork?.cancel()
    if paused {
      stopRecognition()
      updateMenu("Listening paused")
    } else {
      startListening()
    }
  }

  private func scheduleRestart(after delay: TimeInterval) {
    guard !paused else { return }
    restartWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.startListening() }
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

  func applicationWillTerminate(_ notification: Notification) { stopRecognition() }
}

let app = NSApplication.shared
let delegate = WakeListener()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
