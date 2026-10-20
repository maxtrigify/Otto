import Foundation
import OttoApplicationTools
import OttoCore
import OttoDocuments
import OttoModels

/// Background scheduler for typed widget data jobs. Unlike the in-view interval (which only
/// ticks while a widget is visible), this runs for the whole app session: every tick it scans
/// all canvases for enabled widget schedules and launches due jobs through the shared runner,
/// which serializes runs per widget. Cron expressions take precedence over plain intervals;
/// a widget with no recorded run fires on the first tick so fresh widgets populate immediately.
@MainActor
public final class WidgetJobScheduler {
  /// Background runs are capped at one per minute per widget no matter what the manifest says.
  public nonisolated static let minimumIntervalSeconds = 60

  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  private let runner: WidgetJobRunner
  private let tickSeconds: Double
  private var tickTask: Task<Void, Never>?

  public init(
    store: CanvasStore,
    documents: WorkspaceDocumentStore,
    runner: WidgetJobRunner,
    tickSeconds: Double = 30
  ) {
    self.store = store
    self.documents = documents
    self.runner = runner
    self.tickSeconds = tickSeconds
  }

  deinit {
    tickTask?.cancel()
  }

  public func start() {
    stop()
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.tick()
        let seconds = self.tickSeconds
        try? await Task.sleep(for: .seconds(seconds))
      }
    }
  }

  public func stop() {
    tickTask?.cancel()
    tickTask = nil
  }

  public nonisolated static func nextDue(
    schedule: WidgetSchedule, state: WidgetRuntimeState
  ) -> Date? {
    guard schedule.enabled else { return nil }
    guard let last = state.lastRunAt else { return .distantPast }
    if let cronText = schedule.cron, let cron = CronExpression(cronText) {
      return cron.nextFire(after: last) ?? .distantFuture
    }
    let interval = Double(max(minimumIntervalSeconds, schedule.intervalSeconds))
    return last.addingTimeInterval(interval)
  }

  private func tick() async {
    let widgets = store.snapshot.canvases.flatMap { canvas in
      canvas.nodes.compactMap { node -> (nodeID: UUID, packagePath: String, state: String)? in
        guard node.kind == .widget, case .widget(let path, let state) = node.content,
          !path.isEmpty
        else { return nil }
        return (node.id, path, state)
      }
    }
    let now = Date()
    for widget in widgets {
      guard
        let manifestText = try? await documents.read(
          relativePath: "\(widget.packagePath)/widget.json"),
        let manifest = try? JSONDecoder().decode(
          WidgetManifest.self, from: Data(manifestText.utf8)),
        manifest.job != nil, let schedule = manifest.schedule,
        let due = Self.nextDue(
          schedule: schedule, state: WidgetRuntimeState.decode(from: widget.state)),
        due <= now
      else { continue }
      // Run through one bounded, pressure-aware queue. Awaiting the actor does not block the main
      // thread; it prevents a due-time stampede from creating an unbounded set of detached tasks.
      _ = try? await runner.run(nodeID: widget.nodeID)
    }
  }
}
