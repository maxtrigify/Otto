import Foundation
import OttoTools

public struct ControlGrant: Sendable, Equatable {
  public var actorID: String
  public var scopes: Set<ToolScope>
  public var expiresAt: Date
  public var source: ToolInvocationSource
  public var interactionPrivileges: Set<ToolInteractionPrivilege>
  public var sourceNodeID: UUID?
  public var sourceCanvasID: UUID?

  public init(
    actorID: String,
    scopes: Set<ToolScope>,
    expiresAt: Date,
    source: ToolInvocationSource = .cli,
    interactionPrivileges: Set<ToolInteractionPrivilege>? = nil,
    sourceNodeID: UUID? = nil,
    sourceCanvasID: UUID? = nil
  ) {
    self.actorID = actorID
    self.scopes = scopes
    self.expiresAt = expiresAt
    self.source = source
    self.interactionPrivileges =
      interactionPrivileges ?? source.defaultInteractionPrivileges
    self.sourceNodeID = sourceNodeID
    self.sourceCanvasID = sourceCanvasID
  }
}

public actor ControlAuthenticator {
  private var grants: [String: ControlGrant] = [:]

  public init() {}

  public func issue(
    actorID: String,
    scopes: Set<ToolScope>,
    lifetime: TimeInterval = 3_600,
    source: ToolInvocationSource = .cli,
    interactionPrivileges: Set<ToolInteractionPrivilege>? = nil,
    sourceNodeID: UUID? = nil,
    sourceCanvasID: UUID? = nil
  ) -> String {
    let token =
      UUID().uuidString.replacingOccurrences(of: "-", with: "")
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    grants[token] = ControlGrant(
      actorID: actorID,
      scopes: scopes,
      expiresAt: .now.addingTimeInterval(lifetime),
      source: source,
      interactionPrivileges: interactionPrivileges,
      sourceNodeID: sourceNodeID,
      sourceCanvasID: sourceCanvasID
    )
    return token
  }

  public func resolve(_ token: String) -> ControlGrant? {
    guard let grant = grants[token] else { return nil }
    guard grant.expiresAt > .now else {
      grants[token] = nil
      return nil
    }
    return grant
  }

  public func revoke(_ token: String) {
    grants[token] = nil
  }

  @discardableResult
  public func revokeAll(actorID: String) -> Int {
    let tokens = grants.compactMap { $0.value.actorID == actorID ? $0.key : nil }
    for token in tokens { grants[token] = nil }
    return tokens.count
  }
}
