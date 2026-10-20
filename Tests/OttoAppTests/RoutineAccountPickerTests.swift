import Foundation
import OttoModels
import OttoSecurity
import OttoServices
import Testing

@testable import OttoApp

@MainActor
@Suite("Automation account picker")
struct RoutineAccountPickerTests {
  @Test("Says what the default runs on and which accounts are signed in")
  func labels() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "acct-picker-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = ProviderAccountStore(
      rootDirectory: root, userHome: root, secrets: InMemorySecretStore())
    #expect(
      RoutineAccountPicker.defaultLabel(accounts: accounts, botAccountName: nil)
        == "This Mac’s login")
    let work = try accounts.create(name: "Work")
    let personal = try accounts.create(name: "Personal")
    try accounts.setDefault(work.id)
    #expect(
      RoutineAccountPicker.defaultLabel(accounts: accounts, botAccountName: nil)
        == "Default account (Work)")
    #expect(
      RoutineAccountPicker.defaultLabel(accounts: accounts, botAccountName: "Personal")
        == "The bot’s account (Personal)")

    let data = accounts.providerDataDirectory(accountID: work.id, provider: .codex)
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: data.appending(path: "auth.json"))
    #expect(RoutineAccountPicker.label(work, provider: .codex, accounts: accounts) == "Work")
    #expect(
      RoutineAccountPicker.label(personal, provider: .codex, accounts: accounts)
        == "Personal (not signed in to \(AgentProvider.codex.rawValue))")
  }
}
