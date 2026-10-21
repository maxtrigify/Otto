import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import OttoApplicationTools
import OttoCommercial
import OttoModels
import OttoRPCContracts
import OttoRuntime
import OttoSecurity
import OttoServices
import SwiftUI

struct MobileSettingsView: View {
  @ObservedObject var services: ApplicationServices
  @State private var isRefreshing = false
  @State private var refreshError: String?
  @State private var isRefreshingRemote = false
  @State private var remoteRefreshError: String?
  @State private var remoteLicenseKey = ""
  @State private var isActivatingRemote = false
  @State private var isRefreshingSubscription = false
  @State private var subscriptionMessage: String?

  var body: some View {
    Form {
      Section("Pair nearby") {
        if let payload = services.mobilePairingPayload, services.mobileHostEndpoint != nil {
          HStack(alignment: .top, spacing: 22) {
            pairingCode(payload)
            VStack(alignment: .leading, spacing: 10) {
              Text(payload.environmentName)
                .font(.title3.weight(.semibold))
              Label(payload.baseURL.absoluteString, systemImage: "network")
              Label(
                "Fingerprint \(payload.fingerprint.prefix(12))…",
                systemImage: "checkmark.seal"
              )
              Label(
                "Expires \(payload.expiresAt.formatted(date: .omitted, time: .shortened))",
                systemImage: "timer"
              )
              Text(
                "Open Otto on your iPhone and scan this one-time code. Files, provider credentials, and the agent runtime stay on this Mac."
              )
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
        } else if let error = services.mobileHostError {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        } else if services.isStartingMobileHost {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Starting the local mobile host…")
              .foregroundStyle(.secondary)
          }
        } else {
          Text("The local mobile host is not running.")
            .foregroundStyle(.secondary)
        }

        HStack {
          if let refreshError {
            Text(refreshError)
              .font(.callout)
              .foregroundStyle(.red)
          }
          Spacer()
          if services.mobileHostEndpoint == nil {
            Button("Retry connection") {
              Task { await services.startMobileHostIfConfigured() }
            }
            .disabled(services.isStartingMobileHost)
          }
          Button(isRefreshing ? "Creating code…" : "Create a new code") {
            Task { await refreshOffer() }
          }
          .disabled(isRefreshing || services.mobileHostEndpoint == nil)
        }
      }

      Section("Remote Access") {
        if services.managedMobilePairingIsConfigured {
          remoteSubscriptionPanel
        }

        if let payload = services.managedMobilePairingPayload {
          HStack(alignment: .top, spacing: 22) {
            managedPairingCode(payload)
            VStack(alignment: .leading, spacing: 10) {
              Text("Your Otto, wherever you are")
                .font(.title3.weight(.semibold))
              Label(
                payload.controlPlaneURL.host ?? payload.controlPlaneURL.absoluteString,
                systemImage: "network.badge.shield.half.filled"
              )
              Label("One-time device registration", systemImage: "iphone.gen3.badge.checkmark")
              Label(
                "Expires \(payload.expiresAt.formatted(date: .omitted, time: .shortened))",
                systemImage: "timer"
              )
              Text(
                "Scan with Otto on your iPhone to reconnect through the managed relay. This code contains no account or device credential; agents, files, and provider credentials stay on this Mac."
              )
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
        } else if services.managedMobilePairingIsConfigured,
          services.managedRemoteSubscriptionStatus == nil
        {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Checking Otto Remote access…")
              .foregroundStyle(.secondary)
          }
        } else if services.managedMobilePairingIsConfigured {
          Text("Activate Otto Remote above to create a hosted pairing code.")
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          ContentUnavailableView(
            "Remote Access is not configured",
            systemImage: "network.slash",
            description: Text("A managed Otto account and outbound Mac connector are required.")
          )
        }

        HStack {
          if let remoteRefreshError {
            Text(remoteRefreshError)
              .font(.callout)
              .foregroundStyle(.red)
          }
          Spacer()
          Button(isRefreshingRemote ? "Creating code…" : "Create a new remote code") {
            Task { await refreshRemoteOffer() }
          }
          .disabled(
            isRefreshingRemote || !services.managedMobilePairingIsConfigured
              || services.managedRemoteSubscriptionStatus?.state != .active
          )
        }
      }

      Section("Connection") {
        LabeledContent("Host") {
          Text(
            services.mobileHostEndpoint?.absoluteString
              ?? (services.isStartingMobileHost ? "Starting…" : "Not running")
          )
          .textSelection(.enabled)
        }
        Text(
          "The default endpoint is available only on this Mac. Internal builds can advertise a private HTTPS Tailscale URL with OTTO_MOBILE_HOST_PUBLIC_URL."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .frame(width: 680, height: 650)
    .task {
      if services.mobilePairingPayload == nil, services.mobileHostEndpoint != nil {
        await refreshOffer()
      }
      if services.managedMobilePairingIsConfigured {
        await loadRemoteSubscriptionStatus()
        if services.managedMobilePairingPayload == nil,
          services.managedRemoteSubscriptionStatus?.state == .active
        {
          await refreshRemoteOffer()
        }
      }
    }
  }

  @ViewBuilder
  private var remoteSubscriptionPanel: some View {
    switch services.managedRemoteSubscriptionStatus?.state {
    case .active:
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "checkmark.seal.fill")
          .foregroundStyle(.green)
        VStack(alignment: .leading, spacing: 4) {
          Text("Otto Remote is active")
            .font(.headline)
          if let status = services.managedRemoteSubscriptionStatus {
            Text(
              [
                status.plan?.capitalized,
                status.expiresAt.map {
                  "Valid through \($0.formatted(date: .abbreviated, time: .shortened))"
                },
              ].compactMap { $0 }.joined(separator: " · ")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
          }
          Text(
            "This entitlement covers only the hosted relay. Nearby and Tailscale pairing stay local and do not require it."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Button(isRefreshingSubscription ? "Refreshing…" : "Refresh entitlement") {
          Task { await refreshRemoteSubscription() }
        }
        .disabled(isRefreshingSubscription)
      }
      .padding(12)
      .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

    case .missing, .expired:
      VStack(alignment: .leading, spacing: 10) {
        Label(
          services.managedRemoteSubscriptionStatus?.state == .expired
            ? "Otto Remote entitlement expired" : "Activate Otto Remote",
          systemImage: "network.badge.shield.half.filled"
        )
        .font(.headline)
        Text(
          "Hosted relay access uses a separate Otto licence. Nearby and Tailscale pairing remain available without it."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        HStack {
          SecureField("Otto Remote licence key", text: $remoteLicenseKey)
            .textContentType(.password)
          Button(isActivatingRemote ? "Activating…" : "Activate") {
            Task { await activateRemoteSubscription() }
          }
          .disabled(
            isActivatingRemote
              || remoteLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
        }
        if let subscriptionMessage {
          Text(subscriptionMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(12)
      .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

    case nil:
      HStack(spacing: 10) {
        ProgressView().controlSize(.small)
        Text("Checking signed entitlement…")
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func pairingCode(_ payload: OttoMobilePairingPayload) -> some View {
    if let value = try? payload.qrString(), let image = qrImage(value) {
      Image(nsImage: image)
        .interpolation(.none)
        .resizable()
        .frame(width: 196, height: 196)
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Otto mobile pairing QR code")
    } else {
      ContentUnavailableView("Could not render code", systemImage: "qrcode")
        .frame(width: 216, height: 216)
    }
  }

  @ViewBuilder
  private func managedPairingCode(_ payload: ManagedRemotePairingPayload) -> some View {
    if let value = try? payload.qrString(), let image = qrImage(value) {
      Image(nsImage: image)
        .interpolation(.none)
        .resizable()
        .frame(width: 196, height: 196)
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("Otto managed mobile pairing QR code")
    } else {
      ContentUnavailableView("Could not render code", systemImage: "qrcode")
        .frame(width: 216, height: 216)
    }
  }

  private func qrImage(_ value: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
      let cgImage = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(
      cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
  }

  @MainActor
  private func refreshOffer() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      _ = try await services.refreshMobilePairingOffer()
      refreshError = nil
    } catch {
      refreshError = error.localizedDescription
    }
  }

  @MainActor
  private func refreshRemoteOffer() async {
    guard !isRefreshingRemote else { return }
    isRefreshingRemote = true
    defer { isRefreshingRemote = false }
    do {
      _ = try await services.refreshManagedMobilePairingOffer()
      remoteRefreshError = nil
    } catch {
      remoteRefreshError = error.localizedDescription
    }
  }

  @MainActor
  private func loadRemoteSubscriptionStatus() async {
    do {
      _ = try await services.refreshManagedRemoteSubscriptionStatus()
      subscriptionMessage = nil
    } catch {
      subscriptionMessage = error.localizedDescription
    }
  }

  @MainActor
  private func activateRemoteSubscription() async {
    guard !isActivatingRemote else { return }
    isActivatingRemote = true
    defer { isActivatingRemote = false }
    do {
      _ = try await services.activateManagedRemoteSubscription(
        licenseKey: remoteLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
      )
      remoteLicenseKey = ""
      subscriptionMessage = "Otto Remote activated on this Mac."
      remoteRefreshError = nil
    } catch {
      subscriptionMessage = error.localizedDescription
    }
  }

  @MainActor
  private func refreshRemoteSubscription() async {
    guard !isRefreshingSubscription else { return }
    isRefreshingSubscription = true
    defer { isRefreshingSubscription = false }
    do {
      _ = try await services.refreshManagedRemoteSubscription()
      subscriptionMessage = "Entitlement refreshed."
      remoteRefreshError = nil
    } catch {
      subscriptionMessage = error.localizedDescription
    }
  }
}

struct AppearanceSettingsView: View {
  @AppStorage(OttoPreferenceKey.fontScale) private var fontScaleRaw = OttoFontScale.standard
    .rawValue
  @AppStorage(OttoPreferenceKey.matteOpacity) private var matteOpacity = 0.0

  var body: some View {
    Form {
      Picker("Text size", selection: $fontScaleRaw) {
        ForEach(OttoFontScale.allCases, id: \.rawValue) { scale in
          Text(scale.label).tag(scale.rawValue)
        }
      }
      Section("Matte theme") {
        Slider(value: matteOpacityBinding, in: OttoMatteTransparency.range) {
          Text("Surface opacity")
        } minimumValueLabel: {
          Text("Sheer")
        } maximumValueLabel: {
          Text("Solid")
        }
        HStack {
          Text(matteOpacityLabel)
            .font(.callout)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Use theme default") { matteOpacity = 0 }
            .disabled(matteOpacity <= 0)
        }
        Text(
          "Applies to Velvet and Nightscreen. "
            + "Window glass uses a separate, deliberately sheer acrylic density."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .frame(width: 520, height: 360)
  }

  /// Slider shows the resolved value; dragging always writes an explicit preference.
  private var matteOpacityBinding: Binding<Double> {
    Binding(
      get: {
        OttoMatteTransparency.resolve(
          preference: matteOpacity > 0 ? matteOpacity : nil,
          themeDefault: OttoThemeCatalog.velvet.nodeOpacity)
      },
      set: { matteOpacity = OttoMatteTransparency.clamped($0) }
    )
  }

  private var matteOpacityLabel: String {
    matteOpacity > 0
      ? "\(Int((matteOpacityBinding.wrappedValue * 100).rounded()))% opaque"
      : "Theme default"
  }
}

struct AgentDefaultsSettingsView: View {
  @AppStorage(OttoPreferenceKey.agentNamingMode) private var namingModeRaw = AgentNamingMode.otto
    .rawValue
  @AppStorage(OttoPreferenceKey.agentDefaultView) private var defaultViewRaw = AgentDefaultView.chat
    .rawValue
  @AppStorage(OttoPreferenceKey.claudePermissionMode) private var claudePermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.codexPermissionMode) private var codexPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.hermesPermissionMode) private var hermesPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.cursorPermissionMode) private var cursorPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.kimiPermissionMode) private var kimiPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.openCodePermissionMode) private var openCodePermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.grokPermissionMode) private var grokPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.shellPermissionMode) private var shellPermission =
    AgentPermissionMode.workspaceWrite.rawValue
  @AppStorage(OttoPreferenceKey.hermesConnectionMode) private var hermesModeRaw =
    HermesConnectionMode.local.rawValue
  @AppStorage(OttoPreferenceKey.hermesRemoteURL) private var hermesRemoteURL = ""
  @AppStorage(OttoPreferenceKey.hermesRemoteProfile) private var hermesRemoteProfile = ""
  @AppStorage(OttoPreferenceKey.hermesRemoteWorkingDirectory) private var hermesRemoteDirectory = ""
  @State private var customNamesText = ""
  @State private var hermesToken = ""
  @State private var hermesStatus = "Not tested"
  @State private var hermesStatusIsError = false
  @State private var testingHermes = false
  @State private var hermesProfiles: [HermesRemoteProfile] = []
  @State private var loadingHermesProfiles = false
  @State private var hermesProfileDiscoveryError: String?
  @State private var showsManualHermesProfile = false
  private let secrets = makeDefaultSecretStore()

  var body: some View {
    Form {
      Picker("Naming", selection: $namingModeRaw) {
        Text("Otto roster").tag(AgentNamingMode.otto.rawValue)
        Text("Custom roster").tag(AgentNamingMode.custom.rawValue)
      }
      if namingModeRaw == AgentNamingMode.custom.rawValue {
        TextField("Names separated by commas", text: $customNamesText)
          .onSubmit(saveNames)
        Button("Save custom roster", action: saveNames)
          .disabled(parsedNames.isEmpty)
      }
      Section("Default view") {
        Picker("Open new agents in", selection: $defaultViewRaw) {
          Label("Chat", systemImage: "bubble.left.and.bubble.right").tag(
            AgentDefaultView.chat.rawValue)
          Label("Terminal", systemImage: "terminal").tag(AgentDefaultView.terminal.rawValue)
        }
        .pickerStyle(.segmented)
        Text(
          "Agents launched with a task may begin in the rail. Opening them restores this view. Existing agents keep their current view."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      Section("Hermes connection") {
        HStack(spacing: 12) {
          connectionCard(
            mode: .local,
            title: "Local Hermes",
            detail: "Run the Hermes installation on this Mac. Works offline with local models.",
            symbol: "desktopcomputer"
          )
          connectionCard(
            mode: .remote,
            title: "Remote backend",
            detail: "Connect through a tunnel to a running hermes serve backend.",
            symbol: "network"
          )
        }
        if hermesMode == .remote {
          TextField("Remote URL, for example http://host:9119", text: $hermesRemoteURL)
            .textContentType(.URL)
          SecureField("Session token (leave blank to reuse Keychain)", text: $hermesToken)
          HStack {
            Picker("Hermes profile", selection: $hermesRemoteProfile) {
              Text("Use gateway default").tag("")
              ForEach(selectableHermesProfiles) { profile in
                Text(hermesProfileLabel(profile)).tag(profile.name)
              }
            }
            Button {
              Task { await refreshHermesProfiles() }
            } label: {
              if loadingHermesProfiles {
                ProgressView().controlSize(.small)
              } else {
                Image(systemName: "arrow.clockwise")
              }
            }
            .buttonStyle(.borderless)
            .disabled(loadingHermesProfiles || normalizedRemoteURL == nil)
            .help("Refresh profiles from the Hermes backend")
          }
          if let hermesProfileDiscoveryError {
            Text(hermesProfileDiscoveryError)
              .font(.callout)
              .foregroundStyle(.secondary)
            Toggle("Enter a profile name manually", isOn: $showsManualHermesProfile)
          }
          if showsManualHermesProfile {
            TextField("Hermes profile name", text: $hermesRemoteProfile)
          }
          Text(
            "The profile owns its model, provider, memory, and skills. Otto passes the profile name but never replaces its model."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          TextField("Remote working directory (optional)", text: $hermesRemoteDirectory)
          Text(
            "The directory is resolved on the remote Hermes host. Local Otto worktrees are disabled in this mode."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        HStack {
          Circle()
            .fill(hermesStatusIsError ? Color.red : Color.secondary)
            .frame(width: 7, height: 7)
          Text(hermesStatus).font(.callout).foregroundStyle(.secondary)
          Spacer()
          if hermesMode == .remote {
            Button("Forget token", action: forgetHermesToken)
          }
          Button(testingHermes ? "Testing…" : "Save and test", action: saveAndTestHermes)
            .disabled(testingHermes || (hermesMode == .remote && normalizedRemoteURL == nil))
        }
      }
      Section("Default permissions") {
        permissionPicker("Claude Code", selection: $claudePermission)
        permissionPicker("Codex", selection: $codexPermission)
        permissionPicker("Hermes", selection: $hermesPermission)
        permissionPicker("Cursor", selection: $cursorPermission)
        permissionPicker("Kimi", selection: $kimiPermission)
        permissionPicker("OpenCode", selection: $openCodePermission)
        permissionPicker("Grok", selection: $grokPermission)
        permissionPicker("Shell", selection: $shellPermission)
        Text(
          "Applied when launching new agents; each launch can still override. "
            + "Read only plans without editing (Claude plan mode, Codex read-only sandbox, Grok plan + read-only sandbox). "
            + "Hermes supports approval prompts and bypass mode but not a strict read-only sandbox. "
            + "Kimi has no OS sandbox and its chat runs always auto-approve tool calls, so "
            + "read only there applies to its terminal, which opens in plan mode. "
            + "Ask to approve pauses for risky actions so you approve them in chat. "
            + "Bypass permissions never asks."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .frame(width: 650, height: 760)
    .onAppear {
      customNamesText =
        UserDefaults.standard.stringArray(forKey: OttoPreferenceKey.agentCustomNames)?
        .joined(separator: ", ") ?? ""
      Task {
        if (try? await secrets.value(for: OttoPreferenceKey.hermesSessionTokenSecret)) != nil {
          hermesStatus = "Saved session token available"
          if hermesMode == .remote { await refreshHermesProfiles() }
        }
      }
    }
  }

  private var parsedNames: [String] {
    AgentNamingPolicy.normalized(customNamesText.split(separator: ",").map(String.init))
  }

  private func saveNames() {
    guard !parsedNames.isEmpty else { return }
    UserDefaults.standard.set(parsedNames, forKey: OttoPreferenceKey.agentCustomNames)
    namingModeRaw = AgentNamingMode.custom.rawValue
  }

  private func permissionPicker(_ title: String, selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      ForEach(AgentPermissionMode.allCases, id: \.rawValue) { mode in
        Text(permissionLabel(mode)).tag(mode.rawValue)
      }
    }
  }

  private func permissionLabel(_ mode: AgentPermissionMode) -> String {
    switch mode {
    case .readOnly: "Read only"
    case .workspaceWrite: "Ask to approve (workspace write)"
    case .unrestricted: "Bypass all permissions"
    }
  }

  private var hermesMode: HermesConnectionMode {
    HermesConnectionMode(rawValue: hermesModeRaw) ?? .local
  }

  private var normalizedRemoteURL: URL? {
    HermesConnectionConfiguration(
      mode: .remote,
      remoteURL: hermesRemoteURL,
      remoteProfile: hermesRemoteProfile,
      remoteWorkingDirectory: hermesRemoteDirectory
    ).normalizedRemoteURL
  }

  private var selectableHermesProfiles: [HermesRemoteProfile] {
    var profiles = hermesProfiles
    let selected = hermesRemoteProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    if !selected.isEmpty, !profiles.contains(where: { $0.name == selected }) {
      profiles.insert(HermesRemoteProfile(name: selected), at: 0)
    }
    return profiles
  }

  private func hermesProfileLabel(_ profile: HermesRemoteProfile) -> String {
    let details = [profile.provider, profile.model]
      .compactMap { value in
        guard let value, !value.isEmpty else { return nil }
        return value
      }
      .joined(separator: " · ")
    let name = profile.isDefault ? "\(profile.name) (default)" : profile.name
    return details.isEmpty ? name : "\(name) — \(details)"
  }

  private func connectionCard(
    mode: HermesConnectionMode,
    title: String,
    detail: String,
    symbol: String
  ) -> some View {
    let selected = hermesMode == mode
    return Button {
      hermesModeRaw = mode.rawValue
      hermesStatus = mode == .local ? "Uses the Hermes CLI on this Mac" : "Not tested"
      hermesStatusIsError = false
      if mode == .remote {
        Task { await refreshHermesProfiles() }
      }
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Image(systemName: symbol)
          Text(title).font(.headline)
          Spacer()
          if selected { Image(systemName: "checkmark.circle.fill") }
        }
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(14)
      .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
      .background(
        selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
        in: RoundedRectangle(cornerRadius: 12)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(
            selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1
          )
      )
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func saveAndTestHermes() {
    testingHermes = true
    hermesStatus = "Testing connection…"
    hermesStatusIsError = false
    let configuration = HermesConnectionConfiguration(
      mode: hermesMode,
      remoteURL: hermesRemoteURL,
      remoteProfile: hermesRemoteProfile,
      remoteWorkingDirectory: hermesRemoteDirectory
    )
    configuration.save()
    Task {
      do {
        if configuration.mode == .remote, !hermesToken.isEmpty {
          try await secrets.set(hermesToken, for: OttoPreferenceKey.hermesSessionTokenSecret)
          hermesToken = ""
        }
        switch await HermesAdapter(configurationProvider: { configuration }).detectInstallation() {
        case .installed(_, let version):
          hermesStatus =
            configuration.mode == .local
            ? "Local Hermes ready · \(version)" : "Remote backend connected"
          hermesStatusIsError = false
          if configuration.mode == .remote { await refreshHermesProfiles() }
        case .missing(let remediation):
          hermesStatus = remediation
          hermesStatusIsError = true
        }
      } catch {
        hermesStatus = error.localizedDescription
        hermesStatusIsError = true
      }
      testingHermes = false
    }
  }

  private func refreshHermesProfiles() async {
    guard hermesMode == .remote, let baseURL = normalizedRemoteURL else { return }
    let typedToken = hermesToken.trimmingCharacters(in: .whitespacesAndNewlines)
    let token =
      typedToken.isEmpty
      ? (try? await secrets.value(for: OttoPreferenceKey.hermesSessionTokenSecret)) : typedToken
    guard let token, !token.isEmpty else {
      hermesProfileDiscoveryError = "Save a session token to load the profile list."
      showsManualHermesProfile = true
      return
    }
    loadingHermesProfiles = true
    hermesProfileDiscoveryError = nil
    do {
      hermesProfiles = try await HermesRemoteProfileCatalog().profiles(
        baseURL: baseURL,
        sessionToken: token
      )
      showsManualHermesProfile = false
    } catch {
      hermesProfileDiscoveryError =
        "Couldn’t load profiles automatically. You can still enter a profile name manually."
      showsManualHermesProfile = true
    }
    loadingHermesProfiles = false
  }

  private func forgetHermesToken() {
    Task {
      try? await secrets.delete(OttoPreferenceKey.hermesSessionTokenSecret)
      hermesToken = ""
      hermesStatus = "Session token removed"
      hermesStatusIsError = false
    }
  }
}

struct SummarizerSettingsView: View {
  @AppStorage(OttoPreferenceKey.onDeviceWorkTitles) private var enabled = false

  var body: some View {
    Form {
      Toggle("Generate concise work titles on this Mac", isOn: $enabled)
      Text(
        "Titles describe the request you gave an agent, not its current spinner or tool. Nothing is sent to an API."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      LabeledContent("On-device model", value: availabilityLabel)
      Text("When unavailable or disabled, Otto creates a deterministic title from the request.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(width: 540, height: 240)
  }

  private var availabilityLabel: String {
    switch AgentWorkTitleGenerator.onDeviceAvailability {
    case .available: "Available"
    case .unsupportedOS: "Requires macOS 26 or later"
    case .unavailable(let reason): "Unavailable · \(reason)"
    }
  }
}
