import OttoModels
import OttoRuntime
import OttoSecurity
import SwiftUI

struct ModelProviderSettingsView: View {
  @State private var provider = OttoHarnessProvider.openAI
  @State private var apiKey = ""
  @State private var configured: Set<OttoHarnessProvider> = []
  @State private var localURL = LocalModelConfiguration.exampleURL
  @State private var localModel = ""
  @State private var hasLocalSettings = false
  @State private var message: String?
  @State private var isError = false
  private let secrets: any SecretStore
  private let onLocalSaved: (() -> Void)?

  init(
    secrets: any SecretStore = makeDefaultSecretStore(),
    initialProvider: OttoHarnessProvider = .openAI,
    onLocalSaved: (() -> Void)? = nil
  ) {
    self.secrets = secrets
    self._provider = State(initialValue: initialProvider)
    self.onLocalSaved = onLocalSaved
  }

  var body: some View {
    Form {
      Section("Otto Harness model providers") {
        Picker("Configure provider", selection: $provider) {
          ForEach(OttoHarnessProvider.allCases) { candidate in
            Text(candidate.displayName).tag(candidate)
          }
        }
        .pickerStyle(.menu)
        .onChange(of: provider) { _, _ in
          // A partially entered secret must not follow the user to another provider.
          apiKey = ""
          message = nil
        }

        if provider == .local {
          TextField("API base URL (e.g. http://127.0.0.1:11434/v1)", text: $localURL)
            .textFieldStyle(.roundedBorder)
            .textContentType(.URL)
            .accessibilityIdentifier("local-model-url")
          TextField("Model ID (e.g. qwen3:8b)", text: $localModel)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("local-model-id")
          Button("Save local endpoint and model") { saveLocal() }
            .disabled(localURL.isEmpty || localModel.isEmpty)
          Text(
            "Connect to Ollama, LM Studio, llama.cpp or vLLM on this Mac or a private LAN. A key is optional. HTTP is allowed for private hosts, but keys sent over LAN HTTP are not encrypted; use HTTPS when possible. The server must support OpenAI Chat Completions."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          if hasLocalSettings {
            Label("Local endpoint configured", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
        }

        SecureField(
          provider == .local ? "Optional local server API key" : "\(provider.displayName) API key",
          text: $apiKey
        )
        .textFieldStyle(.roundedBorder)
        HStack {
          Button("Save securely") { Task { await save() } }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Remove key", role: .destructive) { Task { await remove() } }
            .disabled(!configured.contains(provider))
          Spacer()
          Label(
            configured.contains(provider)
              ? "Key stored"
              : (provider == .local ? "No key (optional)" : "No key stored"),
            systemImage: configured.contains(provider)
              ? "checkmark.shield.fill" : "key.slash"
          )
          .foregroundStyle(configured.contains(provider) ? .green : .secondary)
        }
        Text(
          "API keys stay in Otto's secure credential store. OpenAI and xAI keys are shared with Voice settings."
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
            Image(
              systemName:
                configured.contains(candidate) || (candidate == .local && hasLocalSettings)
                ? "checkmark.circle.fill" : "circle"
            )
            .foregroundStyle(
              configured.contains(candidate) || (candidate == .local && hasLocalSettings)
                ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
              Text(candidate.displayName)
              Text(
                candidate == .local
                  ? (LocalModelConfiguration.load()?.modelID
                    ?? "Configure an endpoint and model above")
                  : models.map(\.displayName).joined(separator: ", ")
              )
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

  private func saveLocal() {
    do {
      let configuration = try LocalModelConfiguration(baseURL: localURL, modelID: localModel)
      configuration.save()
      localURL = configuration.baseURL.absoluteString
      localModel = configuration.modelID
      hasLocalSettings = true
      ProviderModelCatalogStore.shared.invalidate()
      onLocalSaved?()
      message = "Local model saved. It is now available under Otto Harness → Model."
      isError = false
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
      if let local = LocalModelConfiguration.load() {
        localURL = local.baseURL.absoluteString
        localModel = local.modelID
        hasLocalSettings = true
      }
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
