import Foundation
import OttoTools

public enum PermissionProfile: String, Codable, CaseIterable, Sendable {
  case reviewOnly
  case workspaceSafe
  case unrestricted
}

public enum PermissionDecision: Sendable, Equatable {
  case allow
  case requireConfirmation(reason: String)
  case deny(reason: String)
}

public enum PermissionPolicy {
  public static func decide(
    profile: PermissionProfile,
    definition: ToolDefinition,
    hasRequiredScopes: Bool
  ) -> PermissionDecision {
    guard hasRequiredScopes else { return .deny(reason: "The caller lacks a required scope") }
    switch profile {
    case .reviewOnly:
      return definition.riskLevel == .read
        ? .allow
        : .deny(reason: "Review-only sessions cannot mutate workspace or canvas state")
    case .workspaceSafe:
      switch definition.riskLevel {
      case .read, .reversible: return .allow
      case .consequential:
        return .requireConfirmation(reason: "This action may change workspace files or processes")
      case .destructive:
        return .deny(reason: "Destructive global actions require unrestricted mode")
      }
    case .unrestricted:
      if definition.riskLevel == .destructive || definition.requiresConfirmation {
        return .requireConfirmation(reason: "Confirm the destructive action")
      }
      return .allow
    }
  }
}

public actor RecursiveSpawnLimiter {
  private let maximum: Int
  private let window: Duration
  private let clock = ContinuousClock()
  private var attempts: [String: [ContinuousClock.Instant]] = [:]

  public init(maximum: Int = 3, window: Duration = .seconds(60)) {
    self.maximum = maximum
    self.window = window
  }

  public func consume(actorID: String) -> Bool {
    let now = clock.now
    let cutoff = now - window
    var recent = (attempts[actorID] ?? []).filter { $0 >= cutoff }
    guard recent.count < maximum else {
      attempts[actorID] = recent
      return false
    }
    recent.append(now)
    attempts[actorID] = recent
    return true
  }
}
