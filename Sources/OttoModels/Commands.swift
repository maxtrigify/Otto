import Foundation

public enum CanvasCommand: Sendable, Equatable {
  case createCanvas(name: String)
  case switchCanvas(UUID)
  case createNode(kind: NodeKind, at: WorldPoint, parentAgentID: UUID? = nil)
  case focusNode(UUID?)
  case moveNode(id: UUID, to: WorldPoint)
  case resizeNode(id: UUID, width: Double, height: Double)
  case closeNode(UUID)
  case closeAll
  case setNodeStatus(id: UUID, status: NodeStatus, detail: String)
  case setNodeContent(id: UUID, content: NodeContent)
  case setBrowserSession(id: UUID, session: BrowserSession)
  case setBrowserOwner(id: UUID, agentID: UUID?)
  case updateBrowserTab(id: UUID, tabID: UUID, url: String, title: String?)
  case setAgentDefinition(id: UUID, definition: AgentDefinition)
  case setNodeWorkTitle(id: UUID, title: String?)
  case setNodePresentation(id: UUID, presentation: NodePresentationMode)
  case setNodeMinimized(id: UUID, minimized: Bool)
  case renameNode(id: UUID, name: String)
  case addAttachments(id: UUID, attachments: [OttoAttachment])
  case setNodeSubtitle(id: UUID, subtitle: String)
  case setLayout(LayoutMode)
  case organize
  case setTheme(String)
  case setViewport(Viewport)
  case setAutoFit(Bool)
  case renameCanvas(String)
}

public struct CommandReceipt: Equatable, Sendable {
  public var message: String
  public var affectedNodeIDs: [UUID]

  public init(message: String, affectedNodeIDs: [UUID] = []) {
    self.message = message
    self.affectedNodeIDs = affectedNodeIDs
  }
}
