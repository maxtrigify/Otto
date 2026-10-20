import Foundation
import OttoTools

public enum RemotePushEnvironment: String, Codable, CaseIterable, Sendable {
  case sandbox
  case production
}

public enum RemoteProtocol {
  public static let version = 1
}

public enum RemoteDeviceScope: String, Codable, CaseIterable, Sendable {
  case readActivity = "activity:read"
  case readThreads = "threads:read"
  case sendMessages = "messages:send"
  case respondApprovals = "approvals:respond"
  case interruptRuns = "runs:interrupt"
  case controlComputer = "computer:control"
  case manageDevices = "devices:manage"
}

public struct RemotePairingOffer: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var environmentID: UUID
  public var environmentName: String
  public var fingerprint: String
  public var code: String
  public var expiresAt: Date
  public var scopes: Set<RemoteDeviceScope>

  public init(
    id: UUID = UUID(), environmentID: UUID, environmentName: String, fingerprint: String,
    code: String, expiresAt: Date, scopes: Set<RemoteDeviceScope>
  ) {
    self.id = id
    self.environmentID = environmentID
    self.environmentName = environmentName
    self.fingerprint = fingerprint
    self.code = code
    self.expiresAt = expiresAt
    self.scopes = scopes
  }
}

public struct RemotePairingQRPayload: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var offerID: UUID
  public var environmentID: UUID
  public var environmentName: String
  public var fingerprint: String
  public var code: String
  public var expiresAt: Date
}

public struct RemotePairedDevice: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var publicKey: String
  public var credentialHash: String
  public var scopes: Set<RemoteDeviceScope>
  public var pairedAt: Date
  public var lastSeenAt: Date?
  public var revokedAt: Date?
  public var pushToken: String?
  public var pushEnvironment: RemotePushEnvironment?
  public var pushRegisteredAt: Date?

  public init(
    id: UUID = UUID(), name: String, publicKey: String, credentialHash: String,
    scopes: Set<RemoteDeviceScope>, pairedAt: Date = .now, lastSeenAt: Date? = nil,
    revokedAt: Date? = nil,
    pushToken: String? = nil,
    pushEnvironment: RemotePushEnvironment? = nil,
    pushRegisteredAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.publicKey = publicKey
    self.credentialHash = credentialHash
    self.scopes = scopes
    self.pairedAt = pairedAt
    self.lastSeenAt = lastSeenAt
    self.revokedAt = revokedAt
    self.pushToken = pushToken
    self.pushEnvironment = pushEnvironment
    self.pushRegisteredAt = pushRegisteredAt
  }
}

public struct RemotePairingResult: Codable, Equatable, Sendable {
  public var device: RemotePairedDevice
  public var credential: String
}

public enum RemoteMethod: String, Codable, Sendable {
  case hello
  case heartbeat
  case events
  case launch
  case input
  case resize
  case stop
  case fileRead = "file.read"
  case fileWrite = "file.write"
  case tokenRotate = "token.rotate"
}

public struct RemoteRequest: Codable, Sendable, Equatable {
  public var id: String
  public var token: String
  public var method: RemoteMethod
  public var parameters: JSONValue?

  public init(
    id: String = UUID().uuidString,
    token: String,
    method: RemoteMethod,
    parameters: JSONValue? = nil
  ) {
    self.id = id
    self.token = token
    self.method = method
    self.parameters = parameters
  }
}

public struct RemoteFailure: Codable, Sendable, Equatable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct RemoteResponse: Codable, Sendable, Equatable {
  public var id: String
  public var result: JSONValue?
  public var error: RemoteFailure?

  public init(id: String, result: JSONValue? = nil, error: RemoteFailure? = nil) {
    self.id = id
    self.result = result
    self.error = error
  }
}

public enum RemoteEventKind: String, Codable, Sendable, CaseIterable {
  case sessionStarted = "session.started"
  case outputAppended = "session.output"
  case sessionExited = "session.exited"
  case sessionStopped = "session.stopped"
}

public struct RemoteEvent: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var sequence: Int64
  public var timestamp: Date
  public var kind: RemoteEventKind
  public var sessionID: UUID?
  public var payload: JSONValue?

  public init(
    id: UUID = UUID(),
    sequence: Int64 = 0,
    timestamp: Date = .now,
    kind: RemoteEventKind,
    sessionID: UUID? = nil,
    payload: JSONValue? = nil
  ) {
    self.id = id
    self.sequence = sequence
    self.timestamp = timestamp
    self.kind = kind
    self.sessionID = sessionID
    self.payload = payload
  }
}

public struct RemoteEventPage: Codable, Sendable, Equatable {
  public var events: [RemoteEvent]
  public var latestSequence: Int64
}

public struct RemoteCursorInput: Codable, Sendable, Equatable {
  public var afterSequence: Int64
  public var limit: Int

  public init(afterSequence: Int64 = 0, limit: Int = 200) {
    self.afterSequence = afterSequence
    self.limit = limit
  }
}

public struct RemoteLaunchInput: Codable, Sendable, Equatable {
  public var executable: String
  public var arguments: [String]
  public var workspacePath: String
  public var columns: UInt16
  public var rows: UInt16

  public init(
    executable: String,
    arguments: [String] = [],
    workspacePath: String,
    columns: UInt16 = 120,
    rows: UInt16 = 36
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workspacePath = workspacePath
    self.columns = columns
    self.rows = rows
  }
}

public struct RemoteSessionInput: Codable, Sendable, Equatable {
  public var sessionID: UUID

  public init(sessionID: UUID) { self.sessionID = sessionID }
}

public struct RemoteTerminalInput: Codable, Sendable, Equatable {
  public var sessionID: UUID
  public var data: Data

  public init(sessionID: UUID, data: Data) {
    self.sessionID = sessionID
    self.data = data
  }
}

public struct RemoteResizeInput: Codable, Sendable, Equatable {
  public var sessionID: UUID
  public var columns: UInt16
  public var rows: UInt16

  public init(sessionID: UUID, columns: UInt16, rows: UInt16) {
    self.sessionID = sessionID
    self.columns = columns
    self.rows = rows
  }
}

public struct RemoteSessionOutput: Codable, Sendable, Equatable {
  public var sessionID: UUID
}

public struct RemoteHello: Codable, Sendable, Equatable {
  public var protocolVersion: Int
  public var daemonVersion: String
  public var daemonID: UUID
  public var activeSessionIDs: [UUID]
  public var eventPage: RemoteEventPage
}

public struct RemoteTokenRotateInput: Codable, Sendable, Equatable {
  public var newToken: String

  public init(newToken: String) { self.newToken = newToken }
}

public enum RemoteTokenGenerator {
  public static func generate(byteCount: Int = 32) -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<max(32, byteCount))
      .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
      .joined()
  }
}

public struct RemoteHeartbeat: Codable, Sendable, Equatable {
  public var daemonID: UUID
  public var timestamp: Date
  public var activeSessions: Int
  public var processorCount: Int
  public var physicalMemoryBytes: UInt64
}

public struct RemoteResourceLimits: Codable, Sendable, Equatable {
  public var maximumSessions: Int
  public var maximumEventPage: Int
  public var maximumInputBytes: Int
  public var maximumColumns: UInt16
  public var maximumRows: UInt16
  public var maximumJournalBytes: Int64
  public var maximumTransferBytes: Int

  public init(
    maximumSessions: Int = 30,
    maximumEventPage: Int = 500,
    maximumInputBytes: Int = 65_536,
    maximumColumns: UInt16 = 400,
    maximumRows: UInt16 = 200,
    maximumJournalBytes: Int64 = 64 * 1_024 * 1_024,
    maximumTransferBytes: Int = 5 * 1_024 * 1_024
  ) {
    self.maximumSessions = maximumSessions
    self.maximumEventPage = maximumEventPage
    self.maximumInputBytes = maximumInputBytes
    self.maximumColumns = maximumColumns
    self.maximumRows = maximumRows
    self.maximumJournalBytes = maximumJournalBytes
    self.maximumTransferBytes = maximumTransferBytes
  }
}

public struct RemoteFileReadInput: Codable, Sendable, Equatable {
  public var workspacePath: String
  public var relativePath: String

  public init(workspacePath: String, relativePath: String) {
    self.workspacePath = workspacePath
    self.relativePath = relativePath
  }
}

public struct RemoteFileWriteInput: Codable, Sendable, Equatable {
  public var workspacePath: String
  public var relativePath: String
  public var data: Data
  public var overwrite: Bool

  public init(
    workspacePath: String,
    relativePath: String,
    data: Data,
    overwrite: Bool = false
  ) {
    self.workspacePath = workspacePath
    self.relativePath = relativePath
    self.data = data
    self.overwrite = overwrite
  }
}

public struct RemoteFileOutput: Codable, Sendable, Equatable {
  public var data: Data
  public var byteCount: Int

  public init(data: Data, byteCount: Int) {
    self.data = data
    self.byteCount = byteCount
  }
}

public enum RemoteError: Error, LocalizedError, Equatable {
  case unauthorized
  case invalidInput(String)
  case workspaceDenied
  case sessionNotFound
  case resourceLimit(String)
  case journal(String)

  public var errorDescription: String? {
    switch self {
    case .unauthorized: "Remote authentication failed."
    case .invalidInput(let message): "Invalid remote request: \(message)"
    case .workspaceDenied: "The requested workspace is outside registered remote roots."
    case .sessionNotFound: "The remote session does not exist."
    case .resourceLimit(let message): "Remote resource limit reached: \(message)"
    case .journal(let message): "Remote event journal failed: \(message)"
    }
  }
}
