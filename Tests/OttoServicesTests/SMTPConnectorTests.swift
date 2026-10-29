import Foundation
import OttoSecurity
import Testing

@testable import OttoServices

@Suite("SMTP connector")
struct SMTPConnectorTests {
  private func workspace() -> String {
    FileManager.default.temporaryDirectory.appending(path: "smtp-\(UUID().uuidString)").path
  }

  private let configuration = SMTPConfiguration(
    host: "smtp.example.com", port: 587, username: "bot@example.com",
    fromAddress: "bot@example.com", security: .startTLS)

  @Test("Message has CRLF headers, plain UTF-8 body and an encoded non-ASCII subject")
  func messageShape() throws {
    let text = try SMTPConnector.message(
      from: "bot@example.com", to: "amy@example.com", subject: "Café", body: "Hi\nthere",
      date: Date(timeIntervalSince1970: 0), messageID: "<id@example.com>")
    #expect(text.contains("To: amy@example.com\r\n"))
    #expect(text.contains("Subject: =?UTF-8?B?"))
    #expect(text.contains("Content-Type: text/plain; charset=UTF-8\r\n"))
    #expect(text.hasSuffix("\r\n\r\nHi\r\nthere\r\n"))
  }

  @Test("Line breaks in headers are rejected so callers cannot inject headers")
  func headerInjectionRejected() {
    #expect(throws: SMTPError.invalidField("To")) {
      try SMTPConnector.message(
        from: "bot@example.com", to: "amy@example.com\r\nBcc: spy@example.com",
        subject: "Hi", body: "x", date: .now, messageID: "<id>")
    }
    #expect(throws: SMTPError.invalidField("Subject")) {
      try SMTPConnector.message(
        from: "bot@example.com", to: "amy@example.com", subject: "Hi\nBcc: x", body: "x",
        date: .now, messageID: "<id>")
    }
  }

  @Test("Recipients must be bare addresses")
  func bareAddresses() {
    #expect(SMTPConnector.isBareAddress("amy@example.com"))
    #expect(!SMTPConnector.isBareAddress("Amy <amy@example.com>"))
    #expect(!SMTPConnector.isBareAddress("amy@example.com, bob@example.com"))
    #expect(!SMTPConnector.isBareAddress("@example.com"))
    #expect(!SMTPConnector.isBareAddress("amy"))
  }

  @Test("Server settings are validated before saving")
  func validation() {
    #expect(throws: SMTPError.invalidField("Port")) {
      try SMTPConnector.validate(
        SMTPConfiguration(
          host: "h", port: 0, username: "u", fromAddress: "f@example.com", security: .tls))
    }
    #expect(throws: SMTPError.invalidField("Host")) {
      try SMTPConnector.validate(
        SMTPConfiguration(
          host: "", port: 465, username: "u", fromAddress: "f@example.com", security: .tls))
    }
  }

  @Test("Save persists settings and the password, disconnect clears both")
  func saveAndDisconnect() async throws {
    let path = workspace()
    let secrets = InMemorySecretStore()
    let connector = SMTPConnector(workspacePath: path, secrets: secrets)
    #expect(await connector.isConfigured == false)
    try await connector.save(configuration, password: "s3cret")
    #expect(await connector.isConfigured)
    #expect(
      await SMTPConnector(workspacePath: path, secrets: secrets).configuration == configuration)
    try await connector.disconnect()
    #expect(await connector.isConfigured == false)
    #expect(await SMTPConnector(workspacePath: path, secrets: secrets).configuration == nil)
  }

  @Test("Passwords with line breaks are refused")
  func passwordWithNewline() async {
    let connector = SMTPConnector(workspacePath: workspace(), secrets: InMemorySecretStore())
    await #expect(throws: SMTPError.invalidField("Password")) {
      try await connector.save(configuration, password: "line\nbreak")
    }
  }

  @Test("Sending before setup reports not configured")
  func sendWithoutSetup() async {
    let connector = SMTPConnector(workspacePath: workspace(), secrets: InMemorySecretStore())
    await #expect(throws: SMTPError.notConfigured) {
      try await connector.send(to: "amy@example.com", subject: "Hi", body: "x")
    }
  }

  @Test("Server and sender must be plain values before they reach curl")
  func hostAndSenderValidation() {
    #expect(SMTPConnector.isHostName("smtp.example.com"))
    #expect(SMTPConnector.isHostName("192.168.1.10"))
    #expect(!SMTPConnector.isHostName("smtp.example.com/evil"))
    #expect(!SMTPConnector.isHostName("smtp example.com"))
    #expect(!SMTPConnector.isHostName("-smtp.example.com"))
    #expect(throws: SMTPError.invalidField("Host")) {
      try SMTPConnector.validate(
        SMTPConfiguration(
          host: "a.com/x", port: 465, username: "u", fromAddress: "f@example.com",
          security: .tls))
    }
    #expect(throws: SMTPError.invalidField("From address")) {
      try SMTPConnector.validate(
        SMTPConfiguration(
          host: "smtp.example.com", port: 465, username: "u", fromAddress: "Me <f@example.com>",
          security: .tls))
    }
  }
}
