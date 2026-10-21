import CryptoKit
import Foundation

public struct MessagingBinding: Codable, Equatable, Sendable {
  public var id = UUID()
  public var accountID: String
  public var projectPath: String
  public var teamID: UUID
  public var coordinatorID: UUID
  public var roomID = UUID()
  public var expectedSender: String
  public var destination: String
  public var sender: String?
  public var conversation: String?
  public var providerRoute: String?
  public var enabled = true
}

public struct MessagingInbound: Codable, Sendable {
  public var accountID: String
  public var eventID: String
  public var conversation: String
  public var sender: String
  public var destination: String
  public var isDirect: Bool
  public var text: String
  public var unsupported: Bool
}

public struct MessagingJob: Codable, Identifiable, Sendable {
  public enum State: String, Codable, Sendable {
    case queued, running, ready, sending, accepted, uncertain, failed, cancelled
  }
  public var id = UUID()
  public var binding: MessagingBinding
  public var eventKey: String
  public var text: String
  public var reply: String?
  public var state: State = .queued
  public var attempts = 0
  public var nextAttempt = Date.distantPast
  public var createdAt = Date()
  public var acceptedAt: Date?
  public var progressParentID: UUID?
}

/// One atomic file commit includes inbound deduplication and its durable work item.
/// Pairing tokens exist only in memory and are invalidated by restart or disconnect.
@MainActor
public final class MessagingStore {
  struct Contents: Codable {
    var binding: MessagingBinding?
    var jobs: [MessagingJob] = []
  }
  private let url: URL
  private var contents: Contents
  private var pairing: (digest: Data, expires: Date)?
  public var binding: MessagingBinding? { contents.binding }
  public var jobs: [MessagingJob] { contents.jobs }

  public init(url: URL) throws {
    self.url = url
    if FileManager.default.fileExists(atPath: url.path) {
      do {
        contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: url))
      } catch CocoaError.fileReadNoPermission {
        // Builds before 0.2.1 saved this file with complete-unless-open protection, which macOS 27
        // never lets any process read again. Set it aside (never delete) and start fresh; the
        // person pairs messaging again.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
          of: ":", with: "-")
        let aside = url.deletingLastPathComponent()
          .appendingPathComponent("state.unreadable-\(stamp).json")
        try FileManager.default.moveItem(at: url, to: aside)
        contents = Contents()
      }
    } else {
      contents = Contents()
    }
    var restored = contents
    for i in restored.jobs.indices where restored.jobs[i].state == .sending {
      restored.jobs[i].state = .uncertain
    }
    try commit(restored)
  }

  public func configure(_ binding: MessagingBinding) throws {
    guard !binding.accountID.isEmpty, !binding.expectedSender.isEmpty,
      !binding.destination.isEmpty
    else { throw MessagingError.invalidConfiguration }
    var next = contents
    for i in next.jobs.indices where ![.accepted, .failed, .uncertain].contains(next.jobs[i].state)
    {
      next.jobs[i].state = .cancelled
    }
    next.binding = binding
    try commit(next)
    pairing = nil
  }

  public func issuePairing(now: Date = .now) throws -> String {
    guard let binding, binding.enabled, binding.sender == nil else {
      throw MessagingError.invalidConfiguration
    }
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    pairing = (Data(SHA256.hash(data: Data(token.utf8))), now.addingTimeInterval(300))
    return token
  }

  @discardableResult
  public func accept(_ event: MessagingInbound, now: Date = .now) throws -> Bool {
    guard var binding, binding.enabled, event.isDirect,
      event.accountID == binding.accountID, event.sender == binding.expectedSender,
      // Spectrum uses the authenticated project route "shared" for shared-pool numbers.
      // Physical numbers remain the user-facing destination; identity still requires account + sender.
      event.destination == binding.destination || event.destination == "shared",
      !event.eventID.isEmpty,
      !event.conversation.isEmpty, event.text.count <= 16_000
    else { return false }
    let key = ["photon", event.accountID, event.destination, event.eventID]
      .map { "\($0.utf8.count):\($0)" }.joined()
    guard !contents.jobs.contains(where: { $0.eventKey == key }) else { return false }
    var next = contents
    if binding.sender == nil {
      guard !event.unsupported, event.text.hasPrefix("PAIR "), let pairing,
        pairing.expires > now,
        Data(SHA256.hash(data: Data(event.text.dropFirst(5).utf8))) == pairing.digest
      else { return false }
      binding.sender = event.sender
      binding.conversation = event.conversation
      binding.providerRoute = event.destination
      next.binding = binding
      var job = MessagingJob(binding: binding, eventKey: key, text: "")
      job.reply =
        "Paired with Otto. Send a text request to test your team. Otto must be running on your Mac."
      job.state = .ready
      next.jobs.append(job)
      try commit(next)
      self.pairing = nil
      return true
    }
    guard event.sender == binding.sender, event.conversation == binding.conversation,
      event.destination == (binding.providerRoute ?? binding.destination),
      !event.text.hasPrefix("PAIR ")
    else { return false }
    var job = MessagingJob(binding: binding, eventKey: key, text: event.text)
    if event.unsupported {
      job.text = ""
      job.reply =
        "Otto messaging currently supports text in personal conversations. Please send your request as text."
      job.state = .ready
    } else if event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return false
    }
    next.jobs.append(job)
    try commit(next)
    return true
  }

  public func update(_ job: MessagingJob) throws {
    var next = contents
    guard let index = next.jobs.firstIndex(where: { $0.id == job.id }) else { return }
    // Late callbacks after disconnect must never reactivate delivery.
    guard next.jobs[index].state != .cancelled else { return }
    next.jobs[index] = job
    try commit(next)
  }

  public func enqueueReview(for job: MessagingJob) throws {
    let key = job.eventKey + ":desktop-review"
    guard !contents.jobs.contains(where: { $0.eventKey == key }),
      contents.binding?.enabled == true, contents.binding?.id == job.binding.id
    else { return }
    var next = contents
    var notice = MessagingJob(binding: job.binding, eventKey: key, text: "")
    notice.reply =
      "Your team needs your approval. Open Otto on your Mac and review the messaging team conversation. Replying here cannot approve this action."
    notice.state = .ready
    next.jobs.append(notice)
    try commit(next)
  }

  public func enqueueProgress(for job: MessagingJob) throws {
    guard job.state == .running,
      contents.jobs.contains(where: { $0.id == job.id && $0.state == .running }),
      contents.binding?.enabled == true,
      contents.binding?.id == job.binding.id,
      !contents.jobs.contains(where: { $0.progressParentID == job.id })
    else { return }
    var next = contents
    var notice = MessagingJob(binding: job.binding, eventKey: job.eventKey + ":working", text: "")
    notice.reply = "Got it — your team is working on this. I’ll send the answer here."
    notice.state = .ready
    notice.progressParentID = job.id
    next.jobs.append(notice)
    try commit(next)
  }

  public func disconnect() throws {
    var next = contents
    next.binding?.enabled = false
    next.binding?.sender = nil
    next.binding?.conversation = nil
    for i in next.jobs.indices where ![.accepted, .uncertain, .failed].contains(next.jobs[i].state)
    {
      next.jobs[i].state = .cancelled
    }
    try commit(next)
    pairing = nil
  }

  private func commit(_ next: Contents) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(next)
    // 0600 permissions protect this file. Data-protection classes are not used: on macOS 27 a file
    // written with complete-unless-open protection can no longer be read back.
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    contents = next
  }
}

public enum MessagingError: Error, LocalizedError {
  case invalidConfiguration, runtimeMissing, providerUnavailable
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "Select an available project, team and coordinator, and check your Photon details."
    case .runtimeMissing: "Install the Photon connector and Node.js 22 or later, then reconnect."
    case .providerUnavailable:
      "Photon could not connect. Check your project credentials, account access and network, then reconnect."
    }
  }
}
