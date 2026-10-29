import Foundation
import OttoModels
import OttoRuntime
import OttoTools

public enum DiagnosticStatus: String, Codable, Sendable {
  case pass
  case warning
  case failure
}

public struct DiagnosticCheck: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var title: String
  public var status: DiagnosticStatus
  public var detail: String
  public var remediation: String?
}

public struct DiagnosticReport: Codable, Sendable, Equatable {
  public var generatedAt: Date
  public var readyForLocalUse: Bool
  public var checks: [DiagnosticCheck]
}

public struct DiagnosticsRunInput: Codable, Sendable {
  public init() {}
}

public struct DiagnosticsRunTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "diagnostics.run",
    description:
      "Checks local provider and workspace readiness without returning paths or content.",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([:]),
      "additionalProperties": .bool(false),
    ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  private let workspacePath: String
  private let adapters: [any AgentAdapter]
  private let mcpExecutablePath: String?

  public init(
    workspacePath: String,
    adapters: [any AgentAdapter]? = nil,
    mcpExecutablePath: String? = nil
  ) {
    self.workspacePath = workspacePath
    self.adapters =
      adapters ?? [
        ClaudeCodeAdapter(), CodexAdapter(), OpenAIDirectAdapter(), CursorAdapter(), GrokAdapter(),
        HermesAdapter(),
        KimiAdapter(), OpenCodeAdapter(), PiAdapter(), ShellAdapter(),
      ]
    self.mcpExecutablePath = mcpExecutablePath
  }

  public func call(_ input: DiagnosticsRunInput, context: ToolContext) async -> DiagnosticReport {
    var checks: [DiagnosticCheck] = []
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: workspacePath, isDirectory: &isDirectory)
    let writable =
      exists && isDirectory.boolValue
      && FileManager.default.isWritableFile(atPath: workspacePath)
    checks.append(
      DiagnosticCheck(
        id: "workspace",
        title: "Workspace access",
        status: writable ? .pass : .failure,
        detail: writable ? "Workspace is available and writable." : "Workspace is not writable.",
        remediation: writable ? nil : "Choose a writable workspace folder in Otto."
      ))

    let gitMarker = URL(fileURLWithPath: workspacePath).appending(path: ".git").path
    let hasGit = FileManager.default.fileExists(atPath: gitMarker)
    checks.append(
      DiagnosticCheck(
        id: "git",
        title: "Git worktrees",
        status: hasGit ? .pass : .warning,
        detail: hasGit ? "Git repository detected." : "No Git repository detected.",
        remediation: hasGit ? nil : "Initialize Git to enable isolated editing-agent worktrees."
      ))

    for adapter in adapters {
      let id = diagnosticProviderID(adapter.provider)
      switch await adapter.detectInstallation() {
      case .installed(_, let version):
        let compatibility = ProviderCompatibilityPolicy.evaluate(
          provider: adapter.provider,
          reportedVersion: version
        )
        checks.append(
          DiagnosticCheck(
            id: id,
            title: "\(adapter.provider.rawValue) provider",
            status: compatibility.state == .supported ? .pass : .warning,
            detail: "Installed (\(version)). \(compatibility.detail)",
            remediation: compatibility.state == .unsupported ? compatibility.detail : nil
          ))
      case .missing(let remediation):
        checks.append(
          DiagnosticCheck(
            id: id,
            title: "\(adapter.provider.rawValue) provider",
            status: .warning,
            detail: "Not installed.",
            remediation: remediation
          ))
      }
    }

    let bundledMCP = Bundle.main.executableURL?.deletingLastPathComponent()
      .appending(path: "otto-mcp").path
    let mcpPath = mcpExecutablePath ?? bundledMCP ?? ExecutableLocator.find("otto-mcp")
    let hasMCP = mcpPath.map(FileManager.default.isExecutableFile(atPath:)) == true
    checks.append(
      DiagnosticCheck(
        id: "mcp",
        title: "Agent tool bridge",
        status: hasMCP ? .pass : .warning,
        detail: hasMCP ? "Otto MCP bridge is executable." : "Otto MCP bridge is unavailable.",
        remediation: hasMCP ? nil : "Reinstall Otto so the bundled otto-mcp executable is present."
      ))

    return DiagnosticReport(
      generatedAt: .now,
      readyForLocalUse: !checks.contains(where: { $0.status == .failure }),
      checks: checks
    )
  }
}

private func diagnosticProviderID(_ provider: AgentProvider) -> String {
  switch provider {
  case .claudeCode: "provider.claude-code"
  case .codex: "provider.codex"
  case .openAI: "provider.openai-api"
  case .hermes: "provider.hermes"
  case .cursor: "provider.cursor"
  case .kimi: "provider.kimi"
  case .openCode: "provider.opencode"
  case .pi: "provider.pi"
  case .grok: "provider.grok"
  case .shell: "provider.shell"
  }
}
