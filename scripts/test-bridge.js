#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../Resources/pi-space-bridge.js"), "utf8");

function load(host = {}) {
  const warnings = [];
  const window = { ...host };
  const context = vm.createContext({
    window,
    console: { warn: message => warnings.push(message) },
  });
  vm.runInContext(source, context, { filename: "pi-space-bridge.js" });
  return { bridge: window.PiSpaceBridge, warnings, window };
}

{
  const messages = [];
  const { bridge } = load({
    webkit: { messageHandlers: { piSpace: { postMessage: message => messages.push(message) } } },
  });
  assert.equal(bridge.platform, "macos");
  assert.equal(bridge.available, true);
  bridge.send("prompt", { text: "hello" });
  assert.equal(messages.length, 1);
  assert.equal(messages[0].action, "prompt");
  assert.equal(messages[0].bridgeVersion, 1);
  assert.equal(messages[0].text, "hello");
}

{
  const messages = [];
  let messageListener;
  const host = {
    chrome: { webview: {
      postMessage: message => messages.push(message),
      addEventListener: (name, listener) => { if (name === "message") messageListener = listener; },
    } },
  };
  const { bridge, window } = load(host);
  assert.equal(bridge.platform, "windows");
  bridge.send("abort");
  assert.equal(messages.length, 1);
  assert.equal(messages[0].action, "abort");
  assert.equal(messages[0].bridgeVersion, 1);
  let received;
  window.appError = payload => { received = payload; };
  messageListener({ data: { event: "appError", payload: { message: "test" } } });
  assert.equal(JSON.stringify(received), JSON.stringify({ message: "test" }));
}

{
  const messages = [];
  const { bridge } = load({
    piSpaceHost: { platform: "linux", postMessage: message => messages.push(message) },
  });
  assert.equal(bridge.platform, "linux");
  bridge.send("applyWorkspace", { path: "/tmp/project" });
  assert.equal(messages.length, 1);
  assert.equal(messages[0].action, "applyWorkspace");
  assert.equal(messages[0].bridgeVersion, 1);
  assert.equal(messages[0].path, "/tmp/project");
}

{
  const { bridge, warnings, window } = load();
  assert.equal(bridge.platform, "browser");
  assert.equal(bridge.available, false);
  assert.throws(() => bridge.send("refresh"), /native host is unavailable/);
  assert.throws(() => bridge.send("", {}), /non-empty strings/);
  assert.throws(() => bridge.send("refresh", []), /payloads must be objects/);

  let received;
  window.rpcEvent = payload => { received = payload; };
  assert.equal(bridge.receive("rpcEvent", { type: "agent_start" }), true);
  assert.equal(JSON.stringify(received), JSON.stringify({ type: "agent_start" }));
  assert.equal(bridge.receive("unknownEvent", {}), false);
  assert.match(warnings[0], /unknown native event/);
  assert.throws(() => bridge.receive("rpcEvent", null), /payloads must be objects/);
}

console.log("Bridge contract checks passed.");
