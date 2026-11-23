import Foundation
import OttoBrowser
import OttoCore
import OttoTools

public struct BrowserSequenceInput: Codable, Sendable {
  public enum Action: String, Codable, Sendable { case click, type, wait, list, downloadPDF }
  public struct Step: Codable, Sendable {
    public var action: Action
    public var target: String
    public var text: String?
  }
  public var nodeID: UUID
  public var steps: [Step]
}

public struct BrowserSequenceResult: Codable, Sendable {
  public var completedSteps: Int = 0
  public var files: [String] = []
  public var matchedControls: [String] = []
  public var stoppedReason: String?
  public var availableControls: [String] = []
}

public struct BrowserSequenceTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "browser.sequence",
    description: """
      Run 1–12 ordered steps on the current tab and site. Use exact accessible names for click,
      type, wait and downloadPDF. Use list to return up to 12 control names containing target.
      End with an observed result or a verified PDF download (direct same-origin link, 8 MiB max).
      On a stop, inspect and resume from completedSteps. Use browser.click for consequential clicks.
      """,
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(),
        "steps": .arraySchema(
          of: .objectSchema(
            properties: [
              "action": .object([
                "type": .string("string"),
                "enum": .array([
                  .string("click"), .string("type"), .string("wait"), .string("list"),
                  .string("downloadPDF"),
                ]),
              ]),
              "target": .stringSchema(
                description: "Exact accessible name, or a name fragment for list"),
              "text": .stringSchema(description: "Replacement text, for type only"),
            ], required: ["action", "target"])),
      ], required: ["nodeID", "steps"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead, .canvasWrite], riskLevel: .consequential)

  let store: CanvasStore
  let runtime: BrowserRuntime
  let workspacePath: String
  private let activeRuns = ActiveRuns()

  public init(store: CanvasStore, runtime: BrowserRuntime, workspacePath: String) {
    self.store = store
    self.runtime = runtime
    self.workspacePath = workspacePath
  }

  private actor ActiveRuns {
    private var nodes: Set<UUID> = []

    func run(on node: UUID, operation: @Sendable () async throws -> BrowserSequenceResult)
      async throws -> BrowserSequenceResult
    {
      guard nodes.insert(node).inserted else {
        throw ToolRegistryError.invalidInput("A browser sequence is already running on this node")
      }
      defer { nodes.remove(node) }
      return try await operation()
    }
  }

  public func call(_ input: BrowserSequenceInput, context: ToolContext) async throws
    -> BrowserSequenceResult
  {
    guard (1...12).contains(input.steps.count),
      input.steps.allSatisfy({
        !$0.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && ($0.action == .type) == ($0.text != nil)
      })
    else {
      throw ToolRegistryError.invalidInput("Expected 1–12 named steps, with text only for type")
    }
    return try await activeRuns.run(on: input.nodeID) {
      try await execute(input, context: context)
    }
  }

  private func execute(_ input: BrowserSequenceInput, context: ToolContext) async throws
    -> BrowserSequenceResult
  {
    let id = input.nodeID
    try await ensureInteractiveWebSession(
      nodeID: id, store: store, runtime: runtime, context: context)
    guard let start = await runtime.state(nodeID: id), let origin = Self.site(of: start.url) else {
      throw ToolRegistryError.invalidInput("Inspect the active tab before starting a sequence")
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var result = BrowserSequenceResult()
    for step in input.steps {
      let stepDeadline = min(deadline, .now.advanced(by: .seconds(8)))
      do {
        while true {
          try Task.checkCancellation()
          guard .now < stepDeadline else {
            throw ToolRegistryError.invalidInput("Timed out waiting for \(step.target)")
          }
          let page = try await runtime.inspectPage(nodeID: id)
          guard Self.site(of: page.url) == origin,
            await runtime.state(nodeID: id)?.activeTabID == start.activeTabID
          else {
            throw ToolRegistryError.invalidInput(
              "The active tab or site changed. Inspect before continuing.")
          }
          result.availableControls = page.elements.prefix(12).map(\.name)
          if step.action == .list {
            let names = page.elements.lazy.map(\.name).filter {
              $0.localizedCaseInsensitiveContains(step.target)
            }
            if !names.isEmpty {
              result.matchedControls.append(contentsOf: names.prefix(12))
              break
            }
            try await Task.sleep(for: .milliseconds(150))
            continue
          }
          let matches = page.elements.filter {
            $0.name.caseInsensitiveCompare(step.target) == .orderedSame
          }
          guard matches.count < 2 else {
            throw BrowserRuntimeError.pageElementAmbiguous(step.target)
          }
          if let element = matches.first, step.action == .wait || !element.isDisabled {
            do {
              if let file = try await perform(step, on: element, page: page, context: context) {
                result.files.append(file)
              }
              break
            } catch BrowserRuntimeError.stalePageSnapshot {
              // The renderer rejected this revision before dispatching the action.
            } catch BrowserRuntimeError.pageElementNotFound {
              // A rerender detached the target before dispatch.
            }
          }
          try await Task.sleep(for: .milliseconds(150))
        }
        result.completedSteps += 1
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result.stoppedReason = error.localizedDescription
        return result
      }
    }
    result.availableControls = []
    return result
  }

  private static func site(of address: String) -> URL? {
    guard var components = URLComponents(string: address) else { return nil }
    components.fragment = nil
    if components.host != nil {
      components.path = ""
      components.query = nil
    }
    return components.url
  }

  private func perform(
    _ step: BrowserSequenceInput.Step, on element: BrowserPageElement,
    page: BrowserPageSnapshot, context: ToolContext
  ) async throws -> String? {
    if step.action == .wait { return nil }
    if step.action == .downloadPDF {
      guard element.role == "link" else {
        throw ToolRegistryError.invalidInput("Expected a PDF link")
      }
      let data = try await runtime.readPDF(
        nodeID: page.nodeID,
        element: BrowserResolvedElement(
          elementID: element.id, pageRevision: page.pageRevision))
      let root = URL(fileURLWithPath: workspacePath, isDirectory: true).resolvingSymlinksInPath()
      let directory = root.appendingPathComponent("Downloads", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL
      else {
        throw ToolRegistryError.invalidInput("Downloads must be inside this workspace")
      }
      let name = element.name.components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }.joined(separator: "-").prefix(48)
      let file = directory.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
      try data.write(to: file, options: .atomic)
      return file.path
    }
    let request = BrowserInteractionRequest(
      revision: page.pageRevision,
      kind: step.action == .click ? .click : .type, elementID: element.id, text: step.text)
    if step.action == .click {
      // A sequence can already have committed earlier steps. Never ask the bridge to replay it.
      var singleClickContext = context
      singleClickContext.confirmed = false
      do {
        try await requireBrowserClickConfirmation(
          nodeID: page.nodeID, request: request,
          toolName: "browser.click", runtime: runtime, context: singleClickContext)
      } catch ToolRegistryError.confirmationRequired {
        throw ToolRegistryError.invalidInput(
          "Use browser.click for this step, then resume with the remaining steps.")
      }
    } else if !element.actions.contains(.type) || element.isSensitive {
      throw ToolRegistryError.invalidInput("Expected an editable, non-password field")
    }
    _ = try await runtime.interact(nodeID: page.nodeID, request: request)
    return nil
  }
}
