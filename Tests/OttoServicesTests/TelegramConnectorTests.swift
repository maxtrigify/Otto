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
    #expect(TelegramCommand.parse("/bots@OttoDeskBot", addressedTo: "ottodeskbot") == .bots)
    #expect(TelegramCommand.parse("/bots@OtherBot", addressedTo: "ottodeskbot") == nil)
    #expect(TelegramCommand.parse("/approve") == nil)
    #expect(TelegramCommand.parse("/bot") == nil)
    #expect(TelegramCommand.parse("") == nil)
    #expect(TelegramCommand.parse(String(repeating: "X", count: 4_001)) == nil)
  }

  @Test("Only real human senders in private chats or groups may be considered for pairing")
  func privateAndGroupHumans() throws {
    let privateMessage = """
      {"message_id":1,"chat":{"id":123,"type":"private"},
       "from":{"id":123,"is_bot":false},"text":"/bots"}
      """
    let decoder = JSONDecoder()
    let valid = try decoder.decode(TelegramIncomingMessage.self, from: Data(privateMessage.utf8))
    #expect(valid.isPrivateHuman)
    #expect(!valid.isGroupHuman)
    let groupMessage =
      privateMessage
      .replacingOccurrences(of: "private", with: "supergroup")
      .replacingOccurrences(of: #""id":123,"type""#, with: #""id":-100123,"type""#)
    let groupValid = try decoder.decode(
      TelegramIncomingMessage.self, from: Data(groupMessage.utf8))
    #expect(groupValid.isGroupHuman)
    #expect(groupValid.isAuthorized(privateChatID: nil, groupChatID: -100123, groupSenderID: 123))
    #expect(!groupValid.isAuthorized(privateChatID: 123, groupChatID: -100123, groupSenderID: 999))
    #expect(!groupValid.isAuthorized(privateChatID: 123, groupChatID: -200, groupSenderID: 123))
    #expect(!groupValid.isAuthorized(privateChatID: 123, groupChatID: nil, groupSenderID: nil))
    #expect(valid.isAuthorized(privateChatID: 123, groupChatID: nil, groupSenderID: nil))
    #expect(!valid.isAuthorized(privateChatID: 999, groupChatID: -100123, groupSenderID: 123))
    #expect(
      !groupValid.isPrivateHuman)
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
    let botGroup = groupMessage.replacingOccurrences(of: "false", with: "true")
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(botGroup.utf8)
      ).isGroupHuman)
    let anonymousAdmin = groupMessage.replacingOccurrences(
      of: #""from":{"id":123,"is_bot":false}"#,
      with: #""from":{"id":123,"is_bot":false},"sender_chat":{"id":-100123,"type":"supergroup"}"#)
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(anonymousAdmin.utf8)
      ).isGroupHuman)
    let spoofedGroup = groupMessage.replacingOccurrences(
      of: #""type":"supergroup""#, with: #""type":"private""#)
    #expect(
      try !decoder.decode(
        TelegramIncomingMessage.self, from: Data(spoofedGroup.utf8)
      ).isGroupHuman)
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

  @Test("A voice note is read as a recording only when the message has no text")
  func voiceNotes() throws {
    let voice = """
      {"message_id":7,"chat":{"id":123,"type":"private"},"from":{"id":123,"is_bot":false},
       "voice":{"file_id":"AwACAgQ","file_unique_id":"x","duration":23,"mime_type":"audio/ogg",
       "file_size":41000},"caption":"for the release"}
      """
    let message = try JSONDecoder().decode(TelegramIncomingMessage.self, from: Data(voice.utf8))
    #expect(message.recording?.fileID == "AwACAgQ")
    #expect(message.recording?.duration == 23)
    #expect(message.caption == "for the release")
    let texted = voice.replacingOccurrences(of: #""caption""#, with: #""text""#)
    let withText = try JSONDecoder().decode(
      TelegramIncomingMessage.self, from: Data(texted.utf8))
    #expect(withText.recording == nil)
  }

  @Test("Approval taps carry a one-time token, never the request itself")
  func approvalButtons() throws {
    let token = TelegramApprovalAnswer.makeToken()
    #expect(token.count == 16)
    #expect(TelegramApprovalAnswer.parse("ok:\(token)") == .approve(token))
    #expect(TelegramApprovalAnswer.parse("no:\(token)") == .deny(token))
    #expect(TelegramApprovalAnswer.parse("ok:\(token.uppercased())") == nil)
    #expect(TelegramApprovalAnswer.parse("ok:short") == nil)
    #expect(TelegramApprovalAnswer.parse("yes:\(token)") == nil)
    #expect(TelegramApprovalAnswer.parse(nil) == nil)

    let update = """
      {"update_id":9,"callback_query":{"id":"cb1","from":{"id":123,"is_bot":false},
       "message":{"message_id":44,"chat":{"id":123,"type":"private"}},"data":"ok:\(token)"}}
      """
    let decoded = try JSONDecoder().decode(TelegramUpdate.self, from: Data(update.utf8))
    #expect(decoded.message == nil)
    #expect(decoded.callbackQuery?.from.id == 123)
    #expect(decoded.callbackQuery?.message?.messageID == 44)
    #expect(TelegramApprovalAnswer.parse(decoded.callbackQuery?.data) == .approve(token))
  }
}
