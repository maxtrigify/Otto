#if os(macOS)
  import Foundation
  import OttoRuntime
  import Testing

  struct AgentResourcePressureMonitorTests {
    @Test("Thermal notifications can arrive on a background thread without crashing")
    @MainActor
    func backgroundThermalNotification() async {
      let scheduler = AgentResourceScheduler(
        configuration: .init(nominalLimit: 2, elevatedLimit: 1, criticalLimit: 1))
      let monitor = AgentResourcePressureMonitor(scheduler: scheduler)
      monitor.start()
      defer { monitor.stop() }

      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global(qos: .userInteractive).async {
          #expect(!Thread.isMainThread)
          NotificationCenter.default.post(
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
          continuation.resume()
        }
      }
    }
  }
#endif
