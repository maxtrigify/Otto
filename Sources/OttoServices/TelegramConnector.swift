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
  public let messageID: Int64
  public let chat: Peer
  public let from: Sender?
  public let senderChat: Peer?
  public let text: String?
  enum CodingKeys: String, CodingKey {
    case messageID = "message_id"
    case chat, from, text
    case senderChat = "sender_chat"
  }

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
  enum CodingKeys: String, CodingKey {
    case updateID = "update_id"
    case message
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
        "offset": offset, "limit": 15, "timeout": 12, "allowed_updates": ["message"],
      ])
  }

  public func send(_ message: String, to chatID: Int64) async throws {
    struct Receipt: Decodable {
      let messageID: Int64
      enum CodingKeys: String, CodingKey { case messageID = "message_id" }
    }
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
  @Published public private(set) var selectedBotID: UUID?

  private weak var services: ApplicationServices?
  private let secrets: any SecretStore
  private let defaults: UserDefaults
  private let prefix: String
  private var transport: TelegramBotTransport?
  private var pollTask: Task<Void, Never>?
  private var offset: Int64
  private var pendingSenderID: Int64?
  private var pairingExpiry: Date?
  private var groupPairingExpiry: Date?
  private let credentialKey: String

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
    self.selectedBotID = defaults.string(forKey: "\(prefix).bot").flatMap(UUID.init(uuidString:))
  }

  public var bots: [AgentProfile] {
    (services?.agentProfiles.activeProfiles ?? []).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  /// The Mac owner selects the sole bot exposed to Telegram. Chat commands
  /// cannot change this binding or access another Otto bot.
  public func selectBot(_ id: UUID?) {
    guard id == nil || bots.contains(where: { $0.id == id }) else { return }
    selectedBotID = id
    if let id {
      defaults.set(id.uuidString, forKey: "\(prefix).bot")
    } else {
      defaults.removeObject(forKey: "\(prefix).bot")
    }
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
      approvedChatID = nil
      approvedGroupID = nil
      approvedGroupSenderID = nil
      pendingGroupID = nil
      pendingGroupSenderID = nil
      groupPairingCode = nil
      selectedBotID = nil
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

  private func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let client = self.transport else { return }
        do {
          let updates = try await client.updates(after: self.offset)
          for update in updates.sorted(by: { $0.updateID < $1.updateID }) {
            guard !Task.isCancelled else { return }
            if update.updateID < self.offset { continue }
            // Save before dispatch: after a crash an update must not run twice.
            self.offset = update.updateID + 1
            self.defaults.set(NSNumber(value: self.offset), forKey: "\(self.prefix).offset")
            if let message = update.message { await self.handle(message, client: client) }
          }
        } catch {
          if !Task.isCancelled {
            self.status = "Telegram polling interrupted. Retrying connection."
          }
          try? await Task.sleep(for: .seconds(5))
        }
      }
    }
  }

  private func handle(_ message: TelegramIncomingMessage, client: TelegramBotTransport) async {
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
        "Otto commands:\n/bots — show the Otto bot selected on the Mac\nSend normal text to that bot. Only the Mac owner can change the bot. Tool approvals remain in Otto on the Mac.",
        to: chat)
    case .bots:
      let selected = selectedBotID.flatMap { id in bots.first(where: { $0.id == id }) }
      try? await client.send(
        selected.map { "Connected Otto bot: @\($0.handle) — \($0.name)" }
          ?? "No Otto bot selected. Select one on the Mac in Connectors → Telegram.", to: chat)
    case .use, .send:
      try? await client.send(
        "Bot selection is locked on the Mac. Open Otto → Connectors → Telegram to choose the bot.",
        to: chat)
    case .message(let prompt):
      guard let id = selectedBotID, let bot = bots.first(where: { $0.id == id }) else {
        try? await client.send("Select an Otto bot in Mac → Connectors → Telegram.", to: chat)
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
      // A prompt send may return before the backend starts or finishes. Follow
      // the exact opened agent and never borrow another bot's result.
      for _ in 0..<120 {
        try? await Task.sleep(for: .seconds(1))
        if Task.isCancelled { return }
        guard let snapshot = services.fleetStore.snapshot(for: opened.agentID) else { continue }
        let newAnswer = snapshot.transcript.reversed().first {
          $0.role == .assistant && $0.kind == .text && !$0.text.isEmpty
            && !previousAssistantIDs.contains($0.id)
        }?.text
        guard snapshot.runID != previousRunID || newAnswer != nil else { continue }
        if snapshot.state == .waitingPermission || snapshot.state == .waitingUser {
          try? await client.send(
            "This bot needs your input or approval in the Otto Mac app.", to: chat)
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
    } catch {
      try? await client.send(
        "Could not dispatch the message. Open Otto on your Mac to check the bot.", to: chat)
    }
  }
}
