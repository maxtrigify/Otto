import Foundation
import OttoBrowser
import OttoCore
import OttoModels
import OttoServices

/// Makes Otto Desktop the renderer for the engine's browsers, as the Mac app's WebKit views are.
///
/// BrowserRuntime keeps each browser's state and asks a registered renderer to read and act on
/// pages. Here every renderer call becomes a host call to the desktop, which runs the same page
/// scripts (BrowserPageScripts) in a Chromium view, so bots browse identically on every OS.
@MainActor
final class DesktopBrowserBridge {
  struct StatePayload: Encodable, Sendable {
    var nodeID: UUID
    var name: String
    var state: BrowserRuntimeState
  }

  struct NodePayload: Encodable, Sendable { var nodeID: UUID }

  struct EvalParams: Encodable, Sendable {
    var nodeID: UUID
    var script: String
  }

  struct ClickParams: Encodable, Sendable {
    var nodeID: UUID
    var x: Double
    var y: Double
  }

  struct CaptureReply: Decodable {
    var png: String
    var width: Int
    var height: Int
  }

  private let store: CanvasStore
  private let runtime: BrowserRuntime
  private let host: DesktopHost
  private var watchers: [UUID: Task<Void, Never>] = [:]
  private let ownerID = UUID()

  init(store: CanvasStore, runtime: BrowserRuntime, host: DesktopHost) {
    self.store = store
    self.runtime = runtime
    self.host = host
  }

  func start() async {
    await runtime.setRendererPreparation { [weak self] state in
      guard let self else { return }
      await self.reconcile()
      // The desktop creates the tab's view if needed and waits for its first load.
      _ = try await self.host.call(
        "browser.prepare", StatePayload(nodeID: state.nodeID, name: self.name(state.nodeID), state: state),
        as: Bool.self, timeout: .seconds(20))
    }
    Task { [weak self] in
      while !Task.isCancelled {
        await self?.reconcile()
        try? await Task.sleep(for: .milliseconds(400))
      }
    }
  }

  /// Browsers live as nodes in the workspace; follow them as bots and the person open and close
  /// them, forwarding each state change (navigate, back, new tab) to the desktop.
  func reconcile() async {
    let nodes = store.snapshot.canvases.flatMap(\.nodes).filter { $0.kind == .browser }
    let ids = Set(nodes.map(\.id))
    for node in nodes where watchers[node.id] == nil {
      if await runtime.state(nodeID: node.id) == nil {
        let session: BrowserSession
        if let existing = node.browserSession {
          session = existing
        } else if case .browser(let url) = node.content {
          session = BrowserSession(url: url)
        } else {
          session = BrowserSession(url: BrowserDefaults.blankURL)
        }
        _ = await runtime.synchronize(nodeID: node.id, session: session)
      }
      await registerHandlers(node.id)
      let nodeID = node.id
      watchers[nodeID] = Task { [weak self] in
        guard let self else { return }
        for await state in await self.runtime.updates(nodeID: nodeID) {
          await self.host.emit(
            "browser.state", StatePayload(nodeID: nodeID, name: self.name(nodeID), state: state))
        }
      }
    }
    for (nodeID, watcher) in watchers where !ids.contains(nodeID) {
      watcher.cancel()
      watchers[nodeID] = nil
      await runtime.unregisterCaptureHandler(nodeID: nodeID, ownerID: ownerID)
      await runtime.unregisterPageHandler(nodeID: nodeID, ownerID: ownerID)
      await host.emit("browser.closed", NodePayload(nodeID: nodeID))
    }
  }

  private func name(_ nodeID: UUID) -> String {
    store.snapshot.canvases.flatMap(\.nodes).first { $0.id == nodeID }?.displayName ?? "Browser"
  }

  private func registerHandlers(_ nodeID: UUID) async {
    let host = self.host
    await runtime.registerCaptureHandler(nodeID: nodeID, ownerID: ownerID) {
      let reply = try await host.call(
        "browser.capture", NodePayload(nodeID: nodeID), as: CaptureReply.self)
      guard let png = Data(base64Encoded: reply.png) else {
        throw BrowserRuntimeError.captureUnavailable(nodeID)
      }
      return BrowserCapture(pngData: png, pixelWidth: reply.width, pixelHeight: reply.height)
    }
    await runtime.registerPageHandler(
      nodeID: nodeID,
      ownerID: ownerID,
      snapshot: { nodeID in
        let json = try await Self.evaluate(BrowserPageScripts.inspection, nodeID: nodeID, host: host)
        let page = try JSONDecoder().decode(BrowserDOMSnapshot.self, from: Data(json.utf8))
        return BrowserPageSnapshot(
          nodeID: nodeID, url: page.url, title: page.title, pageRevision: page.revision,
          elements: page.elements)
      },
      interact: { nodeID, request in
        try await Self.interact(nodeID: nodeID, request: request, host: host)
      },
      assess: { nodeID, request in
        let json = try await Self.evaluate(
          BrowserPageScripts.assessment(try Self.encode(request)), nodeID: nodeID, host: host)
        return try JSONDecoder().decode(BrowserInteractionAssessment.self, from: Data(json.utf8))
      }
    )
  }

  private static func interact(
    nodeID: UUID, request: BrowserInteractionRequest, host: DesktopHost
  ) async throws -> BrowserInteractionResult {
    let requestJSON = try encode(request)
    if request.kind == .click {
      // Like the Mac: bring the target on screen, then press there with a real (trusted) mouse
      // click when nothing covers it, which some sites require. Otherwise replay events.
      let located = try await evaluate(
        BrowserPageScripts.locate(requestJSON), nodeID: nodeID, host: host)
      let target = try JSONDecoder().decode(BrowserDOMLocateResult.self, from: Data(located.utf8))
      try target.throwIfFailed(nodeID: nodeID, elementID: request.elementID)
      if target.hit == true, let x = target.x, let y = target.y {
        let clicked = try await host.call(
          "browser.click", ClickParams(nodeID: nodeID, x: x, y: y), as: Bool.self)
        if clicked {
          return BrowserInteractionResult(
            nodeID: nodeID, pageRevision: request.revision, url: target.url,
            message: "Clicked element")
        }
      }
    }
    let json = try await evaluate(
      BrowserPageScripts.interaction(requestJSON), nodeID: nodeID, host: host)
    let decoded = try JSONDecoder().decode(BrowserDOMInteractionResult.self, from: Data(json.utf8))
    guard decoded.ok else {
      switch decoded.error {
      case "stale": throw BrowserRuntimeError.stalePageSnapshot
      case "missing": throw BrowserRuntimeError.pageElementNotFound(request.elementID ?? "unknown")
      default: throw BrowserRuntimeError.pageInteractionUnavailable(nodeID)
      }
    }
    return BrowserInteractionResult(
      nodeID: nodeID, pageRevision: request.revision, url: decoded.url,
      message: decoded.message ?? "Browser interaction completed")
  }

  private static func evaluate(_ script: String, nodeID: UUID, host: DesktopHost) async throws
    -> String
  {
    try await host.call("browser.eval", EvalParams(nodeID: nodeID, script: script), as: String.self)
  }

  private static func encode(_ request: BrowserInteractionRequest) throws -> String {
    String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
  }
}
