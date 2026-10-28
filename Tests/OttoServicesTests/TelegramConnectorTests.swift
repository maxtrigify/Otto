import Foundation
import OttoServices
import Testing

@Suite("Telegram connector command and safety rules")
struct TelegramConnectorTests {
  @Test("Bot commands route to saved Otto bots without granting approval")
  func commands() {
    #expect(TelegramCommand.parse("/start") == .help)
    #expect(TelegramCommand.parse("/help") == .help)
    #expect(TelegramCommand.parse("/bots") == .bots)
    #expect(TelegramCommand.parse("/use @Engineer") == .use("@Engineer"))
    #expect(
      TelegramCommand.parse("/bot @Engineer please review") == .send("@Engineer", "please review"))
    #expect(TelegramCommand.parse("Hi there") == .message("Hi there"))
    #expect(TelegramCommand.parse("/pair code123") == .pair("code123"))
    #expect(TelegramCommand.parse("/approve") == nil)
    #expect(TelegramCommand.parse("/bot") == nil)
    #expect(TelegramCommand.parse("") == nil)
    #expect(TelegramCommand.parse(String(repeating: "X", count: 4_001)) == nil)
  }

  @Test("Only direct, human, self-addressed Telegram messages may be processed")
  func privateHumanOnly() throws {
    let privateMessage = """
      {"message_id":1,"chat":{"id":123,"type":"private"},
       "from":{"id":123,"is_bot":false},"text":"/bots"}
      """
    let decoder = JSONDecoder()
    let valid = try decoder.decode(TelegramIncomingMessage.self, from: Data(privateMessage.utf8))
    #expect(valid.isPrivateHuman)
    let groupMessage = privateMessage.replacingOccurrences(of: "private", with: "group")
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(groupMessage.utf8)
      ).isPrivateHuman)
    let spoofed = privateMessage.replacingOccurrences(
      of: #""id":123,"is_bot":false"#,
      with: #""id":999,"is_bot":false"#)
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(spoofed.utf8)
      ).isPrivateHuman)
    let automated = privateMessage.replacingOccurrences(of: "false", with: "true")
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(automated.utf8)
      ).isPrivateHuman)
  }

  @Test("Reject malformed BotFather tokens before any network request")
  func tokenValidation() {
    for value in ["", "123", "bot-invalid", "1234:too-short", "abc:token", "12345:bad/path/secret"]
    {
      #expect(throws: TelegramConnectionError.self) {
        _ = try TelegramBotTransport(token: value)
      }
    }
    #expect(throws: Never.self) {
      _ = try TelegramBotTransport(token: "123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567")
    }
  }
}
