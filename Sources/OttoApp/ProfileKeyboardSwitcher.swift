import AppKit
import OttoModels
import SwiftUI

/// Freeze the recent-profile order for the duration of a gesture.
struct ProfileCycleSelection {
  private(set) var profiles: [OttoProfile] = []
  var selectedID: UUID?

  mutating func cycle(profiles available: [OttoProfile], backwards: Bool = false) -> Bool {
    if profiles.isEmpty {
      guard available.count > 1 else { return false }
      profiles = available
      selectedID = available.first?.id
    }
    advance(backwards: backwards)
    return true
  }

  enum KeyResult { case ignored, consumed, commit }

  mutating func handle(_ event: NSEvent, available: [OttoProfile]) -> KeyResult {
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if event.type == .flagsChanged {
      return !flags.contains(.option) && !profiles.isEmpty ? .commit : .ignored
    }
    if event.keyCode == 48, flags == .option || flags == [.option, .shift] {
      return cycle(profiles: available, backwards: flags.contains(.shift)) ? .consumed : .ignored
    }
    guard !profiles.isEmpty else { return .ignored }
    switch event.keyCode {
    case 53: cancel()
    case 36, 76: return .commit
    case 123, 126: advance(backwards: true)
    case 124, 125: advance(backwards: false)
    default: break
    }
    return .consumed
  }

  mutating func advance(backwards: Bool) {
    guard !profiles.isEmpty else { return }
    let index = profiles.firstIndex { $0.id == selectedID } ?? 0
    selectedID = profiles[(index + (backwards ? profiles.count - 1 : 1)) % profiles.count].id
  }

  mutating func cancel() {
    profiles = []
    selectedID = nil
  }
}

struct ProfileCycleOverlay: View {
  let profiles: [OttoProfile]
  let selectedID: UUID?
  var choose: (UUID) -> Void
  var cancel: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.25)
          .contentShape(Rectangle())
          .onTapGesture(perform: cancel)
        panel
          .frame(
            width: min(
              CGFloat(profiles.count * 112 + 48), min(680, max(280, geometry.size.width - 40)))
          )
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
          .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(Color.primary.opacity(0.1)) }
          .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Switch space")
      }
    }
  }

  private var panel: some View {
    VStack(spacing: 18) {
      Text("Switch space")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
      ScrollViewReader { reader in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 8) {
            ForEach(profiles) { profile in
              ProfileCycleCard(profile: profile, selected: profile.id == selectedID) {
                choose(profile.id)
              }
              .id(profile.id)
            }
          }
          .padding(2)
        }
        .onChange(of: selectedID, initial: true) { _, id in
          if let id {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
              reader.scrollTo(id, anchor: .center)
            }
          }
        }
      }
      Text("Tab to cycle · Release ⌥ to switch · Esc to cancel")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .padding(22)
  }
}

private struct ProfileCycleCard: View {
  let profile: OttoProfile
  let selected: Bool
  var choose: () -> Void

  var body: some View {
    Button(action: choose) {
      VStack(spacing: 12) {
        Image(systemName: profile.symbol)
          .font(.system(size: 30, weight: .medium))
          .frame(width: 66, height: 66)
          .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        Text(profile.name)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .frame(height: 34, alignment: .top)
      }
      .frame(width: 104)
      .padding(.vertical, 14)
      .background {
        RoundedRectangle(cornerRadius: 20)
          .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
      }
      .overlay {
        RoundedRectangle(cornerRadius: 20)
          .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
      }
      .contentShape(RoundedRectangle(cornerRadius: 20))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

/// Local, window-scoped monitoring also receives Option release while web/text editors have focus.
struct ProfileShortcutEvents: NSViewRepresentable {
  var handle: (NSEvent) -> Bool
  var cancel: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(handle: handle, cancel: cancel) }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.view = view
    context.coordinator.start()
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.handle = handle
    context.coordinator.cancel = cancel
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

  @MainActor final class Coordinator {
    weak var view: NSView?
    var handle: (NSEvent) -> Bool
    var cancel: () -> Void
    nonisolated(unsafe) private var monitor: Any?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(handle: @escaping (NSEvent) -> Bool, cancel: @escaping () -> Void) {
      self.handle = handle
      self.cancel = cancel
    }
    func start() {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
        [weak self] event in
        guard let self else { return event }
        return route(event)
      }
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
      ) { [weak self] notification in
        let windowID = (notification.object as? NSWindow).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
          guard let self, let windowID, let window = self.view?.window,
            ObjectIdentifier(window) == windowID
          else { return }
          self.cancel()
        }
      }
    }
    func route(_ event: NSEvent) -> NSEvent? {
      guard let window = view?.window, window.isKeyWindow,
        window.attachedSheet == nil, NSApp?.modalWindow == nil
      else { return event }
      return handle(event) ? nil : event
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      if let observer { NotificationCenter.default.removeObserver(observer) }
      monitor = nil
      observer = nil
    }
    deinit {
      if let monitor { NSEvent.removeMonitor(monitor) }
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }
  }
}
