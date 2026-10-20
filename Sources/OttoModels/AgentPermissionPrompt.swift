import Foundation

/// Shared contract for in-chat tool approvals on one-shot provider runs. Claude Code's
/// `--permission-prompt-tool` flag names an MCP tool that is called whenever the CLI needs
/// permission; Otto serves that tool through the otto-mcp bridge, forwards the request to the
/// app over the control socket, and blocks until the user answers in the agent conversation.
public enum AgentPermissionPrompt {
  /// Registry name of the approval tool the app exposes on the control socket.
  public static let toolName = "agent.request_permission"

  /// The same tool as Claude Code addresses it through the "otto" MCP server. Claude namespaces
  /// MCP tools as mcp__<server>__<name> and sanitizes characters outside [A-Za-z0-9_-] to
  /// underscores, so the registry's "agent.request_permission" becomes
  /// "agent_request_permission" — a dotted name here can never match and makes the CLI exit 1
  /// the first time an approval is needed.
  public static let mcpToolName = "mcp__otto__agent_request_permission"

  /// Automatic browser confirmations expire in the app before the bridge socket deadline.
  /// This removes stale cards and returns a denial instead of abandoning a live approval.
  public static let browserConfirmationTimeout: Duration = .seconds(60)
  public static let browserResponseTimeoutMilliseconds: Int32 = 65_000

  /// Explicit provider permission requests can still wait for a human decision.
  public static let responseTimeoutMilliseconds: Int32 = 3_600_000
}

/// Shared contract for the universal in-chat question tool. Any provider reaching Otto over the
/// otto-mcp bridge (Claude Code, Codex) can ask the user a multiple-choice question; the chat
/// surface renders the choices as buttons and the blocked tool call returns the answer. Hermes
/// has its own native clarify tool, which Otto renders through the same card.
public enum AgentUserChoicePrompt {
  /// Registry name of the question tool the app exposes on the control socket.
  public static let toolName = "agent.ask_user"

  /// The same tool as provider CLIs address it after MCP namespacing and sanitization.
  public static let mcpToolName = "mcp__otto__agent_ask_user"

  /// Questions wait on a human, same as approvals.
  public static let responseTimeoutMilliseconds: Int32 = 3_600_000
}
