import Foundation
import OttoModels
import OttoTools

public struct AgentProfileOpenInput: Codable, Sendable {
  public var name: String
  public var newSession: Bool?

  public init(name: String, newSession: Bool? = nil) {
    self.name = name
    self.newSession = newSession
  }
}

public struct AgentProfileOpenOutput: Codable, Sendable, Equatable {
  public var agentID: UUID
  public var displayName: String
  public var openedExisting: Bool
}

/// Voice and other control surfaces use the same name-resolution path as Command-F.
public struct AgentProfileOpenTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.profile_open",
    description:
      "Opens a saved custom agent by name, opening its existing conversation unless a new session is requested.",
    inputSchema: .objectSchema(
      properties: [
        "name": .stringSchema(description: "Exact custom agent name, for example Buz"),
        "newSession": .booleanSchema(
          description: "True only when the user explicitly asks for a new session"),
      ],
      required: ["name"]
    ),
    outputSchema: .objectSchema(),
    requiredScopes: [.agentControl, .canvasWrite],
    riskLevel: .reversible
  )

  private let handler: @Sendable (String, Bool) async throws -> AgentProfileOpenOutput

  public init(
    handler: @escaping @Sendable (String, Bool) async throws -> AgentProfileOpenOutput
  ) {
    self.handler = handler
  }

  public func call(_ input: AgentProfileOpenInput, context: ToolContext) async throws
    -> AgentProfileOpenOutput
  {
    try await handler(input.name, input.newSession ?? false)
  }
}
