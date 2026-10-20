import Combine
import Foundation
import OttoModels

private struct PersistedRoutines: Codable {
  var schemaVersion: Int
  var routines: [Routine]
}

public enum RoutineStoreError: Error, LocalizedError, Equatable, Sendable {
  case invalid(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let message): "Invalid routine: \(message)"
    }
  }
}

@MainActor
public final class RoutineStore: ObservableObject {
  @Published public private(set) var routines: [Routine] = []
  @Published public private(set) var persistenceError: String?
  /// Bumps whenever a run record is appended, so views showing run state can refresh.
  @Published public private(set) var runsRevision = 0

  private let fileURL: URL
  private let runsURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let root = URL(fileURLWithPath: workspacePath).appending(path: ".otto")
    self.fileURL = root.appending(path: "routines.json")
    self.runsURL = root.appending(path: "routines/runs.jsonl")
    load()
  }

  public func routine(id: UUID) -> Routine? { routines.first { $0.id == id } }

  @discardableResult
  public func save(_ candidate: Routine) throws -> Routine {
    var routine = candidate
    routine.name = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
    routine.instruction = routine.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    routine.toolAllowlist = routine.toolAllowlist?.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    if routine.runAfter != nil { routine.trigger = Routine.chainedTrigger }
    try Self.validate(routine)
    try validateChain(routine)
    let now = Date.now
    if let index = routines.firstIndex(where: { $0.id == routine.id }) {
      routine.createdAt = routines[index].createdAt
      routine.revision = max(routines[index].revision + 1, routine.revision)
      routine.updatedAt = now
      routines[index] = routine
    } else {
      routine.createdAt = now
      routine.updatedAt = now
      routine.revision = max(1, routine.revision)
      routines.append(routine)
    }
    routines.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    try persist()
    return routine
  }

  /// Deleting a step keeps the rest of its flow running: steps that ran after it now run
  /// after whatever it ran after, or take over its own trigger if it started the flow.
  public func delete(id: UUID) throws {
    if let removed = routine(id: id) {
      for index in routines.indices where routines[index].runAfter?.routineID == id {
        if let grandparent = removed.runAfter {
          routines[index].runAfter = RoutineChainLink(
            routineID: grandparent.routineID, when: routines[index].runAfter?.when ?? .succeeded)
        } else {
          routines[index].runAfter = nil
          routines[index].trigger = removed.trigger
          routines[index].timeZoneIdentifier = removed.timeZoneIdentifier
        }
        routines[index].revision += 1
        routines[index].updatedAt = .now
      }
    }
    routines.removeAll { $0.id == id }
    try persist()
  }

  /// Steps that run straight after `routineID` finishes.
  public func followers(of routineID: UUID) -> [Routine] {
    routines.filter { $0.runAfter?.routineID == routineID }
  }

  /// The automation that starts the flow `routineID` belongs to.
  public func flowRoot(of routineID: UUID) -> Routine? {
    var current = routine(id: routineID)
    var seen: Set<UUID> = []
    while let link = current?.runAfter, let parent = routine(id: link.routineID),
      seen.insert(parent.id).inserted
    {
      current = parent
    }
    return current
  }

  private func validateChain(_ candidate: Routine) throws {
    guard let link = candidate.runAfter else { return }
    guard link.routineID != candidate.id else {
      throw RoutineStoreError.invalid("A step can’t run after itself")
    }
    guard routine(id: link.routineID) != nil else {
      throw RoutineStoreError.invalid("The step it runs after no longer exists")
    }
    var cursor: UUID? = link.routineID
    var depth = 1
    while let id = cursor {
      guard id != candidate.id else {
        throw RoutineStoreError.invalid("That would make the flow loop back on itself")
      }
      depth += 1
      guard depth <= RoutineChainLink.maximumDepth else {
        throw RoutineStoreError.invalid(
          "Flows can be at most \(RoutineChainLink.maximumDepth) steps deep")
      }
      cursor = routine(id: id)?.runAfter?.routineID
    }
  }

  public func archive(profileID: UUID) throws {
    var changed = false
    for index in routines.indices where routines[index].references(profileID: profileID) {
      if routines[index].enabled {
        routines[index].enabled = false
        routines[index].suspendedByProfileArchive = true
        routines[index].revision += 1
        routines[index].updatedAt = .now
        changed = true
      }
    }
    if changed { try persist() }
  }

  public func restore(profileID: UUID) throws {
    var changed = false
    for index in routines.indices
    where routines[index].references(profileID: profileID)
      && routines[index].suspendedByProfileArchive == true
    {
      routines[index].enabled = false
      routines[index].suspendedByProfileArchive = nil
      routines[index].revision += 1
      routines[index].updatedAt = .now
      changed = true
    }
    if changed { try persist() }
  }

  public func appendRun(_ record: RoutineRunRecord) throws {
    try fileManager.createDirectory(
      at: runsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = try Self.runEncoder.encode(record)
    data.append(0x0A)
    if !fileManager.fileExists(atPath: runsURL.path) {
      try data.write(to: runsURL, options: .atomic)
      runsRevision &+= 1
      return
    }
    let handle = try FileHandle(forWritingTo: runsURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    runsRevision &+= 1
  }

  public func recentRuns(routineID: UUID? = nil, limit: Int = 50) -> [RoutineRunRecord] {
    allRuns().filter { routineID == nil || $0.routineID == routineID }
      .suffix(max(0, limit)).reversed()
  }

  private struct RunsCache {
    var modified: Date?
    var size: Int?
    var records: [RoutineRunRecord]
  }

  /// Run history is read by views on every update, so it is parsed once and reused until
  /// the file changes (here or in another Otto process sharing the workspace).
  private var runsCache: RunsCache?

  private func allRuns() -> [RoutineRunRecord] {
    let attributes = try? fileManager.attributesOfItem(atPath: runsURL.path)
    let modified = attributes?[.modificationDate] as? Date
    let size = (attributes?[.size] as? NSNumber)?.intValue
    if let runsCache, runsCache.modified == modified, runsCache.size == size {
      return runsCache.records
    }
    guard let data = try? Data(contentsOf: runsURL),
      let text = String(data: data, encoding: .utf8)
    else {
      runsCache = RunsCache(modified: modified, size: size, records: [])
      return []
    }
    let decoder = Self.decoder
    let records = text.split(separator: "\n").compactMap { line in
      try? decoder.decode(RoutineRunRecord.self, from: Data(line.utf8))
    }
    runsCache = RunsCache(modified: modified, size: size, records: records)
    return records
  }

  public nonisolated static func validate(_ routine: Routine) throws {
    guard !routine.name.isEmpty else { throw RoutineStoreError.invalid("Name is required") }
    guard routine.name.count <= 120 else { throw RoutineStoreError.invalid("Name is too long") }
    guard !routine.instruction.isEmpty else {
      throw RoutineStoreError.invalid("Instruction is required")
    }
    guard TimeZone(identifier: routine.timeZoneIdentifier) != nil else {
      throw RoutineStoreError.invalid("Timezone is invalid")
    }
    switch routine.trigger {
    case .schedule(let cron, let interval):
      guard (cron == nil) != (interval == nil) else {
        throw RoutineStoreError.invalid("Schedule requires cron or interval, but not both")
      }
      if let cron, CronExpression(cron) == nil {
        throw RoutineStoreError.invalid("Cron expression is invalid")
      }
      if let interval, interval < 60 {
        throw RoutineStoreError.invalid("Schedule intervals must be at least 60 seconds")
      }
    case .webhook(let slug, _):
      guard !slug.isEmpty,
        slug.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
      else { throw RoutineStoreError.invalid("Webhook slug is invalid") }
    case .agentEvent(let types, _):
      guard !types.isEmpty else { throw RoutineStoreError.invalid("Select an agent event") }
    case .slackMessage, .discordMessage, .gitEvent:
      throw RoutineStoreError.invalid("This trigger is not available yet")
    }
    let encoded = String(decoding: try JSONEncoder().encode(routine), as: UTF8.self).lowercased()
    if let marker = credentialMarkers.first(where: { encoded.contains($0) }) {
      throw RoutineStoreError.invalid(
        "Definition appears to contain a credential marker (\(marker))")
    }
  }

  public nonisolated static func scanAssembledPrompt(_ prompt: String) throws -> String {
    let sanitized = prompt.unicodeScalars.filter { scalar in
      !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t"
    }.map(String.init).joined()
    let lowered = sanitized.lowercased()
    if let marker = credentialMarkers.first(where: { lowered.contains($0) }) {
      throw RoutineStoreError.invalid("Assembled prompt contains a credential marker (\(marker))")
    }
    return sanitized
  }

  private func load() {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    do {
      let persisted = try Self.decoder.decode(
        PersistedRoutines.self, from: Data(contentsOf: fileURL))
      routines = persisted.routines.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      persistenceError = nil
    } catch {
      persistenceError = "Could not load routines: \(error.localizedDescription)"
    }
  }

  private func persist() throws {
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try Self.encoder.encode(
        PersistedRoutines(schemaVersion: Routine.currentSchemaVersion, routines: routines))
      try data.write(to: fileURL, options: .atomic)
      persistenceError = nil
    } catch {
      persistenceError = "Could not save routines: \(error.localizedDescription)"
      throw error
    }
  }

  private nonisolated static let credentialMarkers = [
    "api_key=", "apikey=", "access_token=", "password=", "bearer ", "sk-ant-", "sk-proj-",
    "ghp_", "github_pat_", "xoxb-", "xapp-", "akia", "private key-----",
  ]

  private nonisolated static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private nonisolated static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private nonisolated static var runEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

extension Routine {
  fileprivate func references(profileID: UUID) -> Bool {
    if case .spawnProfile(let id) = target, id == profileID { return true }
    if case .botChannel(let id) = delivery, id == profileID { return true }
    return false
  }
}
