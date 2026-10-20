import Foundation
import OttoCore
import OttoDocuments
import OttoModels
import OttoTools

public struct WidgetCreateInput: Codable, Sendable {
  public var name: String
  public var html: String?
  public var network: [String]?
  public var intervalSeconds: Int?
  public var x: Double
  public var y: Double
  public var view: String?
  public var unit: String?
  public var historyLimit: Int?
  public var script: String?
  public var cron: String?
  public var timeoutSeconds: Int?
  public var data: String?
  public var background: String?
  public var accent: String?
  public var textColor: String?

  public init(
    name: String,
    html: String? = nil,
    network: [String]? = nil,
    intervalSeconds: Int? = nil,
    x: Double,
    y: Double,
    view: String? = nil,
    unit: String? = nil,
    historyLimit: Int? = nil,
    script: String? = nil,
    cron: String? = nil,
    timeoutSeconds: Int? = nil,
    data: String? = nil,
    background: String? = nil,
    accent: String? = nil,
    textColor: String? = nil
  ) {
    self.name = name
    self.html = html
    self.network = network
    self.intervalSeconds = intervalSeconds
    self.x = x
    self.y = y
    self.view = view
    self.unit = unit
    self.historyLimit = historyLimit
    self.script = script
    self.cron = cron
    self.timeoutSeconds = timeoutSeconds
    self.data = data
    self.background = background
    self.accent = accent
    self.textColor = textColor
  }
}

public struct WidgetPackageOutput: Codable, Sendable, Equatable {
  public var node: OttoNode
  public var packagePath: String
  public var manifest: WidgetManifest
  public var html: String?
}

public struct WidgetCreateTool: OttoTool {
  public static let scriptRelativePath = "scripts/refresh.sh"

  public static let definition = ToolDefinition(
    name: "widget.create",
    description: """
      Creates a user-owned widget package and opens it as a canvas node. Preferred form: pass \
      'view' (number, line, bar, pie, or table) and Otto renders the data natively; supply \
      'script' (a zsh script printing payload JSON on stdout) plus 'cron' or 'intervalSeconds' \
      to populate it on a background schedule, or 'data' to seed it directly. Payload \
      contracts — number: {"value": 128, "label"?, "unit"?}; line/bar/pie: {"points": \
      [{"label": "Mon", "value": 12}]}; table: {"columns": ["A"], "rows": [["1"]]}. \
      Alternatively pass 'html' for a sandboxed custom HTML widget. Optional 'background', \
      'accent', and 'textColor' hex colors (e.g. "#000000") give the widget its own look, \
      independent of the app theme. Custom HTML may also include a script and schedule; its \
      JSON output is exposed as window.otto.data and via the otto:data browser event.
      """,
    inputSchema: .objectSchema(
      properties: [
        "name": .stringSchema(description: "Human-readable widget name"),
        "html": .stringSchema(
          description:
            "Complete HTML source for a custom HTML widget. Mutually exclusive with view"),
        "network": .arraySchema(of: .stringSchema(description: "Allowed HTTP(S) origin")),
        "intervalSeconds": .integerSchema(
          description: "Schedule interval in seconds; background minimum is 60"),
        "x": .numberSchema(description: "Canvas X position"),
        "y": .numberSchema(description: "Canvas Y position"),
        "view": .stringSchema(
          description: "Native view kind: number, line, bar, pie, or table"),
        "unit": .stringSchema(description: "Unit caption for number views, e.g. followers"),
        "historyLimit": .integerSchema(
          description: "Samples kept for the number view's delta and sparkline (2–1000)"),
        "script": .stringSchema(
          description:
            "zsh data script source; runs in the package directory and must print payload JSON on stdout"
        ),
        "cron": .stringSchema(
          description:
            "Five-field cron schedule, e.g. '0 */6 * * *'. Takes precedence over intervalSeconds"),
        "timeoutSeconds": .integerSchema(description: "Script budget per run (5–600, default 60)"),
        "data": .stringSchema(description: "Initial payload JSON matching the view contract"),
        "background": .stringSchema(
          description: "Custom background color as #RRGGBB hex, overriding the app theme"),
        "accent": .stringSchema(
          description: "Custom accent/chart color as #RRGGBB hex, overriding the app theme"),
        "textColor": .stringSchema(
          description: "Custom text color as #RRGGBB hex, overriding the app theme"),
      ],
      required: ["name", "x", "y"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  private let runner: WidgetJobRunner

  public init(store: CanvasStore, documents: WorkspaceDocumentStore, runner: WidgetJobRunner) {
    self.store = store
    self.documents = documents
    self.runner = runner
  }

  public func call(_ input: WidgetCreateInput, context: ToolContext) async throws
    -> WidgetPackageOutput
  {
    let name = try normalizedWidgetName(input.name)
    let network = try validatedNetwork(input.network ?? [])
    let theme = try validatedTheme(
      background: input.background, accent: input.accent, text: input.textColor)
    let packagePath = "Widgets/\(UUID().uuidString.lowercased())"
    let manifest: WidgetManifest
    var html: String?

    if let viewRaw = input.view {
      guard input.html == nil else {
        throw ToolRegistryError.invalidInput("Provide either view or html, not both")
      }
      guard let kind = WidgetViewKind(rawValue: viewRaw) else {
        throw ToolRegistryError.invalidInput(
          "Unknown view '\(viewRaw)'. Use number, line, bar, pie, or table")
      }
      let view = WidgetViewDescriptor(
        kind: kind, unit: input.unit, historyLimit: input.historyLimit)
      var job: WidgetJob?
      if let script = input.script {
        guard !script.isEmpty, script.utf8.count <= 262_144 else {
          throw ToolRegistryError.invalidInput("Widget scripts must contain 1 byte–256 KB")
        }
        try await documents.replace(
          relativePath: "\(packagePath)/\(Self.scriptRelativePath)", text: script)
        job = WidgetJob(script: Self.scriptRelativePath, timeoutSeconds: input.timeoutSeconds)
      }
      manifest = WidgetManifest(
        name: name,
        description: "Typed Otto widget",
        permissions: WidgetPermissions(network: network),
        schedule: try validatedSchedule(
          cron: input.cron, intervalSeconds: input.intervalSeconds, hasJob: job != nil),
        view: view,
        job: job,
        theme: theme
      )
    } else {
      let source = try validatedWidgetHTML(input.html ?? Self.starterHTML(name: name))
      html = source
      try await documents.replace(relativePath: "\(packagePath)/index.html", text: source)
      var job: WidgetJob?
      if let script = input.script {
        guard !script.isEmpty, script.utf8.count <= 262_144 else {
          throw ToolRegistryError.invalidInput("Widget scripts must contain 1 byte–256 KB")
        }
        try await documents.replace(
          relativePath: "\(packagePath)/\(Self.scriptRelativePath)", text: script)
        job = WidgetJob(script: Self.scriptRelativePath, timeoutSeconds: input.timeoutSeconds)
      }
      manifest = WidgetManifest(
        name: name,
        description: "Custom Otto widget",
        permissions: WidgetPermissions(network: network),
        schedule: try validatedSchedule(
          cron: input.cron, intervalSeconds: input.intervalSeconds, hasJob: job != nil),
        job: job,
        theme: theme
      )
    }
    try await documents.replace(
      relativePath: "\(packagePath)/widget.json", text: encodedManifest(manifest))

    let receipt = try await store.dispatch(
      .createNode(kind: .widget, at: WorldPoint(x: input.x, y: input.y)), context: context)
    guard let nodeID = receipt.affectedNodeIDs.first else {
      throw ToolRegistryError.invalidInput("Widget creation produced no node")
    }
    _ = try await store.dispatch(
      .setNodeContent(id: nodeID, content: .widget(packagePath: packagePath, state: "{}")),
      context: context
    )
    _ = try await store.dispatch(.renameNode(id: nodeID, name: name), context: context)

    if let data = input.data {
      _ = try await runner.setPayload(nodeID: nodeID, payloadJSON: data)
    } else if manifest.job != nil {
      // First run happens inline so the agent sees real data (or the script error, recorded
      // into the node state) in this tool result instead of waiting for the scheduler.
      _ = try? await runner.run(nodeID: nodeID)
    }
    let node = try await store.requiredNode(nodeID, context: context)
    return WidgetPackageOutput(
      node: node, packagePath: packagePath, manifest: manifest, html: html)
  }

  private static func starterHTML(name: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>html{color-scheme:dark}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#121715;color:#f5f0e6;font:16px Georgia,serif}main{text-align:center}small{font:10px ui-monospace,monospace;letter-spacing:.16em;color:#88e6b4}h1{font-size:44px;font-weight:400;margin:12px}</style></head>
    <body><main><small>CUSTOM OTTO WIDGET</small><h1>\(escapedHTML(name))</h1><p>Edit this package to make it yours.</p></main></body></html>
    """
  }

  private static func escapedHTML(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }
}

public struct WidgetNodeInput: Codable, Sendable {
  public var nodeID: UUID
  public init(nodeID: UUID) { self.nodeID = nodeID }
}

public struct WidgetGetTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "widget.get",
    description: "Reads a custom widget's manifest, HTML source, package path, and canvas node.",
    inputSchema: .objectSchema(
      properties: ["nodeID": .stringSchema(description: "Stable widget node UUID")],
      required: ["nodeID"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  public init(store: CanvasStore, documents: WorkspaceDocumentStore) {
    self.store = store
    self.documents = documents
  }

  public func call(_ input: WidgetNodeInput, context: ToolContext) async throws
    -> WidgetPackageOutput
  {
    let node = try await store.requiredNode(input.nodeID, context: context)
    let path = try widgetPackagePath(node)
    let manifestText = try await documents.read(relativePath: "\(path)/widget.json")
    let manifest = try JSONDecoder().decode(WidgetManifest.self, from: Data(manifestText.utf8))
    let html = try? await documents.read(relativePath: "\(path)/index.html")
    return WidgetPackageOutput(node: node, packagePath: path, manifest: manifest, html: html)
  }
}

public struct WidgetUpdateInput: Codable, Sendable {
  public var nodeID: UUID
  public var html: String?
  public var manifest: WidgetManifest?
  public var script: String?

  public init(
    nodeID: UUID, html: String? = nil, manifest: WidgetManifest? = nil, script: String? = nil
  ) {
    self.nodeID = nodeID
    self.html = html
    self.manifest = manifest
    self.script = script
  }
}

public struct WidgetUpdateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "widget.update",
    description: """
      Replaces a widget's HTML, manifest, and/or data script. Manifest updates can add or \
      change the native/custom data job, cron/interval schedule, and custom colors (a 'theme' \
      object with 'background', 'accent', and/or 'text' #RRGGBB hex strings that override \
      the app theme — use it when the user asks for specific widget colors). Script updates \
      replace the job's data script source.
      """,
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable widget node UUID"),
        "html": .stringSchema(description: "Complete replacement HTML source"),
        "manifest": .object(["type": .string("object")]),
        "script": .stringSchema(description: "Complete replacement data script source"),
      ],
      required: ["nodeID"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let get: WidgetGetTool
  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  public init(store: CanvasStore, documents: WorkspaceDocumentStore) {
    self.store = store
    self.documents = documents
    self.get = WidgetGetTool(store: store, documents: documents)
  }

  public func call(_ input: WidgetUpdateInput, context: ToolContext) async throws
    -> WidgetPackageOutput
  {
    guard input.html != nil || input.manifest != nil || input.script != nil else {
      throw ToolRegistryError.invalidInput("Provide html, manifest, or script to update")
    }
    let node = try await store.requiredNode(input.nodeID, context: context)
    let path = try widgetPackagePath(node)
    if let html = input.html {
      try await documents.replace(
        relativePath: "\(path)/index.html", text: try validatedWidgetHTML(html))
    }
    if let script = input.script {
      guard !script.isEmpty, script.utf8.count <= 262_144 else {
        throw ToolRegistryError.invalidInput("Widget scripts must contain 1 byte–256 KB")
      }
      let manifestText = try await documents.read(relativePath: "\(path)/widget.json")
      let current = try JSONDecoder().decode(WidgetManifest.self, from: Data(manifestText.utf8))
      let scriptPath =
        (input.manifest ?? current).job?.script ?? WidgetCreateTool.scriptRelativePath
      try await documents.replace(
        relativePath: "\(path)/\(try WidgetJobRunner.validatedScriptPath(scriptPath))",
        text: script)
    }
    if let manifest = input.manifest {
      _ = try normalizedWidgetName(manifest.name)
      _ = try validatedNetwork(manifest.permissions.network)
      if let theme = manifest.theme {
        _ = try validatedTheme(
          background: theme.background, accent: theme.accent, text: theme.text)
      }
      guard manifest.entry == "index.html" else {
        throw ToolRegistryError.invalidInput("Widget entry must be index.html")
      }
      if let job = manifest.job {
        _ = try WidgetJobRunner.validatedScriptPath(job.script)
      }
      if let cron = manifest.schedule?.cron {
        guard CronExpression(cron) != nil else {
          throw ToolRegistryError.invalidInput("Invalid cron expression: \(cron)")
        }
      }
      try await documents.replace(
        relativePath: "\(path)/widget.json", text: encodedManifest(manifest))
      _ = try await store.dispatch(
        .renameNode(id: input.nodeID, name: manifest.name), context: context)
    }
    return try await get.call(WidgetNodeInput(nodeID: input.nodeID), context: context)
  }
}

public struct WidgetStateOutput: Codable, Sendable, Equatable {
  public var node: OttoNode
  public var state: WidgetRuntimeState
}

public struct WidgetRefreshTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "widget.refresh",
    description:
      "Runs a widget's data job now, ahead of its schedule, and returns the refreshed runtime state (latest payload, history, and any script error).",
    inputSchema: .objectSchema(
      properties: ["nodeID": .stringSchema(description: "Stable widget node UUID")],
      required: ["nodeID"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let store: CanvasStore
  private let runner: WidgetJobRunner
  public init(store: CanvasStore, runner: WidgetJobRunner) {
    self.store = store
    self.runner = runner
  }

  public func call(_ input: WidgetNodeInput, context: ToolContext) async throws
    -> WidgetStateOutput
  {
    _ = try await store.requiredNode(input.nodeID, context: context)
    let state = try await runner.run(nodeID: input.nodeID)
    let node = try await store.requiredNode(input.nodeID, context: context)
    return WidgetStateOutput(node: node, state: state)
  }
}

public struct WidgetSetDataInput: Codable, Sendable {
  public var nodeID: UUID
  public var data: String

  public init(nodeID: UUID, data: String) {
    self.nodeID = nodeID
    self.data = data
  }
}

public struct WidgetSetDataTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "widget.set_data",
    description: """
      Pushes payload JSON straight into a widget, bypassing its script. Native views validate \
      their documented payload contract; custom HTML accepts any valid JSON and receives it as \
      window.otto.data plus an otto:data event.
      """,
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable widget node UUID"),
        "data": .stringSchema(description: "Payload JSON matching the widget's view contract"),
      ],
      required: ["nodeID", "data"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let store: CanvasStore
  private let runner: WidgetJobRunner
  public init(store: CanvasStore, runner: WidgetJobRunner) {
    self.store = store
    self.runner = runner
  }

  public func call(_ input: WidgetSetDataInput, context: ToolContext) async throws
    -> WidgetStateOutput
  {
    _ = try await store.requiredNode(input.nodeID, context: context)
    let state = try await runner.setPayload(nodeID: input.nodeID, payloadJSON: input.data)
    let node = try await store.requiredNode(input.nodeID, context: context)
    return WidgetStateOutput(node: node, state: state)
  }
}

public struct WidgetLogsInput: Codable, Sendable {
  public var nodeID: UUID
  public var limit: Int?

  public init(nodeID: UUID, limit: Int? = nil) {
    self.nodeID = nodeID
    self.limit = limit
  }
}

public struct WidgetLogsOutput: Codable, Sendable, Equatable {
  public var runs: [String]
}

public struct WidgetLogsTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "widget.logs",
    description:
      "Reads a typed widget's recent job runs (JSONL: timestamp, duration, success, message), newest last.",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable widget node UUID"),
        "limit": .integerSchema(description: "Maximum runs to return (default 20, max 200)"),
      ],
      required: ["nodeID"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  private let store: CanvasStore
  private let runner: WidgetJobRunner
  public init(store: CanvasStore, runner: WidgetJobRunner) {
    self.store = store
    self.runner = runner
  }

  public func call(_ input: WidgetLogsInput, context: ToolContext) async throws
    -> WidgetLogsOutput
  {
    _ = try await store.requiredNode(input.nodeID, context: context)
    return WidgetLogsOutput(
      runs: try await runner.runHistory(nodeID: input.nodeID, limit: input.limit ?? 20))
  }
}

public struct WidgetSummary: Codable, Sendable, Equatable {
  public var nodeID: UUID?
  public var name: String
  public var canvasID: UUID?
  public var canvasName: String?
  public var packagePath: String
  public var view: String?
  public var schedule: String?
  public var isOpen: Bool
}

public struct WidgetListInput: Codable, Sendable {
  public init() {}
}

public struct WidgetListOutput: Codable, Sendable, Equatable {
  public var widgets: [WidgetSummary]
}

public struct WidgetListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "widget.list",
    description:
      "Lists every installed widget package, including closed widgets with no canvas card. Returns its name, open state, node and canvas when open, view kind, schedule, and package path.",
    inputSchema: .objectSchema(properties: [:], required: []),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  public init(store: CanvasStore, documents: WorkspaceDocumentStore) {
    self.store = store
    self.documents = documents
  }

  public func call(_ input: WidgetListInput, context: ToolContext) async throws
    -> WidgetListOutput
  {
    let widgets = await installedWidgetEntries(in: store, documents: documents).map(\.summary)
    return WidgetListOutput(widgets: widgets.sorted { $0.name < $1.name })
  }
}

public struct WidgetOpenInput: Codable, Sendable {
  public var name: String
  public init(name: String) { self.name = name }
}

public struct WidgetOpenTool: OttoTool {
  static let savedStateRelativePath = ".otto-runtime-state.json"
  /// Written by Muse before the rename; read when the Otto file does not exist yet.
  static let legacySavedStateRelativePath = ".muse-runtime-state.json"

  public static let definition = ToolDefinition(
    name: "widget.open",
    description: """
      Finds a widget by (possibly partial or spoken) name, switches to its canvas, and brings \
      it into view. Use for requests like "open the Otto Swift Line Count widget".
      """,
    inputSchema: .objectSchema(
      properties: [
        "name": .stringSchema(description: "Widget name to match, e.g. 'swift line count'")
      ],
      required: ["name"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  public init(store: CanvasStore, documents: WorkspaceDocumentStore) {
    self.store = store
    self.documents = documents
  }

  public func call(_ input: WidgetOpenInput, context: ToolContext) async throws
    -> WidgetStateOutput
  {
    let entries = await installedWidgetEntries(in: store, documents: documents)
    guard let match = matchWidget(named: input.name, in: entries) else {
      let available = entries.map(\.name).joined(separator: ", ")
      throw ToolRegistryError.invalidInput(
        entries.isEmpty
          ? "No widgets exist yet"
          : "No widget matches '\(input.name)'. Available: \(available)")
    }

    if let live = match.live {
      if await store.snapshot.activeCanvasID != live.canvasID {
        _ = await store.dispatch(.switchCanvas(live.canvasID))
      }
      _ = await store.dispatch(.focusNode(live.node.id), targetCanvasID: live.canvasID)
      let state: WidgetRuntimeState =
        if case .widget(_, let stateJSON) = live.node.content {
          WidgetRuntimeState.decode(from: stateJSON)
        } else {
          WidgetRuntimeState()
        }
      return WidgetStateOutput(node: live.node, state: state)
    }

    let placement = await MainActor.run {
      WorldPoint(
        x: store.activeCanvas.viewport.centerX - NodeKind.widget.defaultSize.width / 2,
        y: store.activeCanvas.viewport.centerY - NodeKind.widget.defaultSize.height / 2
      )
    }
    let receipt = try await store.dispatch(
      .createNode(kind: .widget, at: placement), context: context)
    guard let nodeID = receipt.affectedNodeIDs.first else {
      throw ToolRegistryError.invalidInput("Opening the widget produced no canvas card")
    }
    var savedState = try? await documents.read(
      relativePath: "\(match.packagePath)/\(Self.savedStateRelativePath)")
    if savedState == nil {
      savedState = try? await documents.read(
        relativePath: "\(match.packagePath)/\(Self.legacySavedStateRelativePath)")
    }
    let state = savedState ?? "{}"
    _ = try await store.dispatch(
      .setNodeContent(
        id: nodeID, content: .widget(packagePath: match.packagePath, state: state)),
      context: context
    )
    _ = try await store.dispatch(.renameNode(id: nodeID, name: match.name), context: context)
    let node = try await store.requiredNode(nodeID, context: context)
    return WidgetStateOutput(node: node, state: WidgetRuntimeState.decode(from: state))
  }
}

public struct WidgetCloseOutput: Codable, Sendable, Equatable {
  public var closed: WidgetSummary
  public var message: String
}

public struct WidgetCloseTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "widget.close",
    description:
      "Closes a widget's canvas card by spoken or partial name while keeping its package installed, searchable, and available to reopen later.",
    inputSchema: .objectSchema(
      properties: [
        "name": .stringSchema(description: "Widget name to match, e.g. 'swift line count'")
      ],
      required: ["name"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  public init(store: CanvasStore, documents: WorkspaceDocumentStore) {
    self.store = store
    self.documents = documents
  }

  public func call(_ input: WidgetOpenInput, context: ToolContext) async throws
    -> WidgetCloseOutput
  {
    let entries = await installedWidgetEntries(in: store, documents: documents)
    guard let match = matchWidget(named: input.name, in: entries) else {
      let available = entries.map(\.name).joined(separator: ", ")
      throw ToolRegistryError.invalidInput(
        entries.isEmpty
          ? "No widgets exist yet"
          : "No widget matches '\(input.name)'. Available: \(available)")
    }
    guard let live = match.live else {
      throw ToolRegistryError.invalidInput("\(match.name) is already closed")
    }
    if case .widget(_, let state) = live.node.content {
      try await documents.replace(
        relativePath: "\(match.packagePath)/\(WidgetOpenTool.savedStateRelativePath)",
        text: state
      )
    }
    _ = await store.dispatch(.closeNode(live.node.id), targetCanvasID: live.canvasID)
    var summary = match.summary
    summary.nodeID = nil
    summary.canvasID = nil
    summary.canvasName = nil
    summary.isOpen = false
    return WidgetCloseOutput(closed: summary, message: "Closed \(match.name); it remains installed")
  }
}

public struct WidgetDeleteInput: Codable, Sendable {
  public var nodeID: UUID?
  public var name: String?

  public init(nodeID: UUID? = nil, name: String? = nil) {
    self.nodeID = nodeID
    self.name = name
  }
}

public struct WidgetDeleteOutput: Codable, Sendable, Equatable {
  public var deleted: WidgetSummary
  public var message: String
}

public struct WidgetDeleteTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "widget.delete",
    description:
      "Deletes a widget by node ID or name: closes its canvas node and moves its package folder to the Trash (recoverable from there).",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable widget node UUID"),
        "name": .stringSchema(description: "Widget name to match when the ID is unknown"),
      ],
      required: []
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .destructive
  )

  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  public init(store: CanvasStore, documents: WorkspaceDocumentStore) {
    self.store = store
    self.documents = documents
  }

  public func call(_ input: WidgetDeleteInput, context: ToolContext) async throws
    -> WidgetDeleteOutput
  {
    let entries = await installedWidgetEntries(in: store, documents: documents)
    let match: InstalledWidgetEntry? =
      if let nodeID = input.nodeID {
        entries.first { $0.live?.node.id == nodeID }
      } else if let name = input.name {
        matchWidget(named: name, in: entries)
      } else {
        nil
      }
    guard input.nodeID != nil || input.name != nil else {
      throw ToolRegistryError.invalidInput("Provide nodeID or name")
    }
    guard let match else {
      throw ToolRegistryError.invalidInput(
        "No widget matches \(input.nodeID.map(\.uuidString) ?? input.name ?? "")")
    }
    if let live = match.live {
      _ = await store.dispatch(.closeNode(live.node.id), targetCanvasID: live.canvasID)
    }
    try await documents.trash(relativePath: match.packagePath)
    let summary = match.summary
    return WidgetDeleteOutput(
      deleted: summary,
      message: "Deleted \(match.name); its package is in the Trash"
    )
  }
}

struct WidgetEntry: Sendable {
  let canvasID: UUID
  let canvasName: String
  let node: OttoNode
  let packagePath: String
}

struct InstalledWidgetEntry: Sendable {
  let packagePath: String
  let manifest: WidgetManifest
  let live: WidgetEntry?

  var name: String { manifest.name }

  var summary: WidgetSummary {
    WidgetSummary(
      nodeID: live?.node.id,
      name: name,
      canvasID: live?.canvasID,
      canvasName: live?.canvasName,
      packagePath: packagePath,
      view: manifest.view?.kind.rawValue,
      schedule: manifest.schedule.flatMap { schedule in
        guard schedule.enabled else { return nil }
        return schedule.cron ?? "every \(schedule.intervalSeconds)s"
      },
      isOpen: live != nil
    )
  }
}

@MainActor
private func widgetEntries(in store: CanvasStore) -> [WidgetEntry] {
  store.snapshot.canvases.flatMap { canvas in
    canvas.nodes.compactMap { node -> WidgetEntry? in
      guard node.kind == .widget, case .widget(let path, _) = node.content, !path.isEmpty else {
        return nil
      }
      return WidgetEntry(
        canvasID: canvas.id, canvasName: canvas.name, node: node, packagePath: path)
    }
  }
}

private func installedWidgetEntries(
  in store: CanvasStore, documents: WorkspaceDocumentStore
) async -> [InstalledWidgetEntry] {
  let liveEntries = await widgetEntries(in: store)
  let liveByPath = Dictionary(
    liveEntries.map { ($0.packagePath, $0) },
    uniquingKeysWith: { first, _ in first })
  let widgetsURL = URL(fileURLWithPath: documents.rootPath, isDirectory: true)
    .appendingPathComponent("Widgets", isDirectory: true)
  let packageURLs =
    (try? FileManager.default.contentsOfDirectory(
      at: widgetsURL, includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles])) ?? []

  var installed: [InstalledWidgetEntry] = []
  for url in packageURLs {
    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
      continue
    }
    let packagePath = "Widgets/\(url.lastPathComponent)"
    guard let manifest = try? await readManifest(documents: documents, packagePath: packagePath)
    else { continue }
    installed.append(
      InstalledWidgetEntry(
        packagePath: packagePath, manifest: manifest, live: liveByPath[packagePath]))
  }

  // Keep live cards discoverable even if their package is temporarily unreadable. This lets the
  // user focus or close the card and makes the package problem visible instead of hiding it.
  let installedPaths = Set(installed.map(\.packagePath))
  for live in liveEntries where !installedPaths.contains(live.packagePath) {
    installed.append(
      InstalledWidgetEntry(
        packagePath: live.packagePath,
        manifest: WidgetManifest(
          name: live.node.displayName, description: "Unreadable widget package"),
        live: live
      ))
  }
  return installed
}

private func readManifest(
  documents: WorkspaceDocumentStore, packagePath: String
) async throws -> WidgetManifest {
  let text = try await documents.read(relativePath: "\(packagePath)/widget.json")
  return try JSONDecoder().decode(WidgetManifest.self, from: Data(text.utf8))
}

/// Matches a spoken or typed widget name against installed widgets: exact normalized match
/// first, then substring, then "all meaningful query words appear in the name" — so
/// "open the Otto Swift line count widget" finds "Otto Swift Line Count".
private func matchWidget(named query: String, in entries: [InstalledWidgetEntry])
  -> InstalledWidgetEntry?
{
  func tokens(_ value: String) -> [String] {
    value.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }
  let filler: Set<String> = ["widget", "the", "a", "my", "open", "show"]
  let queryTokens = tokens(query).filter { !filler.contains($0) }
  guard !queryTokens.isEmpty else { return nil }
  let needle = queryTokens.joined(separator: " ")

  var best: (entry: InstalledWidgetEntry, score: Int)?
  for entry in entries {
    let nameTokens = tokens(entry.name)
    let name = nameTokens.joined(separator: " ")
    let score: Int
    if name == needle {
      score = 3
    } else if name.contains(needle) || needle.contains(name) {
      score = 2
    } else if queryTokens.allSatisfy(nameTokens.contains) {
      score = 1
    } else {
      continue
    }
    if score > (best?.score ?? 0) { best = (entry, score) }
  }
  return best?.entry
}

private func validatedTheme(
  background: String?, accent: String?, text: String?
) throws -> WidgetTheme? {
  func normalized(_ value: String?, name: String) throws -> String? {
    guard let value else { return nil }
    guard let hex = WidgetTheme.normalizedHex(value) else {
      throw ToolRegistryError.invalidInput(
        "Invalid \(name) color '\(value)'. Use #RRGGBB hex, e.g. #00FF66")
    }
    return hex
  }
  let theme = WidgetTheme(
    background: try normalized(background, name: "background"),
    accent: try normalized(accent, name: "accent"),
    text: try normalized(text, name: "text")
  )
  return theme.isEmpty ? nil : theme
}

private func encodedManifest(_ manifest: WidgetManifest) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(manifest)
  guard let text = String(data: data, encoding: .utf8) else {
    throw ToolRegistryError.invalidInput("Widget manifest could not be encoded")
  }
  return text + "\n"
}

private func validatedSchedule(
  cron: String?, intervalSeconds: Int?, hasJob: Bool
) throws -> WidgetSchedule? {
  guard hasJob else { return nil }
  if let cron {
    guard CronExpression(cron) != nil else {
      throw ToolRegistryError.invalidInput("Invalid cron expression: \(cron)")
    }
    return WidgetSchedule(
      enabled: true, intervalSeconds: max(60, intervalSeconds ?? 3_600), cron: cron)
  }
  if let intervalSeconds {
    return WidgetSchedule(enabled: true, intervalSeconds: max(60, intervalSeconds))
  }
  return nil
}

private func widgetPackagePath(_ node: OttoNode) throws -> String {
  guard node.kind == .widget, case .widget(let path, _) = node.content, !path.isEmpty else {
    throw ToolRegistryError.invalidInput("Node is not a configured widget")
  }
  return path
}

private func normalizedWidgetName(_ value: String) throws -> String {
  let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !name.isEmpty, name.count <= 80 else {
    throw ToolRegistryError.invalidInput("Widget name must contain 1–80 characters")
  }
  return name
}

private func validatedWidgetHTML(_ value: String) throws -> String {
  guard !value.isEmpty, value.utf8.count <= 1_048_576 else {
    throw ToolRegistryError.invalidInput("Widget HTML must contain 1 byte–1 MB")
  }
  return value
}

private func validatedNetwork(_ values: [String]) throws -> [String] {
  guard values.count <= 32 else {
    throw ToolRegistryError.invalidInput("Widgets may allow at most 32 network origins")
  }
  for value in values {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme), url.host != nil, url.user == nil, url.password == nil
    else { throw ToolRegistryError.invalidInput("Invalid widget network origin: \(value)") }
  }
  return values
}
