import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

struct BotSubagentsEditor: View {
  @ObservedObject var accounts: ProviderAccountStore
  @Binding var helpers: [BotSubagentConfiguration]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("SUBAGENTS").font(.headline)
      Text(
        "Choose the helpers this bot can use. Saving authorises it to send tasks to each selected account."
      )
      .font(.caption).foregroundStyle(.secondary)
      ForEach($helpers) { $helper in
        VStack(alignment: .leading, spacing: 8) {
          BotSubagentEditor(accounts: accounts, helper: $helper)
          Button("Remove helper", role: .destructive) {
            helpers.removeAll { $0.id == helper.id }
          }
        }
        .padding(12)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
      }
      Button("Add subagent", systemImage: "plus") {
        helpers.append(BotSubagentConfiguration(name: "Helper"))
      }

    }
  }
}

private struct BotSubagentEditor: View {
  @ObservedObject var accounts: ProviderAccountStore
  @ObservedObject private var catalog = ProviderModelCatalogStore.shared
  @Binding var helper: BotSubagentConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Helper name", text: $helper.name).textFieldStyle(.roundedBorder)
      TextField("Job or speciality", text: $helper.role).textFieldStyle(.roundedBorder)
      Picker("Provider", selection: $helper.provider) {
        Text("Codex").tag(AgentProvider.codex)
        Text("Claude Code").tag(AgentProvider.claudeCode)
      }
      Picker("Account", selection: $helper.accountID) {
        Text("This Mac’s login").tag(nil as UUID?)
        if let accountID = helper.accountID, accounts.account(id: accountID) == nil {
          Text("Unavailable — choose an account").tag(helper.accountID)
        }
        ForEach(accounts.accounts) { account in
          Text(account.name).tag(Optional(account.id))
        }
      }
      Picker("Model", selection: $helper.model) {
        Text("Provider default").tag(nil as String?)
        if let selected = helper.model, !models.contains(where: { $0.id == selected }) {
          Text("\(selected) (not in current catalog)").tag(Optional(selected))
        }
        ForEach(models, id: \.id) { model in
          Text(model.displayName).tag(Optional(model.id))
        }
      }
      if models.isEmpty {
        Text("No model catalog available for this account yet.").font(.caption).foregroundStyle(
          .secondary)
      }
    }
    .onChange(of: helper.accountID) { _, _ in helper.model = nil }
    .onChange(of: helper.provider) { _, _ in helper.model = nil }
    .task(id: catalog.request(for: helper.provider, accountID: helper.accountID)) {
      await catalog.load(helper.provider, accountID: helper.accountID)?.value
    }
  }

  private var models: [AgentModel] {
    catalog.catalog(for: helper.provider, accountID: helper.accountID)
      ?? (ProviderModelCatalogStore.isDiscovered(helper.provider)
        ? [] : AgentModelCatalog.options(for: helper.provider))
  }
}
