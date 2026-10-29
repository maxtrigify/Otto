import Foundation

/// Connectors Otto can route through. Each one has its own set of Otto bots allowed to use it.
public enum ConnectorKind: String, CaseIterable, Codable, Sendable, Identifiable {
  case telegram, iMessage, mobile, gmail, calendar, email

  public var id: Self { self }

  public var title: String {
    switch self {
    case .telegram: "Telegram"
    case .iMessage: "iMessage"
    case .mobile: "Mobile"
    case .gmail: "Gmail"
    case .calendar: "Google Calendar"
    case .email: "Email (SMTP)"
    }
  }
}

private struct PersistedConnectorAccess: Codable {
  var schemaVersion: Int
  var grants: [String: [UUID]]
}

/// Which Otto bots may use each connector. Grants are multi-select and default to nobody, so a
/// connector never reaches a bot until the Mac owner allows that bot explicitly.
public final class ConnectorAccessStore: ObservableObject {
  public static let currentSchemaVersion = 1

  @Published public private(set) var grants: [ConnectorKind: Set<UUID>] = [:]
  @Published public private(set) var persistenceError: String?

  private let fileURL: URL

  public init(workspacePath: String) {
    fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/connector-access.json")
    do {
      let persisted = try WorkspaceJSONFile.load(
        PersistedConnectorAccess.self, from: fileURL, fileManager: .default)
      for (raw, ids) in persisted?.grants ?? [:] {
        if let kind = ConnectorKind(rawValue: raw) { grants[kind] = Set(ids) }
      }
    } catch {
      persistenceError = "Could not load connector access. \(error.localizedDescription)"
    }
  }

  public func bots(for kind: ConnectorKind) -> Set<UUID> { grants[kind] ?? [] }

  public func canUse(_ kind: ConnectorKind, profileID: UUID) -> Bool {
    grants[kind]?.contains(profileID) ?? false
  }

  public func setAllowed(_ allowed: Bool, profileID: UUID, for kind: ConnectorKind) throws {
    var next = grants
    var set = next[kind] ?? []
    if allowed { set.insert(profileID) } else { set.remove(profileID) }
    next[kind] = set
    try persist(next)
  }

  /// Called when an Otto bot is deleted so no connector keeps a grant to it.
  public func removeProfile(_ profileID: UUID) throws {
    var next = grants
    for kind in next.keys { next[kind]?.remove(profileID) }
    try persist(next)
  }

  private func persist(_ next: [ConnectorKind: Set<UUID>]) throws {
    let payload = PersistedConnectorAccess(
      schemaVersion: Self.currentSchemaVersion,
      grants: Dictionary(
        uniqueKeysWithValues: next.map { ($0.key.rawValue, $0.value.sorted { $0.uuidString < $1.uuidString }) }))
    try WorkspaceJSONFile.save(payload, to: fileURL, fileManager: .default)
    grants = next
  }
}
