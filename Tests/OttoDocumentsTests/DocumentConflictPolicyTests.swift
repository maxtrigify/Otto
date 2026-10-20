import OttoDocuments
import Testing

@Suite("Document conflict policy")
struct DocumentConflictPolicyTests {
  @Test("External changes apply when the editor has no local modifications")
  func cleanExternalChange() {
    #expect(
      DocumentConflictPolicy.decide(
        draft: "original",
        baseline: "original",
        isEditing: true,
        externalText: "external"
      ) == .apply("external"))
  }

  @Test("External changes preserve a modified draft and surface a conflict")
  func conflictingExternalChange() {
    #expect(
      DocumentConflictPolicy.decide(
        draft: "my unsaved edit",
        baseline: "original",
        isEditing: true,
        externalText: "agent edit"
      ) == .conflict(externalText: "agent edit"))
  }
}
