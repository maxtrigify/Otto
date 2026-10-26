import AppKit
import Foundation
import OttoModels
import OttoServices
import SwiftUI
import Testing

@testable import OttoApp

/// Opt-in visual check of the Send Feedback sheet. Set OTTO_FEEDBACK_SNAPSHOT_DIR to run it.
@Suite("Feedback sheet snapshots")
@MainActor
struct FeedbackSheetSnapshotTests {
  @Test func renderFeedbackSheet() throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_FEEDBACK_SNAPSHOT_DIR"] else {
      return
    }
    let palette = OttoPalette(theme: OttoThemeCatalog.theme(id: "fieldNotes"))
    let client = FeedbackClient(
      endpoint: URL(string: "https://feedback.example.test/v1/feedback")!,
      installID: UUID().uuidString.lowercased(),
      environment: FeedbackEnvironment(
        appVersion: "0.2.0", build: "42", macOS: "26.1", architecture: "arm64", model: "Mac15,6"),
      transport: { _ in throw URLError(.notConnectedToInternet) })
    let screenshot = try FeedbackScreenshot.prepare(image: Self.sampleImage(palette: palette))
    let draft = FeedbackDraft(
      kind: .bug, title: "",
      description:
        "The sidebar stops scrolling after I open a long chat.\nI expected it to keep scrolling; instead it freezes until I switch places.",
      screenshot: screenshot)
    let states: [(String, FeedbackDraft, FeedbackSheet.Phase)] = [
      ("feedback-sheet", draft, .editing),
      ("feedback-sheet-empty", FeedbackDraft(kind: .idea), .editing),
      ("feedback-sheet-failed", draft, .failed(FeedbackError.offline.userMessage)),
      (
        "feedback-sheet-sent", draft,
        .sent(
          FeedbackSubmission(
            issueNumber: 17, issueURL: URL(string: "https://github.com/maxtrigify/Otto/issues/17")!)
        )
      ),
    ]
    for (name, draft, phase) in states {
      let view = FeedbackSheet(client: client, draft: draft, phase: phase, close: {})
        .environment(\.ottoPalette, palette)
      try render(view, to: "\(output)/\(name).png")
    }
  }

  private static func sampleImage(palette: OttoPalette) -> CGImage {
    let size = CGSize(width: 2400, height: 1500)
    let image = NSImage(size: size, flipped: false) { rect in
      NSColor(red: 0.06, green: 0.07, blue: 0.07, alpha: 1).setFill()
      rect.fill()
      NSColor(red: 0.8, green: 0.95, blue: 0.3, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: 520, height: rect.height).fill()
      NSColor(white: 0.9, alpha: 1).setFill()
      for row in 0..<12 {
        NSRect(x: 600, y: 120 + row * 100, width: 1500 - row * 60, height: 36).fill()
      }
      return true
    }
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
  }

  private func render<V: View>(_ view: V, to path: String) throws {
    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }
}
