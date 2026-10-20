import Foundation

/// The set of native widget views Otto renders itself. Users and agents own the data script;
/// Otto owns presentation, so every widget stays glanceable and canvas-native.
public enum WidgetViewKind: String, Codable, CaseIterable, Sendable {
  case number
  case line
  case bar
  case pie
  case table
}

public struct WidgetViewDescriptor: Codable, Equatable, Sendable {
  public var kind: WidgetViewKind
  /// Optional unit caption, e.g. "followers" or "USD".
  public var unit: String?
  /// Number widgets keep this many samples for the delta and sparkline. Clamped to 2...1_000.
  public var historyLimit: Int?

  public init(kind: WidgetViewKind, unit: String? = nil, historyLimit: Int? = nil) {
    self.kind = kind
    self.unit = unit
    self.historyLimit = historyLimit
  }

  public var resolvedHistoryLimit: Int {
    min(1_000, max(2, historyLimit ?? 168))
  }
}

/// A user-owned data job: an executable inside the widget package that prints the payload JSON
/// for the widget's view on stdout.
public struct WidgetJob: Codable, Equatable, Sendable {
  /// Package-relative path of the script, e.g. "scripts/refresh.sh".
  public var script: String
  /// Wall-clock budget for one run. Clamped to 1...60, default 15.
  public var timeoutSeconds: Int?

  public init(script: String, timeoutSeconds: Int? = nil) {
    self.script = script
    self.timeoutSeconds = timeoutSeconds
  }

  public var resolvedTimeoutSeconds: Int {
    min(60, max(1, timeoutSeconds ?? 15))
  }
}

public struct WidgetNumberPayload: Codable, Equatable, Sendable {
  public var value: Double
  public var label: String?
  public var unit: String?

  public init(value: Double, label: String? = nil, unit: String? = nil) {
    self.value = value
    self.label = label
    self.unit = unit
  }
}

public struct WidgetSeriesPoint: Codable, Equatable, Sendable {
  public var label: String
  public var value: Double

  public init(label: String, value: Double) {
    self.label = label
    self.value = value
  }
}

public struct WidgetSeriesPayload: Codable, Equatable, Sendable {
  public var points: [WidgetSeriesPoint]

  public init(points: [WidgetSeriesPoint]) {
    self.points = points
  }
}

public struct WidgetTablePayload: Codable, Equatable, Sendable {
  public var columns: [String]
  public var rows: [[String]]

  public init(columns: [String], rows: [[String]]) {
    self.columns = columns
    self.rows = rows
  }
}

/// A validated data payload matching a widget's declared view.
public enum WidgetPayload: Equatable, Sendable {
  case number(WidgetNumberPayload)
  case series(WidgetSeriesPayload)
  case table(WidgetTablePayload)
}

public enum WidgetPayloadError: LocalizedError, Equatable {
  case oversized(byteCount: Int)
  case malformed(String)
  case outOfBounds(String)

  public var errorDescription: String? {
    switch self {
    case .oversized(let byteCount):
      "Widget payload is \(byteCount) bytes; the limit is \(WidgetPayload.maximumBytes)"
    case .malformed(let detail):
      "Widget payload JSON is malformed: \(detail)"
    case .outOfBounds(let detail):
      "Widget payload is out of bounds: \(detail)"
    }
  }
}

extension WidgetPayload {
  public static let maximumBytes = 262_144

  /// Parses and validates script output (or agent-supplied data) against the widget's view kind.
  /// Contracts: number `{"value": 128, "label"?, "unit"?}`; line/bar/pie
  /// `{"points": [{"label": "Mon", "value": 12}, ...]}`; table
  /// `{"columns": ["A"], "rows": [["1"], ...]}`.
  public static func parse(json: String, kind: WidgetViewKind) throws -> WidgetPayload {
    let data = Data(json.utf8)
    guard data.count <= maximumBytes else {
      throw WidgetPayloadError.oversized(byteCount: data.count)
    }
    let decoder = JSONDecoder()
    switch kind {
    case .number:
      let payload: WidgetNumberPayload
      do {
        payload = try decoder.decode(WidgetNumberPayload.self, from: data)
      } catch {
        throw WidgetPayloadError.malformed("expected {\"value\": <number>}")
      }
      guard payload.value.isFinite else {
        throw WidgetPayloadError.outOfBounds("value must be finite")
      }
      try validateText(payload.label, name: "label")
      try validateText(payload.unit, name: "unit")
      return .number(payload)
    case .line, .bar, .pie:
      let payload: WidgetSeriesPayload
      do {
        payload = try decoder.decode(WidgetSeriesPayload.self, from: data)
      } catch {
        throw WidgetPayloadError.malformed(
          "expected {\"points\": [{\"label\": <string>, \"value\": <number>}]}")
      }
      guard (1...500).contains(payload.points.count) else {
        throw WidgetPayloadError.outOfBounds("points must contain 1–500 entries")
      }
      for point in payload.points {
        guard point.value.isFinite else {
          throw WidgetPayloadError.outOfBounds("point values must be finite")
        }
        guard kind != .pie || point.value >= 0 else {
          throw WidgetPayloadError.outOfBounds("pie values must be non-negative")
        }
        try validateText(point.label, name: "point label")
      }
      return .series(payload)
    case .table:
      let payload: WidgetTablePayload
      do {
        payload = try decoder.decode(WidgetTablePayload.self, from: data)
      } catch {
        throw WidgetPayloadError.malformed(
          "expected {\"columns\": [<string>], \"rows\": [[<string>]]}")
      }
      guard (1...12).contains(payload.columns.count) else {
        throw WidgetPayloadError.outOfBounds("tables must have 1–12 columns")
      }
      guard payload.rows.count <= 200 else {
        throw WidgetPayloadError.outOfBounds("tables must have at most 200 rows")
      }
      for column in payload.columns {
        try validateText(column, name: "column")
      }
      for row in payload.rows {
        guard row.count == payload.columns.count else {
          throw WidgetPayloadError.outOfBounds("every row must match the column count")
        }
        for cell in row {
          try validateText(cell, name: "cell")
        }
      }
      return .table(payload)
    }
  }

  private static func validateText(_ value: String?, name: String) throws {
    guard let value else { return }
    guard value.count <= 400 else {
      throw WidgetPayloadError.outOfBounds("\(name) must contain at most 400 characters")
    }
  }
}

/// Validates the free-form JSON delivered to a custom HTML widget. HTML widgets own their
/// schema, while Otto still enforces valid, bounded JSON before it crosses the web-view bridge.
public func validatedWidgetDataJSON(_ json: String) throws -> String {
  let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
  let data = Data(trimmed.utf8)
  guard data.count <= WidgetPayload.maximumBytes else {
    throw WidgetPayloadError.oversized(byteCount: data.count)
  }
  do {
    _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  } catch {
    throw WidgetPayloadError.malformed("expected valid JSON")
  }
  return trimmed
}

public struct WidgetHistorySample: Codable, Equatable, Sendable {
  public var at: Date
  public var value: Double

  public init(at: Date, value: Double) {
    self.at = at
    self.value = value
  }
}

/// The state Otto stores in `NodeContent.widget.state` for typed (native-view) widgets.
/// HTML widgets keep owning that field as an opaque blob; typed widgets get run metadata,
/// the latest validated payload, and a value history for the number view.
public struct WidgetRuntimeState: Codable, Equatable, Sendable {
  public var payload: String?
  public var history: [WidgetHistorySample]
  public var lastRunAt: Date?
  public var lastSuccessAt: Date?
  public var lastError: String?
  /// Opaque state owned by scheduled HTML widgets. Kept separate from their latest job data.
  public var widgetState: String?

  public init(
    payload: String? = nil,
    history: [WidgetHistorySample] = [],
    lastRunAt: Date? = nil,
    lastSuccessAt: Date? = nil,
    lastError: String? = nil,
    widgetState: String? = nil
  ) {
    self.payload = payload
    self.history = history
    self.lastRunAt = lastRunAt
    self.lastSuccessAt = lastSuccessAt
    self.lastError = lastError
    self.widgetState = widgetState
  }

  public static func decode(from json: String) -> WidgetRuntimeState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let state = try? decoder.decode(WidgetRuntimeState.self, from: Data(json.utf8)) else {
      return WidgetRuntimeState()
    }
    return state
  }

  public func encoded() -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self), let json = String(data: data, encoding: .utf8)
    else { return "{}" }
    return json
  }

  public mutating func recordSuccess(
    payloadJSON: String, payload: WidgetPayload, at date: Date, historyLimit: Int
  ) {
    self.payload = payloadJSON
    lastRunAt = date
    lastSuccessAt = date
    lastError = nil
    if case .number(let number) = payload {
      history.append(WidgetHistorySample(at: date, value: number.value))
      if history.count > historyLimit {
        history.removeFirst(history.count - historyLimit)
      }
    }
  }

  public mutating func recordFailure(_ message: String, at date: Date) {
    lastRunAt = date
    lastError = String(message.prefix(2_000))
  }

  public mutating func recordHTMLSuccess(payloadJSON: String, at date: Date) {
    payload = payloadJSON
    lastRunAt = date
    lastSuccessAt = date
    lastError = nil
  }
}
