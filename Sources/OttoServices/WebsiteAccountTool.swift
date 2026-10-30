import Foundation
import OttoTools

/// No credential parameter and no arbitrary script execution. Identity comes from host routing.
struct WebsiteAccountTool: OttoTool {
  /// The approvals this tool asks for. Both grant or use a signed-in website account, so they
  /// are answered in Otto on the Mac only, never from a phone.
  static let connectApproval = "Connect website"
  static let clickApproval = "Website account click"
  static let approvals: Set<String> = [connectApproval, clickApproval]

  static let definition = ToolDefinition(
    name: "browser.account",
    description:
      "Use an authorised website account in its private browser session. List accounts, request private human sign-in directly from chat (supply a URL for a new account; human approval is required), open a same-origin URL, inspect, type non-secret text, or click. Never send passwords or MFA codes to this tool. Use the returned revision and element ID. Clicks require human approval. Messaging requests deliver private sign-in and approval links directly to the paired conversation. request_login opens private sign-in on the originating surface and waits for completion, then continues the same task automatically. Never ask the user to configure Settings or send a continue message. The private session is separate from ordinary browser nodes; use this tool for all account actions.",
    inputSchema: .objectSchema(
      properties: [
        "action": .stringSchema(description: "list, request_login, open, inspect, type, or click"),
        "accountID": .stringSchema(description: "Account UUID returned by list"),
        "url": .stringSchema(description: "HTTPS URL on the account's exact origin"),
        "revision": .stringSchema(description: "Revision returned by inspect"),
        "elementID": .stringSchema(description: "Element ID returned by inspect"),
        "text": .stringSchema(
          description: "Non-secret text only; private sign-in uses native input"),
      ], required: ["action"]), outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead, .canvasWrite], riskLevel: .reversible)
  let handler: @Sendable (WebsiteAccountCommand, ToolContext) async throws -> WebsiteAccountResult
  func call(_ input: WebsiteAccountCommand, context: ToolContext) async throws
    -> WebsiteAccountResult
  {
    try await handler(input, context)
  }
}

extension ApplicationServices {
  func registerWebsiteAccountTools() async throws {
    try await registry.register(
      WebsiteAccountTool { [weak self] input, context in
        guard let self, let nodeID = context.sourceNodeID else { throw WebsiteAccountError.denied }
        return try await self.performWebsiteAccount(input, nodeID: nodeID)
      })
  }
  private func performWebsiteAccount(_ input: WebsiteAccountCommand, nodeID: UUID) async throws
    -> WebsiteAccountResult
  {
    guard let profileID = profileID(forNode: nodeID),
      let snapshot = try? await supervisor.snapshot(agentID: nodeID)
    else { throw WebsiteAccountError.denied }
    if ["request_login", "click"].contains(input.action),
      let job = messaging.privateJob(for: nodeID), let runID = snapshot.runID
    {
      return try await performPrivatePhoneWebsite(
        input, nodeID: nodeID,
        profileID: profileID, runID: runID, job: job)
    }
    var input = input
    if input.action == "request_login", input.accountID == nil {
      guard let url = input.url else { throw WebsiteAccountError.denied }
      let origin = try WebsiteAccountService.originForLogin(url)
      let available = try await websiteAccounts.perform(
        WebsiteAccountCommand(action: "list"), botID: profileID, runID: snapshot.runID ?? nodeID
      ).accounts.filter { $0.origin == origin }
      if available.count == 1 {
        input.accountID = available[0].id
      } else if available.isEmpty {
        let name =
          agentProfiles.activeProfiles.first(where: { $0.id == profileID })?.name ?? "This bot"
        let approved = try await supervisor.requestPermission(
          agentID: nodeID, toolName: WebsiteAccountTool.connectApproval,
          detail:
            "Allow \(name) to use \(origin) on this and future requests? Only this bot receives access. Sign-in opens privately; passwords never belong in chat. You can revoke access in Websites settings."
        )
        guard approved else { throw WebsiteAccountError.denied }
        input.accountID = try await websiteAccounts.create(
          origin: origin, bots: .selected([profileID]))
      } else {
        throw WebsiteAccountError.denied
      }
    }
    if input.action == "click" {
      // Conservative boundary: account actions can send, buy, delete, or change security.
      // Always use the existing one-shot human decision; do not infer consent from page text.
      let detail = try await websiteAccounts.clickApproval(
        input, botID: profileID, runID: snapshot.runID ?? nodeID)
      let approved = try await supervisor.requestPermission(
        agentID: nodeID, toolName: WebsiteAccountTool.clickApproval, detail: detail)
      guard approved else { throw WebsiteAccountError.denied }
    }
    let result = try await websiteAccounts.perform(
      input, botID: profileID, runID: snapshot.runID ?? nodeID)
    if input.action == "request_login", let id = input.accountID {
      return try await websiteAccounts.waitForLogin(
        accountID: id, botID: profileID, runID: snapshot.runID ?? nodeID)
    }
    return result
  }
}
