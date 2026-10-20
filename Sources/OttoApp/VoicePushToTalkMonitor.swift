import AppKit

/// SwiftUI keyboard shortcuts expose activation but not release. This monitor owns the Talk key's
/// down/up lifecycle so push-to-talk can close the microphone gate the instant the key is released.
@MainActor
final class VoicePushToTalkMonitor {
  // AppKit's opaque observer tokens are not Sendable. They are installed and used on the main
  // actor; the unsafe annotation only permits their required cleanup from Swift's nonisolated
  // deinitializer.
  nonisolated(unsafe) private var localMonitor: Any?
  nonisolated(unsafe) private var globalMonitor: Any?
  nonisolated(unsafe) private var resignObserver: NSObjectProtocol?
  private let shortcut: () -> VoiceShortcut
  private let isEnabled: () -> Bool
  private let changed: (Bool) -> Void
  private var pressed = false

  init(
    shortcut: @escaping () -> VoiceShortcut,
    isEnabled: @escaping () -> Bool,
    changed: @escaping (Bool) -> Void
  ) {
    self.shortcut = shortcut
    self.isEnabled = isEnabled
    self.changed = changed
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
      [weak self] event in
      guard let self, self.handle(event) else { return event }
      return nil
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) {
      [weak self] event in
      _ = self?.handle(event)
    }
    resignObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.releaseIfNeeded() }
    }
  }

  deinit {
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
  }

  private func handle(_ event: NSEvent) -> Bool {
    guard isEnabled() else {
      releaseIfNeeded()
      return false
    }
    let shortcut = shortcut()
    // Modifier flags may already be gone if the user releases Option before the main key. Once a
    // matching press begins, the corresponding key-up must always close the microphone gate.
    if event.type == .keyUp, pressed, matchesCharacter(event, shortcut: shortcut) {
      releaseIfNeeded()
      return true
    }
    guard matches(event, shortcut: shortcut) else { return false }
    if event.type == .keyDown {
      guard !event.isARepeat, !pressed else { return true }
      pressed = true
      changed(true)
    }
    return true
  }

  private func releaseIfNeeded() {
    guard pressed else { return }
    pressed = false
    changed(false)
  }

  private func matches(_ event: NSEvent, shortcut: VoiceShortcut) -> Bool {
    let ignored: NSEvent.ModifierFlags = [.capsLock, .numericPad, .function]
    let actual = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(ignored)
    let expected = shortcut.appKitModifiers
    guard actual == expected else { return false }
    return matchesCharacter(event, shortcut: shortcut)
  }

  private func matchesCharacter(_ event: NSEvent, shortcut: VoiceShortcut) -> Bool {
    event.charactersIgnoringModifiers?.lowercased() == shortcut.appKitCharacter
  }
}

extension VoiceShortcut {
  fileprivate var appKitCharacter: String {
    switch self {
    case .optionSpace, .controlOptionSpace, .shiftOptionSpace, .commandOptionSpace: " "
    case .optionV: "v"
    case .optionC: "c"
    case .optionD: "d"
    }
  }

  fileprivate var appKitModifiers: NSEvent.ModifierFlags {
    switch self {
    case .optionSpace, .optionV, .optionC, .optionD: .option
    case .controlOptionSpace: [.control, .option]
    case .shiftOptionSpace: [.shift, .option]
    case .commandOptionSpace: [.command, .option]
    }
  }
}
