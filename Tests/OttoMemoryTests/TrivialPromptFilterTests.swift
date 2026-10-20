import Foundation
import OttoMemory
import Testing

@Suite("Trivial prompt filter")
struct TrivialPromptFilterTests {
  @Test(
    "Bare conversational beats are trivial",
    arguments: [
      "hello", "Hello", "  hi  ", "hi!", "hey.", "yo", "ok", "OK!", "okay", "sure", "thanks",
      "Thank you", "thanks :)", "yep", "nope", "cool", "nice", "great", "done???", "next",
      "lgtm", "k", "continue", "go ahead", "do it", "proceed", "got it",
    ])
  func trivialPrompts(_ prompt: String) {
    #expect(TrivialPromptFilter.isTrivial(prompt))
  }

  @Test(
    "Anything carrying a task is kept",
    arguments: [
      // Prefix collisions with the trivial list — the anchoring is what saves these.
      "k8s cluster is down", "note the auth bug", "continue the migration from yesterday",
      "yolo deploy", "nice work, now fix the parser", "done with A, start B",
      "hi, can you check the widget runtime plan?", "ok so what broke in CI?",
      "what is intent data", "who owns the canvas notes decision",
    ])
  func substantivePrompts(_ prompt: String) {
    #expect(!TrivialPromptFilter.isTrivial(prompt))
  }

  @Test("Empty, whitespace, and nil carry no signal")
  func emptyPrompts() {
    #expect(TrivialPromptFilter.isTrivial(nil))
    #expect(TrivialPromptFilter.isTrivial(""))
    #expect(TrivialPromptFilter.isTrivial("   \n  "))
  }

  @Test("Slash commands are harness control, not work")
  func slashCommands() {
    #expect(TrivialPromptFilter.isTrivial("/clear"))
    #expect(TrivialPromptFilter.isTrivial("/model opus"))
  }

  @Test("Punctuation alone does not make a prompt substantive")
  func punctuationOnly() {
    #expect(TrivialPromptFilter.isTrivial("???"))
    #expect(TrivialPromptFilter.isTrivial("..."))
  }
}
