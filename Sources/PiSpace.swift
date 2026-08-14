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
  var selectedProvider = UserDefaults.standard.string(forKey: "PiSpaceProvider")
  var selectedModel = UserDefaults.standard.string(forKey: "PiSpaceModel")
  var pendingModel: (provider: String, model: String)?
  let modelsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi/agent/models.json")
  let managedModels: [[String: Any]] = [
    ["choice": "gpt-5.6-sol", "variant": "GPT-5.6 Sol", "provider": "agentrouter", "providerLabel": "AgentRouter", "id": "gpt-5.6-sol", "name": "gpt-5.6-sol"],
    ["choice": "opus-5", "variant": "Claude Opus 5", "provider": "agentrouter", "providerLabel": "AgentRouter", "id": "claude-opus-5", "name": "claude-opus-5"],
    ["choice": "opus-5", "variant": "Claude Opus 5", "provider": "tabitoken", "providerLabel": "TabiToken", "id": "claude-opus-5", "name": "claude-opus-5"],
    ["choice": "opus-5-thinking", "variant": "Claude Opus 5 Thinking", "provider": "tabitoken", "providerLabel": "TabiToken", "id": "claude-opus-5-thinking", "name": "claude-opus-5-thinking"],
    ["choice": "opus-4.8", "variant": "Claude Opus 4.8", "provider": "agentrouter", "providerLabel": "AgentRouter", "id": "claude-opus-4.8", "name": "claude-opus-4.8"],
    ["choice": "opus-4.8", "variant": "Claude Opus 4.8", "provider": "tabitoken", "providerLabel": "TabiToken", "id": "claude-opus-4-8", "name": "claude-opus-4-8"],
    ["choice": "opus-4.8-thinking", "variant": "Claude Opus 4.8 Thinking", "provider": "tabitoken", "providerLabel": "TabiToken", "id": "claude-opus-4-8-thinking", "name": "claude-opus-4-8-thinking"],
    ["choice": "kimi-k3-free", "variant": "Kimi K3 Free", "provider": "tokenrouter", "providerLabel": "TokenRouter", "id": "moonshotai/kimi-k3-free", "name": "moonshotai/kimi-k3-free"],
  ]
  let defaultTabiTokenBaseURL = "https://api.tabitoken.com/v1"
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
    queue.forEach(forward)
    queue.removeAll()
    js("workspaceChosen", ["path": cwd])
    js("instructionsLoaded", ["text": instructions()])
    ensureManagedModels()
    chooseInitialModel()
    syncProviderSettings()
    rpc.start(cwd, continuing: false, provider: selectedProvider, model: selectedModel)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
  }
  func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
    guard let b = m.body as? [String: Any], let a = b["action"] as? String else { return }
    switch a {
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
        let message =
          custom.isEmpty
          ? userText
          : """
          <persistent_user_instructions>
          Follow these preferences throughout this response unless they conflict with safety, system, or developer requirements:
          \(custom)
          </persistent_user_instructions>

          <user_message>
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
    case "refresh": refresh()
    case "sessions": sessions()
    case "switchSession":
      if let i = b["index"] as? Int, files.indices.contains(i) {
        rpc.send(["type": "switch_session", "sessionPath": files[i].path])
      }
    case "chooseWorkspace": choose()
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
        tabiTokenBaseURL: b["tabiTokenBaseURL"] as? String)
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
    ["agentrouter": "AgentRouter", "tokenrouter": "TokenRouter", "tabitoken": "TabiToken"][name]
      ?? name
  }
  func chooseInitialModel() {
    guard selectedProvider == nil || selectedModel == nil else { return }
    let config = readModelsConfig()
    if providerConfigured("agentrouter", config: config) {
      selectedProvider = "agentrouter"
      selectedModel = "gpt-5.6-sol"
    } else if providerConfigured("tokenrouter", config: config) {
      selectedProvider = "tokenrouter"
      selectedModel = "moonshotai/kimi-k3-free"
    } else { return }
    UserDefaults.standard.set(selectedProvider, forKey: "PiSpaceProvider")
    UserDefaults.standard.set(selectedModel, forKey: "PiSpaceModel")
  }
  func syncProviderSettings(message: String? = nil, success: Bool = true) {
    let config = readModelsConfig()
    var payload: [String: Any] = [
      "models": managedModels,
      "agentRouterConfigured": providerConfigured("agentrouter", config: config),
      "tokenRouterConfigured": providerConfigured("tokenrouter", config: config),
      "tabiTokenConfigured": providerConfigured("tabitoken", config: config),
      "tabiTokenBaseURL": ((config["providers"] as? [String: Any])?["tabitoken"] as? [String: Any])?["baseUrl"] as? String ?? defaultTabiTokenBaseURL,
      "selectedProvider": selectedProvider ?? "",
      "selectedModel": selectedModel ?? "",
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
    } else if let baseURL, !baseURL.isEmpty {
      provider["baseUrl"] = baseURL
    }
    provider["api"] = "openai-completions"
    provider["authHeader"] = true
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
      let contextWindow = name == "agentrouter" ? 128_000 : 200_000
      let maxTokens = name == "agentrouter" ? 16_384 : 32_768
      return [
        "id": id, "name": $0["name"]!,
        "reasoning": name == "agentrouter" || name == "tokenrouter" || id.hasSuffix("-thinking"),
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
    tabiTokenBaseURL: String?)
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
    rpc.start(cwd, continuing: false, provider: selectedProvider, model: selectedModel)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.refresh() }
  }
  func forward(_ x: [String: Any]) {
    guard ready else {
      queue.append(x)
      return
    }
    js("rpcEvent", x)
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
      }
    } else if command == "new_session" {
      let cancelled = (x["data"] as? [String: Any])?["cancelled"] as? Bool ?? false
      if !cancelled {
        rpc.send(["type": "get_messages"])
        rpc.send(["type": "get_state"])
      }
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
