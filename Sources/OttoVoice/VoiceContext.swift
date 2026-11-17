import Foundation
import OttoModels

public struct VoiceContext: Codable, Equatable, Sendable {
  public var activeCanvas: VoiceCanvasContext
  public var canvases: [VoiceCanvasContext]
  public var nodes: [VoiceNodeContext]
  public var focusedNodeID: UUID?
  public var recentEvents: [String]
  public var knownWorkspaces: [String]
  public var sessions: [VoiceSessionContext]
  public var bots: [VoiceBotContext]
  public var teams: [VoiceTeamContext]
  /// The models each installed harness offers, so a spoken model name can be matched to a real
  /// one. Absent until the harnesses have been asked.
  public var models: [VoiceHarnessModels]?
  /// Where the person is in Otto and what they are looking at, so "this", "here" and "that
  /// page" mean something. Absent when Otto has not said.
  public var screen: VoiceScreenContext?

  public init(
    activeCanvas: VoiceCanvasContext,
    canvases: [VoiceCanvasContext] = [],
    nodes: [VoiceNodeContext],
    focusedNodeID: UUID? = nil,
    recentEvents: [String] = [],
    knownWorkspaces: [String] = [],
    sessions: [VoiceSessionContext] = [],
    bots: [VoiceBotContext] = [],
    teams: [VoiceTeamContext] = []
  ) {
    self.activeCanvas = activeCanvas
    self.canvases = canvases.isEmpty ? [activeCanvas] : canvases
    self.nodes = nodes
    self.focusedNodeID = focusedNodeID
    self.recentEvents = recentEvents
    self.knownWorkspaces = knownWorkspaces
    self.sessions = sessions
    self.bots = bots
    self.teams = teams
  }

  public init(
    canvas: OttoCanvas,
    workspace: String,
    knownWorkspaces: [String] = [],
    canvases: [OttoCanvas] = []
  ) {
    activeCanvas = VoiceCanvasContext(
      id: canvas.id,
      name: canvas.name,
      workspace: workspace,
      layout: canvas.layoutMode ?? .freeform
    )
    self.canvases = (canvases.isEmpty ? [canvas] : canvases).map {
      VoiceCanvasContext(
        id: $0.id,
        name: $0.name,
        workspace: workspace,
        layout: $0.layoutMode ?? .freeform
      )
    }
    nodes = canvas.nodes.map(VoiceNodeContext.init)
    focusedNodeID = canvas.selectedNodeID
    recentEvents = []
    self.knownWorkspaces = knownWorkspaces
    sessions = []
    bots = []
    teams = []
  }
}

/// What is in front of the person right now.
public struct VoiceScreenContext: Codable, Equatable, Sendable {
  /// The place in Otto: Home, Chat, Documents, Browser, Activity and so on.
  public var place: String
  /// What kind of thing is open there: a bot, session, team, document or web page.
  public var kind: String?
  /// Its name, as the person sees it.
  public var showing: String?
  /// The session, bot conversation or browser page, for the tools that read one.
  public var nodeID: UUID?
  /// The open document's path, for the tools that read one.
  public var path: String?
  public var url: String?

  public init(
    place: String, kind: String? = nil, showing: String? = nil, nodeID: UUID? = nil,
    path: String? = nil, url: String? = nil
  ) {
    self.place = place
    self.kind = kind
    self.showing = showing
    self.nodeID = nodeID
    self.path = path
    self.url = url
  }

  /// One line a voice model can be told, with nothing in it that should not be said aloud.
  public var summary: String {
    guard let showing, !showing.isEmpty else { return "The user is looking at \(place) in Otto." }
    let what = kind.map { "the \($0) \"\(showing)\"" } ?? "\"\(showing)\""
    return "The user is in \(place) in Otto, looking at \(what)."
  }
}

/// The models one harness can run, by the name the person sees and the id a tool call takes.
public struct VoiceHarnessModels: Codable, Equatable, Sendable {
  public var harness: String
  public var models: [VoiceModelName]

  public init(harness: String, models: [VoiceModelName]) {
    self.harness = harness
    self.models = models
  }
}

public struct VoiceModelName: Codable, Equatable, Sendable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct VoiceSessionContext: Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var canvasID: UUID
  public var provider: AgentProvider?
  public var status: NodeStatus

  public init(
    id: UUID,
    name: String,
    canvasID: UUID,
    provider: AgentProvider?,
    status: NodeStatus
  ) {
    self.id = id
    self.name = name
    self.canvasID = canvasID
    self.provider = provider
    self.status = status
  }
}

public struct VoiceBotContext: Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var handle: String
  public var jobTitle: String?
  public var nodeID: UUID?

  public init(id: UUID, name: String, handle: String, jobTitle: String?, nodeID: UUID?) {
    self.id = id
    self.name = name
    self.handle = handle
    self.jobTitle = jobTitle
    self.nodeID = nodeID
  }
}

public struct VoiceTeamContext: Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var memberHandles: [String]
  public var orchestratorHandle: String?

  public init(
    id: UUID, name: String, memberHandles: [String], orchestratorHandle: String?
  ) {
    self.id = id
    self.name = name
    self.memberHandles = memberHandles
    self.orchestratorHandle = orchestratorHandle
  }
}

public struct VoiceCanvasContext: Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var workspace: String
  public var layout: LayoutMode

  public init(id: UUID, name: String, workspace: String, layout: LayoutMode) {
    self.id = id
    self.name = name
    self.workspace = workspace
    self.layout = layout
  }
}

public struct VoiceNodeContext: Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var kind: NodeKind
  public var provider: AgentProvider?
  public var status: NodeStatus

  public init(id: UUID, name: String, kind: NodeKind, provider: AgentProvider?, status: NodeStatus)
  {
    self.id = id
    self.name = name
    self.kind = kind
    self.provider = provider
    self.status = status
  }

  public init(node: OttoNode) {
    let provider: AgentProvider?
    if case .agent(let value) = node.content {
      provider = value
    } else {
      provider = nil
    }
    self.init(
      id: node.id,
      name: node.displayName,
      kind: node.kind,
      provider: provider,
      status: node.status
    )
  }
}
