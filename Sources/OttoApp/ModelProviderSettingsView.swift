import OttoRuntime
import OttoSecurity
import SwiftUI

struct ModelProviderSettingsView: View {
  @State private var provider = OttoHarnessProvider.openAI
  @State private var apiKey = ""
  @State private var configured: Set<OttoHarnessProvider> = []
  @State private var message: String?
  @State private var isError = false
  private let secrets: any SecretStore

  init(secrets: any SecretStore = makeDefaultSecretStore()) {
    self.secrets = secrets
  }

  var body: some View {
    Form {
      Section("Otto Harness model providers") {
        Picker("Configure provider", selection: $provider) {
          ForEach(OttoHarnessProvider.allCases) { candidate in
            Text(candidate.displayName).tag(candidate)
          }
        }
        .pickerStyle(.segmented)

        SecureField("\(provider.displayName) API key", text: $apiKey)
          .textFieldStyle(.roundedBorder)
        HStack {
          Button("Save securely") { Task { await save() } }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Remove key", role: .destructive) { Task { await remove() } }
            .disabled(!configured.contains(provider))
          Spacer()
          Label(
            configured.contains(provider) ? "Key stored" : "No key stored",
            systemImage: configured.contains(provider)
              ? "checkmark.shield.fill" : "key.slash"
          )
          .foregroundStyle(configured.contains(provider) ? .green : .secondary)
        }
        Text(
          "Keys stay in Otto's secure credential store. OpenAI and xAI keys are shared with Voice settings."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if let message {
          Text(message).foregroundStyle(isError ? Color.red : Color.secondary)
        }
      }

      Section("Available in Otto Harness") {
        ForEach(OttoHarnessProvider.allCases) { candidate in
          let models = AgentModelCatalog.options(for: .openAI).filter {
            OttoHarnessModelSelection.resolve($0.id).provider == candidate
          }
          HStack(alignment: .top) {
            Image(systemName: configured.contains(candidate) ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(configured.contains(candidate) ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
              Text(candidate.displayName)
              Text(models.map(\.displayName).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .task { await refresh() }
  }

  private func save() async {
    do {
      try await secrets.set(
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.credentialKey)
      apiKey = ""
      message = "\(provider.displayName) key saved."
      isError = false
      await refresh(clearMessage: false)
    } catch {
      message = error.localizedDescription
      isError = true
    }
  }

  private func remove() async {
    do {
      try await secrets.delete(provider.credentialKey)
      apiKey = ""
      message = "\(provider.displayName) key removed."
      isError = false
      await refresh(clearMessage: false)
    } catch {
      message = error.localizedDescription
      isError = true
    }
  }

  private func refresh(clearMessage: Bool = true) async {
    do {
      var result: Set<OttoHarnessProvider> = []
      for candidate in OttoHarnessProvider.allCases {
        if try await !(secrets.value(for: candidate.credentialKey) ?? "").isEmpty {
          result.insert(candidate)
        }
      }
      configured = result
      if clearMessage { message = nil }
    } catch {
      message = error.localizedDescription
      isError = true
    }
  }
}
