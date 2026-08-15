(function (global) {
  "use strict";

  const protocolVersion = 1;

  function transport() {
    const macOS = global.webkit?.messageHandlers?.piSpace;
    if (macOS?.postMessage) {
      return { platform: "macos", postMessage: message => macOS.postMessage(message) };
    }

    const windows = global.chrome?.webview;
    if (windows?.postMessage) {
      return { platform: "windows", postMessage: message => windows.postMessage(message) };
    }

    const nativeHost = global.piSpaceHost;
    if (nativeHost?.postMessage) {
      return { platform: nativeHost.platform || "linux", postMessage: message => nativeHost.postMessage(message) };
    }

    return null;
  }

  function send(action, payload = {}) {
    if (typeof action !== "string" || !action) {
      throw new TypeError("Pi Space bridge actions must be non-empty strings.");
    }
    if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
      throw new TypeError("Pi Space bridge payloads must be objects.");
    }

    const activeTransport = transport();
    if (!activeTransport) {
      throw new Error("Pi Space native host is unavailable.");
    }

    activeTransport.postMessage({ ...payload, action, bridgeVersion: protocolVersion });
  }

  function receive(event, payload = {}) {
    if (typeof event !== "string" || !event) {
      throw new TypeError("Pi Space bridge events must be non-empty strings.");
    }
    if (payload === null || typeof payload !== "object" || Array.isArray(payload)) {
      throw new TypeError("Pi Space bridge event payloads must be objects.");
    }

    const handler = global[event];
    if (typeof handler !== "function") {
      console.warn(`Pi Space ignored unknown native event: ${event}`);
      return false;
    }
    handler(payload);
    return true;
  }

  function receiveMessage(message) {
    if (!message || typeof message !== "object" || Array.isArray(message)) return false;
    return receive(message.event, message.payload || {});
  }

  if (global.chrome?.webview?.addEventListener) {
    global.chrome.webview.addEventListener("message", event => receiveMessage(event.data));
  }

  global.PiSpaceBridge = Object.freeze({
    protocolVersion,
    get platform() { return transport()?.platform || "browser"; },
    get available() { return transport() !== null; },
    send,
    receive,
    receiveMessage,
  });
})(window);
