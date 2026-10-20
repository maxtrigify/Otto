import OttoModels
import OttoServices
import SwiftUI

/// Chooses which AI account (subscription or API key) runs an automation, so someone with two
/// Codex or two Claude Code subscriptions can pick the one that pays for it.
struct RoutineAccountPicker: View {
  @ObservedObject var accounts: ProviderAccountStore
  @Binding var accountID: UUID?
  /// The provider the automation runs on, used to say which accounts are signed in to it.
  let provider: AgentProvider?
  /// The bot's own account, when a bot runs it; nil means a fresh agent.
  let botAccountName: String?
  var showsLabel = true

  var body: some View {
    Picker("AI account", selection: $accountID) {
      Text(Self.defaultLabel(accounts: accounts, botAccountName: botAccountName))
        .tag(UUID?.none)
      ForEach(accounts.accounts) { account in
        Text(Self.label(account, provider: provider, accounts: accounts))
          .tag(Optional(account.id))
      }
    }
    .modifier(HiddenLabel(hidden: !showsLabel))
    .disabled(provider.map { !$0.supportsProviderAccounts } ?? false)
  }

  /// What "no choice" runs on: the bot's account, the default account, or this Mac's login.
  static func defaultLabel(accounts: ProviderAccountStore, botAccountName: String?) -> String {
    if let botAccountName { return "The bot’s account (\(botAccountName))" }
    if let name = accounts.account(id: accounts.defaultAccountID)?.name {
      return "Default account (\(name))"
    }
    return "This Mac’s login"
  }

  static func label(
    _ account: ProviderAccount, provider: AgentProvider?, accounts: ProviderAccountStore
  ) -> String {
    guard let provider, provider.supportsProviderAccounts,
      account.credentialMode(for: provider) == .login,
      !accounts.hasProviderLogin(accountID: account.id, provider: provider)
    else { return account.name }
    return "\(account.name) (not signed in to \(provider.rawValue))"
  }

  private struct HiddenLabel: ViewModifier {
    let hidden: Bool
    func body(content: Content) -> some View {
      if hidden { content.labelsHidden() } else { content }
    }
  }
}
