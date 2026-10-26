import AppKit
import OttoModels
import SwiftUI
import Testing

@testable import OttoApp

@Suite("Profile keyboard switching") @MainActor
struct ProfileKeyboardSwitcherTests {
  private let profiles = ["Muse Home", "Smuggler", "Ironman"].map {
    OttoProfile(name: $0, symbol: "house", workspacePath: "/fixtures/\($0)")
  }

  @Test func quickTapSelectsPreviousAndCyclesWithoutReordering() {
    var selection = ProfileCycleSelection()
    let gestureResult1 = selection.cycle(profiles: profiles)
    #expect(gestureResult1)
    #expect(selection.selectedID == profiles[1].id)
    let gestureResult2 = selection.cycle(profiles: profiles.reversed())
    #expect(gestureResult2)
    #expect(selection.selectedID == profiles[2].id)
    #expect(selection.profiles == profiles)
    selection.advance(backwards: false)
    #expect(selection.selectedID == profiles[0].id)
    selection.advance(backwards: true)
    #expect(selection.selectedID == profiles[2].id)
    selection.cancel()
    #expect(selection.selectedID == nil)
    #expect(selection.profiles.isEmpty)
  }

  @Test func backwardsAndSingleProfile() {
    var selection = ProfileCycleSelection()
    let gestureResult3 = !selection.cycle(profiles: [])
    #expect(gestureResult3)
    let gestureResult4 = !selection.cycle(profiles: [profiles[0]])
    #expect(gestureResult4)
    let gestureResult5 = selection.cycle(profiles: profiles, backwards: true)
    #expect(gestureResult5)
    #expect(selection.selectedID == profiles[2].id)
  }

  @Test func keyboardReleaseEscapeAndModifierBoundaries() throws {
    func event(
      _ type: NSEvent.EventType = .keyDown, key: UInt16 = 48,
      flags: NSEvent.ModifierFlags = .option
    ) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: flags,
          timestamp: 0, windowNumber: 0, context: nil, characters: "\t",
          charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: key))
    }
    var selection = ProfileCycleSelection()
    let gestureResult6 =
      selection.handle(try event(flags: .control), available: profiles) == .ignored
    #expect(gestureResult6)
    let gestureResult7 =
      selection.handle(try event(flags: [.command, .option]), available: profiles) == .ignored
    #expect(gestureResult7)
    let gestureResult8 = selection.handle(try event(), available: profiles) == .consumed
    #expect(gestureResult8)
    #expect(selection.selectedID == profiles[1].id)
    let gestureResult9 =
      selection.handle(try event(.flagsChanged, flags: []), available: profiles) == .commit
    #expect(gestureResult9)
    selection.cancel()
    let gestureResult10 = selection.handle(try event(), available: profiles) == .consumed
    #expect(gestureResult10)
    let gestureResult11 = selection.handle(try event(key: 53), available: profiles) == .consumed
    #expect(gestureResult11)
    let gestureResult12 =
      selection.handle(try event(.flagsChanged, flags: []), available: profiles) == .ignored
    #expect(gestureResult12)
    let gestureResult13 =
      selection.handle(try event(flags: [.option, .shift]), available: profiles) == .consumed
    #expect(gestureResult13)
    #expect(selection.selectedID == profiles[2].id)
  }

  @Test func monitorOnlyHandlesOwningKeyWindowAndCancelsOnFocusLoss() throws {
    _ = NSApplication.shared
    let window = ShortcutTestWindow(
      contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let view = NSView()
    window.contentView = view
    var handled = 0
    var cancelled = 0
    let coordinator = ProfileShortcutEvents.Coordinator(
      handle: { _ in
        handled += 1
        return true
      }, cancel: { cancelled += 1 })
    coordinator.view = view
    coordinator.start()
    defer { coordinator.stop() }
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil,
        characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
    #expect(coordinator.route(event) != nil)
    #expect(handled == 0)
    window.testIsKey = true
    #expect(coordinator.route(event) == nil)
    #expect(handled == 1)
    window.testSheet = NSWindow()
    #expect(coordinator.route(event) != nil)
    #expect(handled == 1)
    window.testSheet = nil
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: NSWindow())
    #expect(cancelled == 0)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(cancelled == 1)
    coordinator.view = nil
    #expect(coordinator.route(event) != nil)
    #expect(handled == 1)
  }

  @Test func renderSwitcher() throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_PROFILE_SNAPSHOT_DIR"] else {
      return
    }
    let view = ProfileCycleOverlay(
      profiles: profiles, selectedID: profiles[1].id, choose: { _ in }, cancel: {})
    let host = NSHostingView(rootView: view.frame(width: 900, height: 550))
    host.frame = CGRect(x: 0, y: 0, width: 900, height: 550)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    try data.write(to: URL(fileURLWithPath: output).appending(path: "profile-switcher.png"))
  }
}

@MainActor private final class ShortcutTestWindow: NSWindow {
  var testIsKey = false
  var testSheet: NSWindow?
  override var isKeyWindow: Bool { testIsKey }
  override var attachedSheet: NSWindow? { testSheet }
}
