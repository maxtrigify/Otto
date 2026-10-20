public enum AgentDisplayStatus: String, Codable, CaseIterable, Sendable {
  case needsYou = "Needs you"
  case failed = "Failed"
  case working = "Working"
  case idle = "Idle"

  public init(_ status: NodeStatus) {
    switch status {
    case .waiting: self = .needsYou
    case .failed: self = .failed
    case .starting, .working: self = .working
    case .idle, .done, .stopped: self = .idle
    }
  }

  public var sortOrder: Int {
    switch self {
    case .needsYou: 0
    case .failed: 1
    case .working: 2
    case .idle: 3
    }
  }
}

public struct StageRailSections: Equatable, Sendable {
  public var needsYou: [OttoNode]
  public var agents: [OttoNode]
  public var windows: [OttoNode]

  public init(nodes: [OttoNode]) {
    let agentNodes = nodes.filter { $0.kind == .agent }
    needsYou = Self.sorted(
      agentNodes.filter { AgentDisplayStatus($0.status) == .needsYou })
    agents = Self.sorted(
      agentNodes.filter { AgentDisplayStatus($0.status) != .needsYou })
    windows = Self.sorted(nodes.filter { Self.isWindow($0.kind) })
  }

  private static func sorted(_ nodes: [OttoNode]) -> [OttoNode] {
    nodes.sorted {
      let leftStatus = AgentDisplayStatus($0.status).sortOrder
      let rightStatus = AgentDisplayStatus($1.status).sortOrder
      if leftStatus != rightStatus { return leftStatus < rightStatus }
      return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  private static func isWindow(_ kind: NodeKind) -> Bool {
    switch kind {
    case .terminal, .browser, .markdown, .media, .appMirror, .whiteboard, .gtmGrid, .widget,
      .unsupported:
      true
    case .agent, .label, .group, .connector:
      false
    }
  }
}

public struct AmbientAgentStatus: Equatable, Sendable {
  public var working: Int
  public var queued: Int
  public var waiting: Int

  public init(nodes: [OttoNode]) {
    let agents = nodes.filter { $0.kind == .agent }
    working = agents.count { $0.status == .working }
    queued = agents.count { $0.status == .starting }
    waiting = agents.count { $0.status == .waiting }
  }

  public init(working: Int, queued: Int, waiting: Int) {
    self.working = working
    self.queued = queued
    self.waiting = waiting
  }

  public var isEmpty: Bool { working == 0 && queued == 0 && waiting == 0 }

  public var label: String {
    var parts: [String] = []
    if working > 0 { parts.append("\(working) working") }
    if queued > 0 { parts.append("\(queued) queued") }
    if waiting > 0 { parts.append("\(waiting) waiting") }
    return parts.joined(separator: " · ")
  }
}
