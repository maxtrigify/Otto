#if os(macOS)
  import Dispatch
  import Foundation

  /// Bridges macOS memory and thermal signals into scheduler admission. It never stops active
  /// workers; pressure only lowers the number of new workers that may start.
  @MainActor
  public final class AgentResourcePressureMonitor: NSObject {
    private let schedulers: [AgentResourceScheduler]
    private var source: DispatchSourceMemoryPressure?
    private var memoryPressure: AgentResourcePressure = .nominal
    private var thermalPressure: AgentResourcePressure = .nominal

    public init(scheduler: AgentResourceScheduler) {
      self.schedulers = [scheduler]
      super.init()
    }

    /// Publishes one system-pressure signal to every expensive-work scheduler. Widget jobs use
    /// a stricter scheduler than agents, but both must react to the same thermal and memory state.
    public init(schedulers: [AgentResourceScheduler]) {
      self.schedulers = schedulers
      super.init()
    }

    public func start() {
      guard source == nil else { return }
      thermalPressure = Self.pressure(for: ProcessInfo.processInfo.thermalState)

      let source = DispatchSource.makeMemoryPressureSource(
        eventMask: [.normal, .warning, .critical],
        queue: .main
      )
      source.setEventHandler { [weak self, weak source] in
        guard let self, let source else { return }
        self.memoryPressure = Self.pressure(for: source.data)
        self.publish()
      }
      self.source = source
      source.resume()

      NotificationCenter.default.addObserver(
        self,
        selector: #selector(thermalStateDidChange),
        name: ProcessInfo.thermalStateDidChangeNotification,
        object: nil
      )
      publish()
    }

    public func stop() {
      source?.cancel()
      source = nil
      NotificationCenter.default.removeObserver(
        self, name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
      memoryPressure = .nominal
      thermalPressure = .nominal
      publish()
    }

    public static func combined(
      memory: AgentResourcePressure,
      thermal: AgentResourcePressure
    ) -> AgentResourcePressure {
      if memory == .critical || thermal == .critical { return .critical }
      if memory == .elevated || thermal == .elevated { return .elevated }
      return .nominal
    }

    private func publish() {
      let pressure = Self.combined(memory: memoryPressure, thermal: thermalPressure)
      let schedulers = schedulers
      Task {
        for scheduler in schedulers {
          await scheduler.updatePressure(pressure)
        }
      }
    }

    // NotificationCenter invokes selectors on the posting thread. macOS posts thermal
    // changes from a background queue, so the Objective-C entry point must not be isolated.
    @objc nonisolated private func thermalStateDidChange() {
      Task { @MainActor [weak self] in
        guard let self, self.source != nil else { return }
        self.thermalPressure = Self.pressure(for: ProcessInfo.processInfo.thermalState)
        self.publish()
      }
    }

    private static func pressure(
      for event: DispatchSource.MemoryPressureEvent
    ) -> AgentResourcePressure {
      if event.contains(.critical) { return .critical }
      if event.contains(.warning) { return .elevated }
      return .nominal
    }

    private static func pressure(
      for state: ProcessInfo.ThermalState
    ) -> AgentResourcePressure {
      switch state {
      case .nominal: .nominal
      case .fair, .serious: .elevated
      case .critical: .critical
      @unknown default: .elevated
      }
    }
  }
#endif
