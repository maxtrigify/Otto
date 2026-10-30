import Combine
import CryptoKit
import Foundation
import OttoModels
import OttoRuntime
import OttoSecurity

// Telegram's token is part of its mandated Bot API URL. Never log the full URL,
// any URLSession error (which can contain it), or the raw response body.
public struct TelegramIncomingMessage: Codable, Sendable {
  public struct Peer: Codable, Sendable {
    public let id: Int64
    public let type: String?
  }
  public struct Sender: Codable, Sendable {
    public let id: Int64
    public let isBot: Bool?
    enum CodingKeys: String, CodingKey {
      case id
      case isBot = "is_bot"
    }
  }
  /// A voice note or audio file. Only its Bot API handle is kept; Otto downloads the bytes
  /// once the sender is known to be paired.
  public struct Audio: Codable, Sendable, Equatable {
    public let fileID: String
    public let duration: Int?
    public let fileSize: Int?
    enum CodingKeys: String, CodingKey {
      case fileID = "file_id"
      case duration
      case fileSize = "file_size"
    }
  }
  public let messageID: Int64
  public let chat: Peer
  public let from: Sender?
  public let senderChat: Peer?
  public let text: String?
  public let caption: String?
  public let voice: Audio?
  public let audio: Audio?
  enum CodingKeys: String, CodingKey {
    case messageID = "message_id"
    case chat, from, text, caption, voice, audio
    case senderChat = "sender_chat"
  }

  /// The recording to transcribe when the message has no text of its own.
  public var recording: Audio? { text == nil ? voice ?? audio : nil }

  public var isPrivateHuman: Bool {
    chat.type == "private" && from?.id == chat.id && from?.isBot == false
  }

  public var isGroupHuman: Bool {
    (chat.type == "group" || chat.type == "supergroup") && chat.id < 0
      && from?.isBot == false && senderChat == nil && from?.id != nil
  }

  public func isAuthorized(
    privateChatID: Int64?, groupChatID: Int64?, groupSenderID: Int64?
  ) -> Bool {
    if isPrivateHuman { return privateChatID != nil && privateChatID == chat.id }
    if isGroupHuman {
      return groupChatID != nil && groupChatID == chat.id
        && groupSenderID != nil && groupSenderID == from?.id
    }
    return false
  }
}

public struct TelegramUpdate: Codable, Sendable {
  public let updateID: Int64
  public let message: TelegramIncomingMessage?
  public let callbackQuery: TelegramCallbackQuery?
  enum CodingKeys: String, CodingKey {
    case updateID = "update_id"
    case message
    case callbackQuery = "callback_query"
  }
}

/// A tap on one of Otto's inline buttons, such as Approve under a tool approval.
public struct TelegramCallbackQuery: Codable, Sendable {
  public struct Origin: Codable, Sendable {
    public let messageID: Int64
    public let chat: TelegramIncomingMessage.Peer
    enum CodingKeys: String, CodingKey {
      case messageID = "message_id"
      case chat
    }
  }
  public let id: String
  public let from: TelegramIncomingMessage.Sender
  public let message: Origin?
  public let data: String?
}

/// Inline-button answers to a tool approval. The callback data names a short random token
/// rather than the request itself; the token maps to one request's ID and nonce on the Mac, is
/// accepted only from the paired person in the chat it was sent to, and works once.
public enum TelegramApprovalAnswer: Equatable, Sendable {
  case approve(String)
  case deny(String)

  public static func parse(_ data: String?) -> Self? {
    guard let data, data.count <= 64 else { return nil }
    let parts = data.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, parts[1].count == 32,
      parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { return nil }
    switch parts[0] {
    case "ok": return .approve(parts[1])
    case "no": return .deny(parts[1])
    default: return nil
    }
  }

  public var token: String {
    switch self {
    case .approve(let token), .deny(let token): token
    }
  }

  /// 16 bytes from the system's cryptographic generator, as 32 lowercase hex digits.
  public static func makeToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<16).map { _ in
      String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
    }.joined()
  }
}

public enum TelegramCommand: Equatable, Sendable {
  case help, bots
  case use(String)
  case send(String, String)
  case message(String)
  case pair(String)

  public static func parse(_ raw: String, addressedTo botUsername: String? = nil)
    -> TelegramCommand?
  {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.count <= 4_000 else { return nil }
    let split = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    let address = String(split[0]).split(separator: "@", maxSplits: 1)
    if address.count == 2 {
      guard let botUsername, address[1].caseInsensitiveCompare(botUsername) == .orderedSame
      else { return nil }
    }
    let first = String(address[0]).lowercased()
    let argument =
      split.count > 1 ? String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    switch first {
    case "/start", "/help": return .help
    case "/bots": return .bots
    case "/use": return argument.isEmpty ? nil : .use(argument)
    case "/pair": return argument.isEmpty ? nil : .pair(argument)
    case "/bot":
      let values = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      guard values.count == 2 else { return nil }
      return .send(String(values[0]), String(values[1]))
    default: return text.hasPrefix("/") ? nil : .message(text)
    }
  }
}

public enum TelegramConnectionError: Error, LocalizedError {
  case invalidToken, unavailable, notReady
  public var errorDescription: String? {
    switch self {
    case .invalidToken: "Enter a Telegram BotFather token in the format 123456:secret."
    case .unavailable:
      "Telegram Bot API unavailable. Check the bot token, network and webhook settings."
    case .notReady: "Otto and the selected bot must be running before sending messages."
    }
  }
}

private final class TelegramNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public actor TelegramBotTransport {
  private let token: String
  private let session: URLSession
  private let redirects = TelegramNoRedirects()

  public init(token: String, session: URLSession = .shared) throws {
    let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      candidate.range(
        of: #"^[0-9]{5,20}:[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil
    else { throw TelegramConnectionError.invalidToken }
    self.token = candidate
    self.session = session
  }

  private struct Envelope<Value: Decodable>: Decodable {
    let ok: Bool
    let result: Value?
  }

  private func call<Value: Decodable>(
    _ method: String, arguments: [String: Any]
  ) async throws -> Value {
    // The method is a fixed call site, not a user-supplied path or URL.
    let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)")!
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: arguments)
    // No redirects to other domains with a token-bearing request.
    do {
      let (data, response) = try await session.data(for: request, delegate: redirects)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        data.count < 4_000_000,
        let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data),
        envelope.ok, let result = envelope.result
      else { throw TelegramConnectionError.unavailable }
      return result
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw TelegramConnectionError.unavailable
    }
  }

  public func verify() async throws -> String {
    struct Bot: Decodable { let username: String? }
    let bot: Bot = try await call("getMe", arguments: [:])
    return bot.username ?? "Telegram bot"
  }

  public func updates(after offset: Int64) async throws -> [TelegramUpdate] {
    try await call(
      "getUpdates",
      arguments: [
        "offset": offset, "limit": 15, "timeout": 12,
        "allowed_updates": ["message", "callback_query"],
      ])
  }

  private struct Receipt: Decodable {
    let messageID: Int64
    enum CodingKeys: String, CodingKey { case messageID = "message_id" }
  }

  /// Sends one message with a row of inline buttons, each a title and its callback data.
  @discardableResult
  public func send(
    _ message: String, to chatID: Int64, buttons: [(title: String, data: String)]
  ) async throws -> Int64 {
    let receipt: Receipt = try await call(
      "sendMessage",
      arguments: [
        "chat_id": chatID, "text": String(message.prefix(3_500)),
        "disable_web_page_preview": true,
        "reply_markup": [
          "inline_keyboard": [buttons.map { ["text": $0.title, "callback_data": $0.data] }]
        ],
      ])
    return receipt.messageID
  }

  /// Replaces a message's text and removes its buttons, so an answered approval cannot be
  /// tapped again.
  public func edit(_ messageID: Int64, in chatID: Int64, text: String) async throws {
    let _: Receipt = try await call(
      "editMessageText",
      arguments: [
        "chat_id": chatID, "message_id": messageID, "text": String(text.prefix(3_500)),
        "disable_web_page_preview": true,
      ])
  }

  /// Stops the button's loading spinner and briefly shows `text`.
  public func answerCallback(_ id: String, text: String) async throws {
    let _: Bool = try await call(
      "answerCallbackQuery", arguments: ["callback_query_id": id, "text": text])
  }

  /// Downloads a file the bot received into a private temporary folder. The caller removes it.
  public func download(fileID: String, maxBytes: Int) async throws -> URL {
    struct File: Decodable {
      let filePath: String?
      let fileSize: Int?
      enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case fileSize = "file_size"
      }
    }
    let file: File = try await call("getFile", arguments: ["file_id": fileID])
    guard let path = file.filePath, (file.fileSize ?? 0) <= maxBytes,
      !path.contains(".."), !path.hasPrefix("/"),
      path.allSatisfy({ $0.isLetter || $0.isNumber || "/._-".contains($0) }),
      let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(path)")
    else { throw TelegramConnectionError.unavailable }
    do {
      let (data, response) = try await session.data(
        for: URLRequest(url: url, timeoutInterval: 60), delegate: redirects)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        !data.isEmpty, data.count <= maxBytes
      else { throw TelegramConnectionError.unavailable }
      let directory = FileManager.default.temporaryDirectory
        .appending(path: "otto-telegram-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let ext = (path as NSString).pathExtension
      let destination = directory.appending(path: "recording.\(ext.isEmpty ? "oga" : ext)")
      try data.write(to: destination, options: .atomic)
      return destination
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // URLSession errors can carry the token-bearing URL; never pass them on.
      throw TelegramConnectionError.unavailable
    }
  }

  public func send(_ message: String, to chatID: Int64) async throws {
    let characters = Array(message)
    for chunk in stride(from: 0, to: characters.count, by: 3_500) {
      let part = String(characters[chunk..<min(chunk + 3_500, characters.count)])
      let _: Receipt = try await call(
        "sendMessage",
        arguments: [
          "chat_id": chatID, "text": part, "disable_web_page_preview": true,
        ])
    }
  }
}

@MainActor
public final class TelegramConnector: ObservableObject {
  @Published public private(set) var status = "Not connected"
  @Published public private(set) var username: String?
  @Published public private(set) var pairingCode: String?
  @Published public private(set) var pendingChatID: Int64?
  @Published public private(set) var approvedChatID: Int64?
  @Published public private(set) var approvedGroupID: Int64?
  @Published public private(set) var approvedGroupSenderID: Int64?
  @Published public private(set) var pendingGroupID: Int64?
  @Published public private(set) var pendingGroupSenderID: Int64?
  @Published public private(set) var groupPairingCode: String?
  /// Off by default: the Mac owner opts in to answering tool approvals from the paired chat.
  @Published public private(set) var approvalsFromTelegram: Bool
  /// Set by the app: transcribes a voice note on this Mac. Nil leaves voice notes unsupported.
  public var transcribeRecording: (@Sendable (URL) async throws -> String)?

  private weak var services: ApplicationServices?
  private let secrets: any SecretStore
  private let defaults: UserDefaults
  private let prefix: String
  private var transport: TelegramBotTransport?
  private var pollTask: Task<Void, Never>?
  private var offset: Int64
  private var pendingSenderID: Int64?
  private var activeBotByChatID: [Int64: UUID] = [:]
  private var pairingExpiry: Date?
  private var groupPairingExpiry: Date?
  private let credentialKey: String
  private var pendingApprovals: [String: PendingApproval] = [:]
  /// Work for one message that outlives its poll, such as following a run or transcribing a
  /// voice note. Cancelled on stop, disconnect and before a new token connects.
  private var messageTasks: [UUID: Task<Void, Never>] = [:]

  /// One approval sent to Telegram, kept until it is answered, expires or the run moves on.
  private struct PendingApproval {
    let agentID: UUID
    let requestID: UUID
    let nonce: String
    let chat: Int64
    let messageID: Int64
    let text: String
    let expires: Date
  }

  static let pollingInterrupted = "Telegram polling interrupted. Retrying connection."
  /// Voice notes longer than this are not transcribed.
  static let maxRecordingSeconds = 300

  /// Account and credential approvals stay in Otto on the Mac: a website-account click may
  /// send, buy, delete or change security settings, and connecting a website grants a bot a
  /// signed-in account. Everything else may be answered here once the owner allows it.
  public nonisolated static func isAnswerableOnTelegram(_ pending: AgentPendingPermission) -> Bool {
    !WebsiteAccountTool.approvals.contains(pending.toolName)
  }

  public init(
    services: ApplicationServices,
    secrets: any SecretStore = makeKeychainSecretStore(service: OttoSecretService.messaging),
    defaults: UserDefaults = .standard
  ) {
    self.services = services
    self.secrets = secrets
    self.defaults = defaults
    let workspaceHash = SHA256.hash(data: Data(services.workspacePath.utf8))
      .map { String(format: "%02x", $0) }.joined().prefix(24)
    self.prefix = "otto.telegram.\(workspaceHash)"
    self.credentialKey = "telegram.bot-token.\(workspaceHash)"
    self.offset = max(0, Int64(defaults.integer(forKey: "\(prefix).offset")))
    let savedChat = defaults.object(forKey: "\(prefix).chat") as? NSNumber
    self.approvedChatID = savedChat?.int64Value
    self.approvedGroupID = (defaults.object(forKey: "\(prefix).group") as? NSNumber)?.int64Value
    self.approvedGroupSenderID =
      (defaults.object(forKey: "\(prefix).group.sender") as? NSNumber)?.int64Value
    self.approvalsFromTelegram = defaults.bool(forKey: "\(prefix).approvals")
    if let legacy = defaults.string(forKey: "\(prefix).bot").flatMap(UUID.init(uuidString:)) {
      // Before multi-select, the Mac owner chose one Otto bot. Carry that choice over once.
      if services.connectorAccess.bots(for: .telegram).isEmpty {
        try? services.connectorAccess.setAllowed(true, profileID: legacy, for: .telegram)
      }
      defaults.removeObject(forKey: "\(prefix).bot")
    }
  }

  public var bots: [AgentProfile] {
    (services?.agentProfiles.activeProfiles ?? []).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private var noBotsMessage: String {
    "No Otto bot is allowed on Telegram. Allow one on the Mac in Connectors → Telegram."
  }

  /// Otto bots this Telegram connection may reach. The Mac owner grants them in
  /// Connectors → Telegram; chat messages can only pick among these.
  public var allowedBots: [AgentProfile] {
    guard let access = services?.connectorAccess else { return [] }
    return bots.filter { access.canUse(.telegram, profileID: $0.id) }
  }

  /// The bot a chat is talking to. Chosen with /use; defaults to the first allowed bot.
  private func activeBot(for chat: Int64) -> AgentProfile? {
    let allowed = allowedBots
    if let id = activeBotByChatID[chat], let bot = allowed.first(where: { $0.id == id }) {
      return bot
    }
    return allowed.first
  }

  private func allowedBot(matching handle: String) -> AgentProfile? {
    let wanted = handle.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).lowercased()
    return allowedBots.first { $0.handle.lowercased() == wanted }
  }

  public func setApprovalsFromTelegram(_ enabled: Bool) {
    approvalsFromTelegram = enabled
    defaults.set(enabled, forKey: "\(prefix).approvals")
    if !enabled { pendingApprovals = [:] }
  }

  /// The one paired person, in the chat they paired: the private chat, or the approved group's
  /// pairing member. Nobody else's taps or recordings are acted on.
  private func isPairedPerson(_ senderID: Int64?, in chat: Int64) -> Bool {
    guard let senderID else { return false }
    if let approvedChatID, chat == approvedChatID { return senderID == approvedChatID }
    if let approvedGroupID, chat == approvedGroupID { return senderID == approvedGroupSenderID }
    return false
  }

  public func connect(token: String) async {
    guard pollTask == nil else {
      status = "Disconnect before replacing the token."
      return
    }
    do {
      let client = try TelegramBotTransport(token: token)
      let name = try await client.verify()
      try await secrets.set(
        token.trimmingCharacters(in: .whitespacesAndNewlines), for: credentialKey)
      // Nothing begun under the previous token may answer through the new one.
      cancelMessageTasks()
      transport = client
      username = name
      status = "Connected to @\(name)"
      if approvedChatID == nil { issuePairingCode() }
      startPolling()
    } catch {
      status = "Could not connect. Check the Telegram bot token and network."
    }
  }

  public func reconnect() async {
    guard pollTask == nil else { return }
    do {
      guard let token = try await secrets.value(for: credentialKey) else { return }
      let client = try TelegramBotTransport(token: token)
      username = try await client.verify()
      transport = client
      status = "Connected to @\(username ?? "bot")"
      if approvedChatID == nil { issuePairingCode() }
      startPolling()
    } catch {
      status = "Telegram unavailable. Check the token, network or existing webhook."
    }
  }

  public func start() {
    if pollTask == nil { Task { await reconnect() } }
  }

  public func stop() {
    pollTask?.cancel()
    pollTask = nil
    cancelMessageTasks()
    transport = nil
    username = nil
  }

  public func disconnect() async {
    stop()
    do {
      try await secrets.delete(credentialKey)
      defaults.removeObject(forKey: "\(prefix).chat")
      defaults.removeObject(forKey: "\(prefix).group")
      defaults.removeObject(forKey: "\(prefix).group.sender")
      defaults.removeObject(forKey: "\(prefix).bot")
      defaults.removeObject(forKey: "\(prefix).offset")
      defaults.removeObject(forKey: "\(prefix).approvals")
      approvalsFromTelegram = false
      pendingApprovals = [:]
      approvedChatID = nil
      approvedGroupID = nil
      approvedGroupSenderID = nil
      pendingGroupID = nil
      pendingGroupSenderID = nil
      groupPairingCode = nil
      activeBotByChatID = [:]
      pendingChatID = nil
      pendingSenderID = nil
      pairingCode = nil
      offset = 0
      status = "Disconnected. Revoke the token in BotFather if it may be exposed."
    } catch {
      status = "Stopped. Keychain removal failed; retry Disconnect."
    }
  }

  public func issuePairingCode() {
    pairingCode = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    pairingExpiry = Date().addingTimeInterval(600)
    pendingChatID = nil
    pendingSenderID = nil
  }

  public func issueGroupPairingCode() {
    groupPairingCode = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    groupPairingExpiry = Date().addingTimeInterval(600)
    pendingGroupID = nil
    pendingGroupSenderID = nil
  }

  public func approvePendingGroup() {
    guard let group = pendingGroupID, group < 0, let sender = pendingGroupSenderID,
      sender > 0
    else { return }
    defaults.set(NSNumber(value: group), forKey: "\(prefix).group")
    defaults.set(NSNumber(value: sender), forKey: "\(prefix).group.sender")
    approvedGroupID = group
    approvedGroupSenderID = sender
    pendingGroupID = nil
    pendingGroupSenderID = nil
    groupPairingCode = nil
    groupPairingExpiry = nil
    status = "Telegram group approved. Only the pairing member can command Otto."
    Task {
      try? await transport?.send(
        "Group approved. Messages from the pairing member can reach the Otto bot selected on your Mac. Use /bots to check the selection.",
        to: group)
    }
  }

  public func revokeGroup() {
    defaults.removeObject(forKey: "\(prefix).group")
    defaults.removeObject(forKey: "\(prefix).group.sender")
    approvedGroupID = nil
    approvedGroupSenderID = nil
    pendingGroupID = nil
    pendingGroupSenderID = nil
    groupPairingCode = nil
    groupPairingExpiry = nil
  }

  public func approvePendingChat() {
    guard let chat = pendingChatID, pendingSenderID == chat else { return }
    defaults.set(NSNumber(value: chat), forKey: "\(prefix).chat")
    approvedChatID = chat
    pendingChatID = nil
    pendingSenderID = nil
    pairingCode = nil
    pairingExpiry = nil
    status = "Paired to your private Telegram chat."
    Task { try? await transport?.send("Paired with Otto. Send /bots to select a bot.", to: chat) }
  }

  private func cancelMessageTasks() {
    for task in messageTasks.values { task.cancel() }
    messageTasks = [:]
  }

  /// Runs `work` on its own task so polling continues meanwhile: an Approve tap or the next
  /// message must not wait behind it.
  private func track(_ work: @escaping @MainActor (TelegramConnector) async -> Void) {
    let id = UUID()
    messageTasks[id] = Task { [weak self] in
      guard let self else { return }
      await work(self)
      self.messageTasks[id] = nil
    }
  }

  private func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let client = self.transport else { return }
        do {
          let updates = try await client.updates(after: self.offset)
          // A poll that succeeds after an interruption clears the stale warning.
          if self.status == Self.pollingInterrupted {
            self.status = "Connected to @\(self.username ?? "bot")"
          }
          for update in updates.sorted(by: { $0.updateID < $1.updateID }) {
            guard !Task.isCancelled else { return }
            if update.updateID < self.offset { continue }
            // Save before dispatch: after a crash an update must not run twice.
            self.offset = update.updateID + 1
            self.defaults.set(NSNumber(value: self.offset), forKey: "\(self.prefix).offset")
            if let message = update.message { await self.handle(message, client: client) }
            if let tap = update.callbackQuery { await self.handle(tap, client: client) }
          }
        } catch {
          if !Task.isCancelled {
            self.status = Self.pollingInterrupted
          }
          try? await Task.sleep(for: .seconds(5))
        }
      }
    }
  }

  private func handle(_ message: TelegramIncomingMessage, client: TelegramBotTransport) async {
    if let recording = message.recording {
      await handleRecording(recording, in: message, client: client)
      return
    }
    guard let text = message.text,
      let command = TelegramCommand.parse(text, addressedTo: username),
      message.isPrivateHuman || message.isGroupHuman
    else { return }
    let chat = message.chat.id
    if message.isGroupHuman {
      if message.isAuthorized(
        privateChatID: approvedChatID, groupChatID: approvedGroupID,
        groupSenderID: approvedGroupSenderID)
      {
        // Explicitly approved group and one named Telegram user only.
      } else if approvedGroupID == nil, case .pair(let code) = command,
        let groupPairingCode, code == groupPairingCode,
        (groupPairingExpiry ?? .distantPast) > .now
      {
        pendingGroupID = chat
        pendingGroupSenderID = message.from?.id
        status = "Telegram group requests approval in Otto Connectors."
        try? await client.send(
          "Group pairing requested. Approve the group and sender in Otto on your Mac.", to: chat)
        return
      } else {
        return
      }
    } else if approvedChatID != chat {
      guard case .pair(let code) = command,
        approvedChatID == nil, let pairingCode, code == pairingCode,
        (pairingExpiry ?? .distantPast) > .now
      else { return }
      pendingChatID = chat
      pendingSenderID = message.from?.id
      status = "Pairing request received. Approve this Telegram chat on your Mac."
      try? await client.send(
        "Pairing requested. Approve the chat in Otto → Settings → Connectors.", to: chat)
      return
    }
    switch command {
    case .help:
      try? await client.send(
        "Otto commands:\n/bots — list the Otto bots you can reach\n/use @handle — talk to that bot in this chat\n/bot @handle message — ask one bot once\nPlain text and voice notes go to this chat's bot. The Mac owner decides which bots are allowed. "
          + (approvalsFromTelegram
            ? "Tool approvals arrive here with Approve and Deny buttons."
            : "Tool approvals stay in Otto on the Mac unless the owner allows them here."),
        to: chat)
    case .bots:
      let allowed = allowedBots
      guard !allowed.isEmpty else {
        try? await client.send(noBotsMessage, to: chat)
        return
      }
      let current = activeBot(for: chat)?.id
      let lines = allowed.map { bot in
        "\(bot.id == current ? "•" : " ") @\(bot.handle) — \(bot.name)"
      }
      try? await client.send("Otto bots you can reach:\n" + lines.joined(separator: "\n"), to: chat)
    case .use(let handle):
      guard let bot = allowedBot(matching: handle) else {
        try? await client.send(
          "No allowed Otto bot matches \(handle). Send /bots to see them.", to: chat)
        return
      }
      activeBotByChatID[chat] = bot.id
      try? await client.send("This chat now talks to @\(bot.handle).", to: chat)
    case .send(let handle, let text):
      guard let bot = allowedBot(matching: handle) else {
        try? await client.send(
          "No allowed Otto bot matches \(handle). Send /bots to see them.", to: chat)
        return
      }
      await sendPrompt(text, to: bot, client: client, chat: chat)
    case .message(let prompt):
      guard let bot = activeBot(for: chat) else {
        try? await client.send(noBotsMessage, to: chat)
        return
      }
      await sendPrompt(prompt, to: bot, client: client, chat: chat)
    case .pair:
      try? await client.send("Already paired. Use /bots to choose a bot.", to: chat)
    }
  }

  private func sendPrompt(
    _ prompt: String, to bot: AgentProfile, client: TelegramBotTransport, chat: Int64
  ) async {
    guard let services, services.isOnline else {
      try? await client.send("Otto is not ready on your Mac.", to: chat)
      return
    }
    // Telegram content is untrusted input. It does not grant permission or approve
    // a pending desktop action; those must still go through Otto's UI.
    let previousNodeID = services.botRoster().first { $0.profile.id == bot.id }?.nodeID
    let previousSnapshot = previousNodeID.flatMap { services.fleetStore.snapshot(for: $0) }
    let previousRunID = previousSnapshot?.runID
    let previousAssistantIDs = Set(
      previousSnapshot?.transcript.filter { $0.role == .assistant }.map(\.id) ?? [])
    do {
      let opened = try await services.controlSendPrompt(
        to: bot.id.uuidString, prompt: prompt)
      try? await client.send("Sent to @\(bot.handle). Working…", to: chat)
      track { connector in
        await connector.follow(
          agentID: opened.agentID, bot: bot, previousRunID: previousRunID,
          previousAssistantIDs: previousAssistantIDs, client: client, chat: chat)
      }
    } catch {
      try? await client.send(
        "Could not dispatch the message. Open Otto on your Mac to check the bot.", to: chat)
    }
  }

  /// Relays the opened agent's answer, never another bot's. While it waits for a tool approval,
  /// the approval is offered here when the owner allowed that, and the wait is extended.
  private func follow(
    agentID: UUID, bot: AgentProfile, previousRunID: UUID?, previousAssistantIDs: Set<UUID>,
    client: TelegramBotTransport, chat: Int64
  ) async {
    guard let services else { return }
    var deadline = Date.now.addingTimeInterval(120)
    var offeredRequestID: UUID?
    var deferredRequestID: UUID?
    while Date.now < deadline {
      try? await Task.sleep(for: .seconds(1))
      if Task.isCancelled { return }
      guard let snapshot = services.fleetStore.snapshot(for: agentID) else { continue }
      let newAnswer = snapshot.transcript.reversed().first {
        $0.role == .assistant && $0.kind == .text && !$0.text.isEmpty
          && !previousAssistantIDs.contains($0.id)
      }?.text
      guard snapshot.runID != previousRunID || newAnswer != nil else { continue }
      if snapshot.state == .waitingPermission {
        guard approvalsFromTelegram,
          let pending = await services.supervisor.pendingPermission(agentID: agentID)
        else {
          try? await client.send(
            "@\(bot.handle) needs your approval in the Otto Mac app.", to: chat)
          return
        }
        guard Self.isAnswerableOnTelegram(pending) else {
          // No buttons: keep following so the answer still arrives once it is approved on the Mac.
          if pending.requestID != deferredRequestID {
            deferredRequestID = pending.requestID
            try? await client.send(
              "@\(bot.handle) needs a website account approval. Approve it in Otto on your Mac.",
              to: chat)
          }
          deadline = max(deadline, Date.now.addingTimeInterval(600))
          continue
        }
        if pending.requestID != offeredRequestID {
          offeredRequestID = pending.requestID
          await offerApproval(pending, agentID: agentID, bot: bot, client: client, chat: chat)
        }
        // A person on their phone may take a while to answer.
        deadline = max(deadline, Date.now.addingTimeInterval(600))
        continue
      }
      if snapshot.state == .waitingUser {
        try? await client.send(
          "@\(bot.handle) has a question for you in the Otto Mac app.", to: chat)
        return
      }
      if [.done, .idle, .failed, .interrupted, .stopped].contains(snapshot.state) {
        let answer = newAnswer ?? snapshot.result
        try? await client.send(
          answer?.isEmpty == false
            ? answer! : "Bot finished. Open Otto on your Mac to review the result.",
          to: chat)
        return
      }
    }
    try? await client.send(
      "Still working. Check this bot in Otto on your Mac for the result.", to: chat)
  }

  private func offerApproval(
    _ pending: AgentPendingPermission, agentID: UUID, bot: AgentProfile,
    client: TelegramBotTransport, chat: Int64
  ) async {
    pendingApprovals = pendingApprovals.filter { $0.value.expires > .now }
    let token = TelegramApprovalAnswer.makeToken()
    let text = "@\(bot.handle) asks for approval:\n\n\(pending.reason)"
    guard
      let messageID = try? await client.send(
        text, to: chat,
        buttons: [("Approve", "ok:\(token)"), ("Deny", "no:\(token)")])
    else { return }
    pendingApprovals[token] = PendingApproval(
      agentID: agentID, requestID: pending.requestID, nonce: pending.nonce, chat: chat,
      messageID: messageID, text: text, expires: Date.now.addingTimeInterval(3_600))
  }

  /// An Approve or Deny tap. Telegram content is untrusted: the tap counts only from the paired
  /// person, in the chat the approval was sent to, for a request that is still the one waiting.
  private func handle(_ tap: TelegramCallbackQuery, client: TelegramBotTransport) async {
    guard let answer = TelegramApprovalAnswer.parse(tap.data),
      let pending = pendingApprovals[answer.token], let origin = tap.message,
      origin.chat.id == pending.chat, origin.messageID == pending.messageID,
      tap.from.isBot != true, isPairedPerson(tap.from.id, in: origin.chat.id)
    else {
      try? await client.answerCallback(tap.id, text: "This approval is no longer available.")
      return
    }
    pendingApprovals[answer.token] = nil
    guard approvalsFromTelegram, pending.expires > .now, let services else {
      try? await client.answerCallback(tap.id, text: "Approve this in Otto on your Mac.")
      try? await client.edit(
        pending.messageID, in: pending.chat, text: pending.text + "\n\nExpired. Answer on the Mac.")
      return
    }
    let approved = answer == .approve(answer.token)
    do {
      try await services.supervisor.resolvePermission(
        agentID: pending.agentID, requestID: pending.requestID, nonce: pending.nonce,
        approved: approved)
      try? await client.answerCallback(tap.id, text: approved ? "Approved" : "Denied")
      try? await client.edit(
        pending.messageID, in: pending.chat,
        text: pending.text + (approved ? "\n\n✅ Approved on Telegram" : "\n\n❌ Denied on Telegram"))
    } catch {
      try? await client.answerCallback(tap.id, text: "Already answered.")
      try? await client.edit(
        pending.messageID, in: pending.chat,
        text: pending.text + "\n\nAlready answered, or the run moved on.")
    }
  }

  /// A voice note or audio file from the paired person becomes a message to this chat's bot.
  /// Nothing is downloaded for anyone else.
  private func handleRecording(
    _ recording: TelegramIncomingMessage.Audio, in message: TelegramIncomingMessage,
    client: TelegramBotTransport
  ) async {
    guard message.isPrivateHuman || message.isGroupHuman,
      message.isAuthorized(
        privateChatID: approvedChatID, groupChatID: approvedGroupID,
        groupSenderID: approvedGroupSenderID)
    else { return }
    let chat = message.chat.id
    guard let transcribeRecording else {
      try? await client.send(
        "Voice notes need on-device speech on the Mac. Send text instead.", to: chat)
      return
    }
    guard let bot = activeBot(for: chat) else {
      try? await client.send(noBotsMessage, to: chat)
      return
    }
    guard (recording.duration ?? 0) <= Self.maxRecordingSeconds,
      (recording.fileSize ?? 0) <= AudioRecordingLimits.maxBytes
    else {
      try? await client.send("Voice notes up to 5 minutes can be transcribed.", to: chat)
      return
    }
    let caption = message.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    // Downloading and transcribing can take minutes; polling must not wait for it.
    track { connector in
      let transcript: String
      do {
        let file = try await client.download(
          fileID: recording.fileID, maxBytes: AudioRecordingLimits.maxBytes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        transcript = try await transcribeRecording(file)
      } catch {
        guard !Task.isCancelled else { return }
        let detail = (error as? LocalizedError)?.errorDescription ?? "It could not be read."
        try? await client.send("Couldn't transcribe that voice note. \(detail)", to: chat)
        return
      }
      guard !Task.isCancelled else { return }
      try? await client.send("🎙️ Heard: “\(transcript)”", to: chat)
      await connector.sendPrompt(
        caption.isEmpty ? transcript : "\(caption)\n\n\(transcript)", to: bot, client: client,
        chat: chat)
    }
  }
}

/// Telegram's Bot API serves files up to 20 MB.
enum AudioRecordingLimits {
  static let maxBytes = 20_000_000
}
