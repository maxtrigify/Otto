import AppKit
import SwiftUI

private struct OttoWindowActiveKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var ottoWindowIsActive: Bool {
    get { self[OttoWindowActiveKey.self] }
    set { self[OttoWindowActiveKey.self] = newValue }
  }
}

/// Reports whether the host window can currently present useful pixels. Expensive visual work
/// should use this in addition to `scenePhase`: a foreground app can still be fully covered,
/// minimized, or parked in another Space.
struct WindowVisibilityObserver: NSViewRepresentable {
  @Binding var isVisible: Bool

  func makeNSView(context: Context) -> ObserverView {
    let view = ObserverView()
    view.visibilityChanged = { visible in
      if isVisible != visible { isVisible = visible }
    }
    return view
  }

  func updateNSView(_ view: ObserverView, context: Context) {
    view.visibilityChanged = { visible in
      if isVisible != visible { isVisible = visible }
    }
    view.publishVisibility()
  }

  final class ObserverView: NSView {
    var visibilityChanged: ((Bool) -> Void)?
    private var observations: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      guard let window else {
        publishVisibility()
        return
      }
      let center = NotificationCenter.default
      for name in [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
      ] {
        observations.append(
          center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishVisibility() }
          })
      }
      publishVisibility()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil { stopObserving() }
      super.viewWillMove(toWindow: newWindow)
    }

    func publishVisibility() {
      let visible =
        window.map {
          !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        } ?? false
      DispatchQueue.main.async { [weak self] in
        self?.visibilityChanged?(visible)
      }
    }

    private func stopObserving() {
      for observation in observations { NotificationCenter.default.removeObserver(observation) }
      observations.removeAll()
    }
  }
}
