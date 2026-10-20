import AppKit
import Testing

@testable import OttoApp

@Suite("Chat composer keys")
struct ChatComposerKeyTests {
  @Test("Shift-Return inserts a line while Return remains submission")
  func returnBehavior() {
    #expect(
      ChatComposerKeyPolicy.action(
        keyCode: 36,
        charactersIgnoringModifiers: "\r",
        modifiers: [.shift],
        pasteboardContainsImage: false
      ) == .insertLineBreak)
    #expect(
      ChatComposerKeyPolicy.action(
        keyCode: 36,
        charactersIgnoringModifiers: "\r",
        modifiers: [],
        pasteboardContainsImage: false
      ) == nil)
  }

  @Test("Image paste remains distinct from ordinary Command-V")
  func pasteBehavior() {
    #expect(
      ChatComposerKeyPolicy.action(
        keyCode: 9,
        charactersIgnoringModifiers: "v",
        modifiers: [.command],
        pasteboardContainsImage: true
      ) == .pasteImage)
    #expect(
      ChatComposerKeyPolicy.action(
        keyCode: 9,
        charactersIgnoringModifiers: "v",
        modifiers: [.command],
        pasteboardContainsImage: false
      ) == nil)
  }

  @Test("Large text paste becomes an attachment; image paste wins")
  func largeTextPasteBehavior() {
    #expect(
      ChatComposerKeyPolicy.action(
        keyCode: 9,
        charactersIgnoringModifiers: "v",
        modifiers: [.command],
        pasteboardContainsImage: false,
        pasteboardContainsLargeText: true
      ) == .pasteLargeText)
    #expect(
      ChatComposerKeyPolicy.action(
        keyCode: 9,
        charactersIgnoringModifiers: "v",
        modifiers: [.command],
        pasteboardContainsImage: true,
        pasteboardContainsLargeText: true
      ) == .pasteImage)
    #expect(
      ChatComposerKeyPolicy.action(
        keyCode: 9,
        charactersIgnoringModifiers: "v",
        modifiers: [.command, .shift],
        pasteboardContainsImage: false,
        pasteboardContainsLargeText: true
      ) == nil)
  }

  @Test("Only long or many-line pastes are attached")
  func pasteThresholds() {
    #expect(!ChatPastedText.shouldAttach("hello world"))
    #expect(!ChatPastedText.shouldAttach(String(repeating: "line\n", count: 5)))
    #expect(ChatPastedText.shouldAttach(String(repeating: "x", count: 1_000)))
    #expect(ChatPastedText.shouldAttach(String(repeating: "line\n", count: 15)))
    #expect(ChatPastedText(String(repeating: "line\n", count: 15)).lineCount == 15)
  }

  @Test("Pasted text round-trips through the sent prompt")
  func pastedTextRoundTrip() throws {
    let first = ChatPastedText("alpha\nbeta\n\ngamma")
    let second = ChatPastedText("<b>\"quoted\"</b>")
    let prompt = try #require(
      ChatPastedText.compose(typed: "Summarise these", pastes: [first, second]))
    #expect(prompt.contains("Summarise these"))
    #expect(prompt.contains("alpha\nbeta\n\ngamma"))

    let split = ChatPastedText.decompose(prompt)
    #expect(split.text == "Summarise these")
    #expect(split.pastes == [first.text, second.text])

    let pasteOnly = try #require(ChatPastedText.compose(typed: nil, pastes: [first]))
    #expect(ChatPastedText.decompose(pasteOnly) == ("", [first.text]))
    #expect(ChatPastedText.compose(typed: nil, pastes: []) == nil)
    #expect(ChatPastedText.decompose("plain message") == ("plain message", []))
  }

  @Test("Mention selection wraps in both keyboard directions")
  func mentionSelection() {
    #expect(MentionPickerPolicy.movedIndex(from: 0, delta: 1, count: 3) == 1)
    #expect(MentionPickerPolicy.movedIndex(from: 2, delta: 1, count: 3) == 0)
    #expect(MentionPickerPolicy.movedIndex(from: 0, delta: -1, count: 3) == 2)
    #expect(MentionPickerPolicy.movedIndex(from: 4, delta: 1, count: 0) == 0)
  }

  @Test("Working agents keep the enabled composer in the focus path")
  func workingAgentFocusPath() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repository.appending(path: "Sources/OttoApp/AgentConversationBody.swift"),
      encoding: .utf8
    )

    #expect(source.contains(".onChange(of: acceptsComposerInput)"))
    #expect(
      source.contains(
        "guard isSelected, presentation == .conversation, acceptsComposerInput else { return }"
      )
    )
  }
}
