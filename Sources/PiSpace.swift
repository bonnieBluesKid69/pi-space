import AppKit
import Darwin
import Foundation
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

  func start(_ cwd: String, continuing: Bool = false) {
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

final class Controller: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
  let rpc = RPC()
  var web: WKWebView!
  var ready = false
  var queue = [[String: Any]]()
  var files = [URL]()
  var cwd = NSHomeDirectory()
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
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
    ready = true
    queue.forEach(forward)
    queue.removeAll()
    js("workspaceChosen", ["path": cwd])
    js("instructionsLoaded", ["text": instructions()])
    rpc.start(cwd, continuing: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
  }
  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    guard let b = m.body as? [String: Any], let a = b["action"] as? String else { return }
    switch a {
    case "prompt":
      if let t = b["text"] as? String {
        let custom = instructions()
        let message =
          custom.isEmpty
          ? t
          : """
          <persistent_user_instructions>
          Follow these preferences throughout this response unless they conflict with safety, system, or developer requirements:
          \(custom)
          </persistent_user_instructions>

          <user_message>
          \(t)
          </user_message>
          """
        rpc.send(["type": "prompt", "message": message, "streamingBehavior": "steer"])
      }
    case "abort": rpc.send(["type": "abort"])
    case "newSession": rpc.send(["type": "new_session"])
    case "refresh": refresh()
    case "sessions": sessions()
    case "switchSession":
      if let i = b["index"] as? Int, files.indices.contains(i) {
        rpc.send(["type": "switch_session", "sessionPath": files[i].path])
      }
    case "chooseWorkspace": choose()
    case "applyWorkspace": if let p = b["path"] as? String { apply(p) }
    case "setModel":
      if let p = b["provider"] as? String, let id = b["model"] as? String {
        rpc.send(["type": "set_model", "provider": p, "modelId": id])
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
  func refresh() {
    ["get_state", "get_messages", "get_available_models", "get_available_thinking_levels"].forEach {
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
  func choose() {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    if p.runModal() == .OK, let x = p.url?.path { js("workspaceChosen", ["path": x]) }
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
    rpc.start(p, continuing: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.refresh() }
  }
  func forward(_ x: [String: Any]) {
    guard ready else {
      queue.append(x)
      return
    }
    js("rpcEvent", x)
    guard x["type"] as? String == "response", x["success"] as? Bool != false,
      let command = x["command"] as? String
    else { return }
    if command == "switch_session" {
      let cancelled = (x["data"] as? [String: Any])?["cancelled"] as? Bool ?? false
      if !cancelled {
        rpc.send(["type": "get_messages"])
        rpc.send(["type": "get_state"])
      }
    } else if command == "new_session" {
      let cancelled = (x["data"] as? [String: Any])?["cancelled"] as? Bool ?? false
      if !cancelled {
        rpc.send(["type": "get_messages"])
        rpc.send(["type": "get_state"])
      }
    } else if ["set_model", "set_thinking_level"].contains(command) {
      rpc.send(["type": "get_state"])
      rpc.send(["type": "get_available_thinking_levels"])
    }
  }
  func js(_ f: String, _ x: [String: Any]) {
    guard ready, let data = try? JSONSerialization.data(withJSONObject: x),
      let payload = String(data: data, encoding: .utf8)
    else { return }
    let script = "window[\(String(reflecting: f))](\(payload));"
    web.evaluateJavaScript(script)
  }
  deinit { rpc.stop() }
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
  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}
signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
