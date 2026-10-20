import AppKit
import OttoModels
import OttoRuntime
import SwiftUI
import Testing

@testable import OttoApp

@Suite("Paper question cards")
struct AgentChoiceCardTests {
  private var prompt: AgentChoicePrompt {
    AgentChoicePrompt(
      requestID: "question-1", question: "Where should I verify the new build?",
      choices: [
        "The Mac mini (Recommended) — A clean install, closest to a new customer’s setup.",
        "This MacBook — Fastest to check, but it already trusts the developer certificate.",
        "Both, starting with the mini — Broader coverage. Adds about ten minutes.",
      ])
  }

  @Test func separatesDisplayCopyWithoutChangingAnswer() {
    let option = AgentChoiceOption(prompt.choices[0])
    #expect(option.title == "The Mac mini")
    #expect(option.recommended)
    #expect(option.detail == "A clean install, closest to a new customer’s setup.")
    #expect(AgentChoiceOption("A — B — C").detail == "B — C")
    #expect(!AgentChoiceOption("Recommended approach").recommended)
    var state = AgentChoiceCardState()
    #expect(state.choose(0, in: prompt) == prompt.choices[0])
    #expect(state.choose(1, in: prompt) == nil)
  }

  @Test func multipleChoicesWaitForContinueAndPreserveOptionOrder() {
    var multi = prompt
    multi.multiSelect = true
    var state = AgentChoiceCardState()
    #expect(state.continueWithSelection(in: multi) == nil)
    #expect(state.choose(2, in: multi) == nil)
    #expect(state.choose(0, in: multi) == nil)
    #expect(state.choose(1, in: multi) == nil)
    #expect(state.choose(1, in: multi) == nil)
    #expect(state.submittedAnswer == nil)
    #expect(
      state.continueWithSelection(in: multi)
        == [multi.choices[0], multi.choices[2]].joined(separator: ", "))
    #expect(state.continueWithSelection(in: multi) == nil)
  }

  @Test func customAnswerRejectsWhitespaceAndSubmitsOnlyOnce() {
    var state = AgentChoiceCardState()
    #expect(state.submit(" \n ") == nil)
    #expect(
      state.submit("Use the mini, but check voice first.") == "Use the mini, but check voice first."
    )
    #expect(state.submit("Duplicate click") == nil)
    #expect(state.choose(-1, in: prompt) == nil)
  }

  @Test @MainActor func themeButtonTextMeetsContrast() {
    for theme in OttoThemeCatalog.all {
      #expect(
        OttoPalette.signalForegroundColor(for: theme).contrastRatio(with: theme.signal) >= 4.5)
    }
    var custom = OttoThemeCatalog.fieldNotes
    custom.signal = ThemeColor(red: 0.5, green: 0.5, blue: 0.5)
    #expect(
      OttoPalette.signalForegroundColor(for: custom).contrastRatio(with: custom.signal) >= 4.5)
    custom.signal = custom.raised
    #expect(OttoPalette.choiceAccentColor(for: custom) == custom.paper)
  }

  /// Optional native SwiftUI captures for visual review, not pixel-golden assertions.
  @Test @MainActor func renderThemeAndWidthVariants() async throws {
    guard let directory = ProcessInfo.processInfo.environment["OTTO_CHOICE_SNAPSHOTS"] else {
      return
    }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let themes = OttoThemeCatalog.all.filter {
      ["glasswing", "nightspire", "field-notes"].contains($0.id)
    }
    _ = NSApplication.shared
    #expect(themes.count == 3)
    for theme in themes {
      for width in [390, 760] {
        for mode in ["single", "multi", "custom", "free", "answered"] {
          var question = prompt
          question.multiSelect = mode == "multi"
          if mode == "free" { question.choices = [] }
          var initial = AgentChoiceCardState()
          if mode == "multi" { initial.selected = [0, 1] }
          if mode == "custom" {
            initial.showsCustomAnswer = true
            initial.customAnswer = "Use the mini, but check the voice flow first."
          }
          if mode == "answered" { _ = initial.choose(0, in: question) }
          let palette = OttoPalette(theme: theme)
          let view = AgentChoiceCard(
            prompt: question, agentName: "Beck", scale: 1, palette: palette,
            initialState: initial, answer: { _ in }
          )
          .padding(16).frame(width: CGFloat(width)).background(palette.surface)
          let host = NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true))
          host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
          let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: width, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
          window.isReleasedWhenClosed = false
          window.contentView = host
          window.orderFront(nil)
          defer { window.close() }
          host.layoutSubtreeIfNeeded()
          let height = host.fittingSize.height
          #expect(height > 100)
          window.setContentSize(NSSize(width: CGFloat(width), height: height))
          host.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(80))
          let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let data = try #require(bitmap.representation(using: .png, properties: [:]))
          try data.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(
              "\(theme.id)-\(width)-\(mode).png"))
        }
      }
    }
  }
}
