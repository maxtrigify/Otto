import Foundation
import OttoModels
import OttoRuntime
import OttoTools

struct SMTPSendInput: Codable, Sendable {
  var to: String
  var subject: String
  var body: String
}

/// Sends mail through the SMTP server the user configured under Connectors. Like gmail.send,
/// every send needs Otto's confirmation of the exact recipient, subject and body.
struct SMTPSendTool: OttoTool {
  typealias Input = SMTPSendInput
  typealias Output = JSONValue
  static let definition = ToolDefinition(
    name: "smtp.send",
    description:
      "Send a plain-text email through the SMTP account configured in Otto. Requires Otto confirmation of the exact recipient, subject and body. Never retry an uncertain send without checking with the user.",
    inputSchema: .objectSchema(
      properties: [
        "to": .stringSchema(description: "Recipient email address"),
        "subject": .stringSchema(description: "Complete subject"),
        "body": .stringSchema(description: "Complete plain-text message"),
      ], required: ["to", "subject", "body"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead], riskLevel: .consequential,
    requiresConfirmation: true, externalEffect: .sendOrPublish)
  let handler: @Sendable (SMTPSendInput, ToolContext) async throws -> JSONValue
  func call(_ input: SMTPSendInput, context: ToolContext) async throws -> JSONValue {
    try await handler(input, context)
  }
}

extension ApplicationServices {
  func registerSMTPTools() async throws {
    try await registry.register(
      SMTPSendTool { [weak self] input, context in
        guard let self else { throw AppConnectionError.unavailable }
        guard await self.sharedAppsProvider(context, writes: true) != nil else {
          throw AppConnectionError.unavailable
        }
        let subject = input.subject
        let body = input.body
        guard subject.utf8.count <= 998, body.utf8.count <= 200_000 else {
          throw ToolRegistryError.invalidInput("Subject or body is too long")
        }
        try await self.smtp.send(to: input.to, subject: subject, body: body)
        return .object(["sent": .bool(true), "to": .string(input.to)])
      },
      availability: { [weak self] context in
        guard let self, let provider = await self.sharedAppsProvider(context, writes: true)
        else { return false }
        return await self.smtp.isConfigured && SharedAppProviders.supported.contains(provider)
      })
  }
}
