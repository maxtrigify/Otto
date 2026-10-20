import AppKit
import SwiftUI
import Testing

@testable import OttoApp

@MainActor
@Suite("Composer scroll")
struct ComposerScrollTests {
  private func height(of text: String, maxHeight: CGFloat) async throws -> CGFloat {
    let view = TextField("Message", text: .constant(text), axis: .vertical)
      .textFieldStyle(.plain)
      .lineLimit(1...)
      .composerScroll(maxHeight: maxHeight)
      .frame(width: 320)
    let host = NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true))
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 1000),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    for _ in 0..<4 {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(40))
    }
    return host.fittingSize.height
  }

  @Test("Short text hugs the box; long text stops at the cap and scrolls")
  func capsHeight() async throws {
    let short = try await height(of: "Hello", maxHeight: 120)
    let long = try await height(
      of: Array(repeating: "A long line of text that wraps in the composer.", count: 40)
        .joined(separator: "\n"),
      maxHeight: 120)
    #expect(short > 4)
    #expect(short < 60)
    #expect(long == 120)
  }

  @Test("Drafts are kept per chat and cleared when emptied")
  func drafts() {
    let key = "test:\(UUID().uuidString)"
    ComposerDrafts.save("half a thought", for: key)
    #expect(ComposerDrafts.text(for: key) == "half a thought")
    ComposerDrafts.save("  ", for: key)
    #expect(ComposerDrafts.text(for: key) == "")
  }

  @Test("Unsent screenshots and pastes are kept per chat; missing images drop out")
  func attachmentDrafts() throws {
    let key = "test:\(UUID().uuidString)"
    let image = FileManager.default.temporaryDirectory
      .appending(path: "draft-\(UUID().uuidString).png").path
    try Data([0x89]).write(to: URL(fileURLWithPath: image))
    let gone = "/nonexistent/\(UUID().uuidString).png"
    ComposerDrafts.saveAttachments(
      .init(imagePaths: [image, gone], pastes: ["long paste"]), for: key)
    let restored = ComposerDrafts.attachments(for: key)
    #expect(restored.imagePaths == [image])
    #expect(restored.pastes == ["long paste"])
    ComposerDrafts.saveAttachments(.init(), for: key)
    #expect(ComposerDrafts.attachments(for: key).isEmpty)
    try? FileManager.default.removeItem(atPath: image)
  }
}

@Suite("Morning Home")
struct MorningHomeTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }

  private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(
      from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
  }

  @Test("Opens Home only when 6am passed while away")
  func boundary() {
    // Away overnight.
    #expect(
      MorningHome.shouldOpenHome(awaySince: date(13, 23), now: date(14, 8), calendar: calendar))
    // Working late past midnight is still the same day.
    #expect(
      !MorningHome.shouldOpenHome(awaySince: date(14, 1), now: date(14, 2), calendar: calendar))
    // A coffee break mid-morning.
    #expect(
      !MorningHome.shouldOpenHome(awaySince: date(14, 9), now: date(14, 10), calendar: calendar))
    // Left just before six, back just after.
    #expect(
      MorningHome.shouldOpenHome(
        awaySince: date(14, 5, 50), now: date(14, 6, 5), calendar: calendar))
    // Away the whole weekend.
    #expect(
      MorningHome.shouldOpenHome(awaySince: date(10, 18), now: date(12, 4), calendar: calendar))
  }
}
