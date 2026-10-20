import Foundation
import OttoModels
import OttoServices
import Testing

@MainActor
@Suite("Office files from before the rename")
struct OfficeLegacyExtensionTests {
  @Test("New files use .ottosheet/.ottoslides; .musesheet/.museslides still open")
  func extensions() {
    #expect(OfficeKind.spreadsheet.fileExtension == "ottosheet")
    #expect(OfficeKind.presentation.fileExtension == "ottoslides")
    #expect(OfficeKind(fileExtension: "musesheet") == .spreadsheet)
    #expect(OfficeKind(fileExtension: "MUSESLIDES") == .presentation)
    #expect(OfficeKind(fileExtension: "ottosheet") == .spreadsheet)
    #expect(OfficeKind(fileExtension: "docx") == .document)
  }

  @Test("A legacy sheet is listed and loads; a new sheet with its title gets a fresh name")
  func legacyFilesStayUsable() throws {
    let workspace = FileManager.default.temporaryDirectory
      .appending(path: "otto-office-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let store = OfficeStore(workspacePath: workspace.path)
    let created = try store.create(.spreadsheet, title: "Budget")
    #expect(created.path == "Documents/Budget.ottosheet")
    // Simulate a file saved by Muse.
    try FileManager.default.moveItem(
      at: workspace.appending(path: created.path),
      to: workspace.appending(path: "Documents/Plan.musesheet"))
    store.refresh()
    let legacy = try #require(store.file(named: "Plan"))
    #expect(legacy.kind == .spreadsheet)
    _ = try store.loadWorkbook(path: legacy.path)
    let fresh = try store.create(.spreadsheet, title: "Plan")
    #expect(fresh.path == "Documents/Plan 2.ottosheet")
  }
}
