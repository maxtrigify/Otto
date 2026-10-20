import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools

public struct SetFontScaleInput: Codable, Sendable {
  public var scale: OttoFontScale
  public init(scale: OttoFontScale) { self.scale = scale }
}

public struct SetFontScaleOutput: Codable, Equatable, Sendable {
  public var scale: OttoFontScale
  public var multiplier: Double
}

public struct ThemeSetFontScaleTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "theme.set_font_scale",
    description:
      "Sets the persisted application text scale used by conversations, terminals, and documents.",
    inputSchema: .objectSchema(
      properties: [
        "scale": .stringSchema(description: "extraSmall, small, standard, large, or extraLarge")
      ],
      required: ["scale"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let suiteName: String?
  public init(suiteName: String? = nil) { self.suiteName = suiteName }

  public func call(_ input: SetFontScaleInput, context: ToolContext) async throws
    -> SetFontScaleOutput
  {
    defaults.set(input.scale.rawValue, forKey: OttoPreferenceKey.fontScale)
    return SetFontScaleOutput(scale: input.scale, multiplier: input.scale.multiplier)
  }

  private var defaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }
}

public struct SetMatteOpacityInput: Codable, Sendable {
  /// Explicit surface opacity for matte themes, or nil/0 to restore the theme default.
  public var opacity: Double?
  public init(opacity: Double? = nil) { self.opacity = opacity }
}

public struct SetMatteOpacityOutput: Codable, Equatable, Sendable {
  public var opacity: Double?
  public var effect: String
}

public struct ThemeSetMatteOpacityTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "theme.set_matte_opacity",
    description:
      "Sets the persisted surface opacity for Velvet's matte material. "
      + "Values are clamped to 0.55–1.0; omit or pass 0 to restore the theme default.",
    inputSchema: .objectSchema(
      properties: [
        "opacity": .object([
          "type": .string("number"),
          "description": .string("0.55 (sheer) to 1.0 (solid); omit for theme default"),
        ])
      ],
      required: []
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let suiteName: String?
  public init(suiteName: String? = nil) { self.suiteName = suiteName }

  public func call(_ input: SetMatteOpacityInput, context: ToolContext) async throws
    -> SetMatteOpacityOutput
  {
    guard let raw = input.opacity, raw > 0 else {
      defaults.removeObject(forKey: OttoPreferenceKey.matteOpacity)
      return SetMatteOpacityOutput(opacity: nil, effect: "Matte themes use their designed opacity")
    }
    let clamped = OttoMatteTransparency.clamped(raw)
    defaults.set(clamped, forKey: OttoPreferenceKey.matteOpacity)
    return SetMatteOpacityOutput(
      opacity: clamped,
      effect: "Matte theme surfaces now render at \(Int((clamped * 100).rounded()))% opacity")
  }

  private var defaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }
}

public struct SetAgentNamingInput: Codable, Sendable {
  public var mode: AgentNamingMode
  public var names: [String]?
  public init(mode: AgentNamingMode, names: [String]? = nil) {
    self.mode = mode
    self.names = names
  }
}

public struct SetAgentNamingOutput: Codable, Equatable, Sendable {
  public var mode: AgentNamingMode
  public var names: [String]
}

public struct AgentSetNamingTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.set_naming",
    description: "Chooses Otto's original agent-name roster or installs a custom ordered roster.",
    inputSchema: .objectSchema(
      properties: [
        "mode": .stringSchema(description: "otto or custom"),
        "names": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
      ],
      required: ["mode"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .reversible
  )

  private let suiteName: String?
  public init(suiteName: String? = nil) { self.suiteName = suiteName }

  public func call(_ input: SetAgentNamingInput, context: ToolContext) async throws
    -> SetAgentNamingOutput
  {
    let policy = AgentNamingPolicy(mode: input.mode, customNames: input.names ?? [])
    if input.mode == .custom, policy.customNames.isEmpty {
      throw ToolRegistryError.invalidInput("Custom naming requires at least one non-empty name")
    }
    policy.save(to: defaults)
    return SetAgentNamingOutput(mode: policy.mode, names: policy.roster)
  }

  private var defaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }
}

public struct SetPermissionDefaultInput: Codable, Sendable {
  public var provider: AgentProvider
  public var permissionMode: AgentPermissionMode
  public init(provider: AgentProvider, permissionMode: AgentPermissionMode) {
    self.provider = provider
    self.permissionMode = permissionMode
  }
}

public struct AgentSetPermissionDefaultTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.set_permission_default",
    description: "Sets the persisted default permission profile for one provider.",
    inputSchema: .objectSchema(
      properties: [
        "provider": .stringSchema(
          description: "claudeCode, codex, cursor, grok, hermes, kimi, openCode, or shell"),
        "permissionMode": .stringSchema(description: "readOnly, workspaceWrite, or unrestricted"),
      ],
      required: ["provider", "permissionMode"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .reversible
  )

  private let suiteName: String?
  public init(suiteName: String? = nil) { self.suiteName = suiteName }

  public func call(_ input: SetPermissionDefaultInput, context: ToolContext) async throws
    -> SetPermissionDefaultInput
  {
    defaults.set(input.permissionMode.rawValue, forKey: permissionKey(input.provider))
    return input
  }

  private var defaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }
}

public struct SetAgentDefaultViewInput: Codable, Sendable {
  public var view: AgentDefaultView
  public init(view: AgentDefaultView) { self.view = view }
}

public struct AgentSetDefaultViewTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "agent.set_default_view",
    description: "Sets whether newly opened agents default to the chat or terminal view.",
    inputSchema: .objectSchema(
      properties: ["view": .stringSchema(description: "chat or terminal")],
      required: ["view"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .reversible
  )

  private let suiteName: String?
  public init(suiteName: String? = nil) { self.suiteName = suiteName }

  public func call(_ input: SetAgentDefaultViewInput, context: ToolContext) async throws
    -> SetAgentDefaultViewInput
  {
    input.view.save(to: defaults)
    return input
  }

  private var defaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }
}

public func permissionKey(_ provider: AgentProvider) -> String {
  switch provider {
  case .claudeCode: OttoPreferenceKey.claudePermissionMode
  case .codex: OttoPreferenceKey.codexPermissionMode
  case .openAI: OttoPreferenceKey.codexPermissionMode
  case .hermes: OttoPreferenceKey.hermesPermissionMode
  case .cursor: OttoPreferenceKey.cursorPermissionMode
  case .kimi: OttoPreferenceKey.kimiPermissionMode
  case .openCode: OttoPreferenceKey.openCodePermissionMode
  case .grok: OttoPreferenceKey.grokPermissionMode
  case .shell: OttoPreferenceKey.shellPermissionMode
  }
}
