import OttoServices
import SwiftUI

/// Explicit billing choice stays visible even when the rest of bot setup is collapsed.
struct BotCreationAccountPicker: View {
  @ObservedObject var accounts: ProviderAccountStore
  @Binding var selection: UUID?

  var body: some View {
    Picker("Account", selection: $selection) {
      Text(defaultLabel).tag(nil as UUID?)
      ForEach(accounts.accounts) { account in
        Text(account.name).tag(Optional(account.id))
      }
    }
    .help("Choose which subscription this bot uses.")
    .onChange(of: accounts.accounts.map(\.id)) { _, ids in
      if let selection, !ids.contains(selection) { self.selection = nil }
    }
  }

  private var defaultLabel: String {
    if let account = accounts.account(id: accounts.defaultAccountID) {
      return "Use default (\(account.name))"
    }
    return "Use default (this Mac’s login)"
  }
}
