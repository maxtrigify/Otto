import Foundation
import OttoModels
import OttoRuntime
import OttoTools

public actor ObservabilityStore: ToolAuditSink {
  private let eventsURL: URL
  private nonisolated let healthTracker: SessionHealthTracker
  private let eventLimit: Int
  private let appVersion: String
  private let operatingSystemVersion: String
  private var events: [ObservabilityEvent]
  private var agentOrdinals: [UUID: Int] = [:]
  private var nextAgentOrdinal = 1
  private var previousSessionAbnormal = false
  private var sessionStarted = false

  public init(
    directory: URL,
    appVersion: String,
    operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
    eventLimit: Int = 2_048
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    self.eventsURL = directory.appending(path: "diagnostic-events.json")
    self.healthTracker = try SessionHealthTracker(directory: directory)
    self.eventLimit = max(32, eventLimit)
    self.appVersion = Self.safeVersion(appVersion)
    self.operatingSystemVersion = Self.safeOperatingSystemVersion(operatingSystemVersion)
    if let data = try? Data(contentsOf: eventsURL),
      let decoded = try? JSONDecoder.observability.decode([ObservabilityEvent].self, from: data)
    {
      self.events = Array(decoded.suffix(max(32, eventLimit)))
    } else {
      self.events = []
    }
  }

  public func beginSession() throws {
    guard !sessionStarted else { return }
    previousSessionAbnormal = try healthTracker.beginSession()
    sessionStarted = true
    if previousSessionAbnormal {
      try append(ObservabilityEvent(kind: .previousSessionAbnormal))
    }
    try append(ObservabilityEvent(kind: .sessionStarted))
  }

  public func endSession() throws {
    guard sessionStarted else { return }
    try append(ObservabilityEvent(kind: .sessionEnded))
    try healthTracker.endSession()
    sessionStarted = false
  }

  public nonisolated func markCleanTermination() {
    try? healthTracker.endSession()
  }

  public func record(_ record: ToolAuditRecord) async {
    try? append(
      ObservabilityEvent(
        timestamp: record.timestamp,
        kind: .toolCall,
        toolName: Self.safeToolName(record.toolName),
        durationMilliseconds: record.durationMilliseconds,
        succeeded: record.succeeded
      )
    )
  }

  public func recordRuntimeEvent(
    _ event: RuntimeEvent,
    provider: AgentProvider?
  ) throws {
    switch event {
    case .output, .transcriptChanged:
      return
    case .stateChanged(let agentID, let state, let confidence):
      try append(
        ObservabilityEvent(
          kind: state == .failed ? .providerFailure : .agentStateChanged,
          provider: provider,
          agentState: state,
          targetOrdinal: ordinal(for: agentID),
          confidence: min(max(confidence, 0), 1)
        )
      )
    case .completed(let agentID, _, let confidence):
      try append(
        ObservabilityEvent(
          kind: .resultExtracted,
          provider: provider,
          agentState: .done,
          targetOrdinal: ordinal(for: agentID),
          confidence: min(max(confidence, 0), 1),
          succeeded: true
        )
      )
    case .exited(let agentID, let code):
      if code != 0 {
        try append(
          ObservabilityEvent(
            kind: .providerFailure,
            provider: provider,
            targetOrdinal: ordinal(for: agentID),
            succeeded: false,
            exitCode: code
          )
        )
      }
    }
  }

  public func recordVoiceState(_ state: String) throws {
    try append(
      ObservabilityEvent(
        kind: .voiceStateChanged,
        voiceState: try Self.safeVoiceState(state)
      )
    )
  }

  public func timeline() -> [ObservabilityEvent] {
    events
  }

  public func snapshot() -> ObservabilitySnapshot {
    let toolEvents = events.filter { $0.kind == .toolCall }
    let latencies = toolEvents.compactMap(\.durationMilliseconds).sorted()
    let median: Double?
    if latencies.isEmpty {
      median = nil
    } else if latencies.count.isMultiple(of: 2) {
      let upper = latencies.count / 2
      median = (latencies[upper - 1] + latencies[upper]) / 2
    } else {
      median = latencies[latencies.count / 2]
    }
    return ObservabilitySnapshot(
      appVersion: appVersion,
      operatingSystemVersion: operatingSystemVersion,
      previousSessionAbnormal: previousSessionAbnormal,
      eventCounts: Dictionary(grouping: events, by: { $0.kind.rawValue }).mapValues(\.count),
      toolSuccessCount: toolEvents.filter { $0.succeeded == true }.count,
      toolFailureCount: toolEvents.filter { $0.succeeded == false }.count,
      toolLatencyMedianMilliseconds: median,
      providerFailureCount: events.filter { $0.kind == .providerFailure }.count
    )
  }

  public func export(
    consent: Bool,
    using exporter: any ObservabilityExporter
  ) async throws {
    guard consent else { throw ObservabilityError.consentRequired }
    try await exporter.export(snapshot())
  }

  private func append(_ event: ObservabilityEvent) throws {
    try Self.validate(event)
    events.append(event)
    if events.count > eventLimit { events.removeFirst(events.count - eventLimit) }
    let data = try JSONEncoder.observability.encode(events)
    try data.write(to: eventsURL, options: [.atomic])
  }

  private func ordinal(for agentID: UUID) -> Int {
    if let existing = agentOrdinals[agentID] { return existing }
    let ordinal = nextAgentOrdinal
    nextAgentOrdinal += 1
    agentOrdinals[agentID] = ordinal
    return ordinal
  }

  private static func validate(_ event: ObservabilityEvent) throws {
    if let toolName = event.toolName, safeToolName(toolName) != toolName {
      throw ObservabilityError.invalidEvent
    }
    if let voiceState = event.voiceState { _ = try safeVoiceState(voiceState) }
    if let duration = event.durationMilliseconds, !duration.isFinite || duration < 0 {
      throw ObservabilityError.invalidEvent
    }
    if let confidence = event.confidence, !confidence.isFinite || !(0...1).contains(confidence) {
      throw ObservabilityError.invalidEvent
    }
    if let ordinal = event.targetOrdinal, ordinal < 1 { throw ObservabilityError.invalidEvent }
  }

  private static func safeToolName(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._")
    guard value.count <= 64, value.unicodeScalars.allSatisfy(allowed.contains) else {
      return "unknown"
    }
    return value
  }

  private static func safeVoiceState(_ value: String) throws -> String {
    let allowed = Set([
      "disconnected", "connecting", "sleeping", "listening", "user_speaking", "end_of_turn",
      "thinking", "calling_tool", "speaking", "interrupted", "error", "reconnecting",
    ])
    guard allowed.contains(value) else { throw ObservabilityError.invalidEvent }
    return value
  }

  private static func safeVersion(_ value: String) -> String {
    String(value.prefix(32)).filter { $0.isNumber || $0 == "." || $0 == "-" }
  }

  private static func safeOperatingSystemVersion(_ value: String) -> String {
    let digits = value.split(whereSeparator: { !$0.isNumber && $0 != "." }).first(where: {
      $0.contains(".")
    })
    return digits.map(String.init) ?? "unknown"
  }
}

extension JSONDecoder {
  fileprivate static var observability: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

extension JSONEncoder {
  fileprivate static var observability: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
