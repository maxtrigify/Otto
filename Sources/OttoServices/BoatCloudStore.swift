import Combine
import CryptoKit
import Foundation
import OttoRemote
import OttoSecurity

/// Personal Boat account integration. Stripe/tenant provisioning is a separate future boundary.
@MainActor public final class BoatCloudStore: ObservableObject {
  public struct Machine: Codable, Identifiable, Equatable {
    public let id: String
    public var conversationID: String?
    public var promptID: String?
    public var uncertainSubmission = false
    public var provider = "codex"
  }
  private struct Saved: Codable {
    var machines: [Machine] = []
    var pendingCreate: BoatCreateIntent?
  }
  @Published public private(set) var connected = false
  @Published public private(set) var busy = false
  @Published public private(set) var machines: [Machine] = []
  @Published public private(set) var sandboxes: [String: BoatSandbox] = [:]
  @Published public private(set) var limits: BoatLimits?
  @Published public private(set) var events: [BoatEvent] = []
  @Published public private(set) var eventMachineID: String?
  @Published public private(set) var taskStatus: [String: String] = [:]
  @Published public private(set) var error: String?
  @Published public private(set) var pendingCreate: BoatCreateIntent?
  private let secrets: any SecretStore
  private let defaults: UserDefaults
  private let transport: BoatCloudClient.Transport
  private var client: BoatCloudClient?
  private var accountScope: String?
  private let secretKey = "boat.personal.api-key"

  public init(
    secrets: any SecretStore = makeKeychainSecretStore(service: OttoSecretService.boat),
    defaults: UserDefaults = .standard,
    transport: @escaping BoatCloudClient.Transport = BoatCloudClient.liveTransport
  ) {
    self.secrets = secrets
    self.defaults = defaults
    self.transport = transport
  }

  public func connect(key: String? = nil) async {
    await perform {
      let value: String
      if let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        value = key.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        guard let stored = try await self.secrets.value(for: self.secretKey) else {
          throw BoatCloudError.notConnected
        }
        value = stored
      }
      let candidate = BoatCloudClient(token: value, transport: self.transport)
      let limits = try await candidate.limits()
      // Validate before replacing a working connection or saving the credential.
      try await self.secrets.set(value, for: self.secretKey)
      self.accountScope = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }
        .joined()
      self.client = candidate
      self.connected = true
      self.limits = limits
      self.sandboxes = [:]
      self.taskStatus = [:]
      self.events = []
      self.eventMachineID = nil
      self.load()
    }
    if connected { await refresh() }
  }

  public func disconnect() async {
    await perform {
      try await self.secrets.delete(self.secretKey)
      self.client = nil
      self.connected = false
      self.accountScope = nil
      self.machines = []
      self.pendingCreate = nil
      self.sandboxes = [:]
      self.events = []
      self.eventMachineID = nil
      self.limits = nil
      self.taskStatus = [:]
    }
  }

  public func refresh(machineID: String? = nil) async {
    await perform {
      let client = try self.requireClient()
      self.limits = try await client.limits()
      for machine in self.machines {
        self.sandboxes[machine.id] = try await client.sandbox(machine.id)
        if let promptID = machine.promptID {
          self.taskStatus[machine.id] = try await client.promptStatus(
            machine.id, promptID: promptID)
        }
      }
      if let machineID,
        let machine = self.machines.first(where: { $0.id == machineID }),
        let conversation = machine.conversationID
      {
        // Rebuild recent history on reconnect. Do not persist remote response bodies or access URLs.
        var cursor: String?
        var all: [BoatEvent] = []
        for _ in 0..<20 {
          let page = try await client.events(machineID, conversation: conversation, cursor: cursor)
          all.append(
            contentsOf: page.events.filter {
              $0.conversationId == nil || $0.conversationId == conversation
            })
          guard page.pageInfo.hasMore, let next = page.pageInfo.nextCursor, next != cursor else {
            break
          }
          cursor = next
        }
        self.events = Array(all.suffix(500))
        self.eventMachineID = machineID
      } else {
        self.events = []
        self.eventMachineID = nil
      }
    }
  }

  public func create(trialOnly: Bool, useAccountEnvironment: Bool) async {
    await perform {
      let client = try self.requireClient()
      // Persist before POST; retry the exact body/key, including after a lost response or relaunch.
      let intent = self.pendingCreate ?? BoatCreateIntent(noEnv: !useAccountEnvironment)
      self.pendingCreate = intent
      self.save()
      let sandbox = try await client.create(intent, trialOnly: trialOnly)
      if !self.machines.contains(where: { $0.id == sandbox.id }) {
        self.machines.append(Machine(id: sandbox.id))
      }
      self.sandboxes[sandbox.id] = sandbox
      self.pendingCreate = nil
      self.save()
    }
  }

  public func resume(_ id: String, trialOnly: Bool) async {
    await perform {
      guard self.machines.contains(where: { $0.id == id }) else {
        throw BoatCloudError.invalidIdentifier
      }
      try await self.requireClient().resume(id, trialOnly: trialOnly)
    }
    if error == nil { await refresh(machineID: id) }
  }

  public func stop(_ id: String) async {
    await perform {
      guard self.machines.contains(where: { $0.id == id }) else {
        throw BoatCloudError.invalidIdentifier
      }
      try await self.requireClient().stop(id)
    }
    if error == nil { await refresh(machineID: id) }
  }

  public func send(_ text: String, to id: String, provider: String) async {
    await perform {
      let client = try self.requireClient()
      guard let index = self.machines.firstIndex(where: { $0.id == id }),
        !self.machines[index].uncertainSubmission
      else { throw BoatCloudError.invalidResponse }
      let sandbox = try await client.sandbox(id)
      self.sandboxes[id] = sandbox
      guard sandbox.canPrompt else { throw BoatCloudError.invalidResponse }
      // The prompt endpoint has no documented idempotency key. Never automatically resend.
      self.machines[index].uncertainSubmission = true
      self.save()
      let receipt: BoatPromptReceipt
      do {
        receipt = try await client.prompt(
          id, text: text, provider: provider,
          conversation: self.machines[index].conversationID)
      } catch let failure as BoatCloudError {
        if case .request(let status, _) = failure,
          [400, 401, 402, 403, 404, 409, 422, 429].contains(status)
        {
          self.machines[index].uncertainSubmission = false
          self.save()
        }
        throw failure
      }
      self.machines[index].promptID = receipt.promptId
      self.machines[index].conversationID = receipt.conversationId
      self.machines[index].provider = provider
      // Missing conversation identity prevents accidentally querying another session's events.
      self.machines[index].uncertainSubmission = receipt.conversationId == nil
      self.save()
    }
  }

  public func acknowledgeUncertainSubmission(_ id: String) {
    guard !busy, let index = machines.firstIndex(where: { $0.id == id }) else { return }
    machines[index].uncertainSubmission = false
    save()
  }

  private func requireClient() throws -> BoatCloudClient {
    guard let client else { throw BoatCloudError.notConnected }
    return client
  }
  private func perform(_ operation: () async throws -> Void) async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do { try await operation() } catch let failure as BoatCloudError {
      error = failure.localizedDescription
    } catch {
      self.error =
        "The connection did not complete. Refresh to check the outcome before trying again."
    }
  }
  private var storageKey: String? { accountScope.map { "otto.boat.personal.\($0)" } }
  private func load() {
    guard let storageKey, let data = defaults.data(forKey: storageKey),
      let saved = try? JSONDecoder().decode(Saved.self, from: data)
    else {
      machines = []
      pendingCreate = nil
      return
    }
    machines = saved.machines
    pendingCreate = saved.pendingCreate
  }
  private func save() {
    guard let storageKey,
      let data = try? JSONEncoder().encode(
        Saved(machines: machines, pendingCreate: pendingCreate))
    else { return }
    defaults.set(data, forKey: storageKey)
  }
}
