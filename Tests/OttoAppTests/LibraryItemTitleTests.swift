import OttoModels
import Testing

@testable import OttoApp

/// Issue #86: every note in Files & notes read "Notes 1" … "Notes 25".
struct LibraryItemTitleTests {
  private func node(
    _ name: String, kind: NodeKind = .markdown, content: NodeContent?
  ) -> OttoNode {
    OttoNode(
      kind: kind, displayName: name, subtitle: "",
      frame: WorldRect(x: 0, y: 0, width: 10, height: 10), zIndex: 0, content: content)
  }

  @Test func placeholderNoteShowsItsFileName() {
    let note = node(
      "Notes 3", content: .markdown(relativePath: "plans/q4-launch_notes.md", text: ""))
    #expect(LibraryItemTitle.title(for: note) == "q4 launch notes")
  }

  @Test func placeholderNoteWithoutAFileShowsItsFirstHeading() {
    let note = node(
      "Notes 12", content: .markdown(relativePath: nil, text: "\n# Client check-ins\nBody"))
    #expect(LibraryItemTitle.title(for: note) == "Client check-ins")
  }

  @Test func placeholderMediaShowsItsFileName() {
    let clip = node(
      "Media 1", kind: .media, content: .media(source: "/Users/me/Movies/reel-cut.mov"))
    #expect(LibraryItemTitle.title(for: clip) == "reel cut")
  }

  @Test func aHeadingReadsBetterThanTheFileName() {
    let note = node(
      "Notes 4",
      content: .markdown(
        relativePath: "nightly-test/client-check-ins.md", text: "# Client check-ins\nWeekly"))
    #expect(LibraryItemTitle.title(for: note) == "Client check-ins")
  }

  @Test func aChosenNameIsKept() {
    let note = node(
      "Launch notes", content: .markdown(relativePath: "otto/goals.md", text: "# Goals"))
    #expect(LibraryItemTitle.title(for: note) == "Launch notes")
  }

  @Test func placeholderStaysWhenThereIsNothingBetter() {
    let note = node("Notes 4", content: .markdown(relativePath: "untitled.md", text: "   "))
    #expect(LibraryItemTitle.title(for: note) == "Notes 4")
  }

  @Test func aNewUntitledNoteKeepsItsPlaceholder() {
    let note = node("Notes 2", content: .markdown(relativePath: nil, text: "# Untitled\n"))
    #expect(LibraryItemTitle.title(for: note) == "Notes 2")
  }

  @Test func longFirstLinesAreShortened() {
    let long = String(repeating: "a", count: 80)
    let note = node("Notes 5", content: .markdown(relativePath: nil, text: long))
    #expect(LibraryItemTitle.title(for: note).count == 60)
  }

  @Test(arguments: ["Notes 1", "Media 22"])
  func placeholdersAreRecognised(name: String) {
    #expect(LibraryItemTitle.isPlaceholder(name))
  }

  @Test(arguments: ["Notes", "Notes 1a", "My Notes 2", "Launch notes"])
  func realNamesAreNotPlaceholders(name: String) {
    #expect(!LibraryItemTitle.isPlaceholder(name))
  }
}
