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
