import Foundation
import OttoMobileClient
import OttoRPCContracts
import SwiftUI
import UIKit
import UserNotifications
import VisionKit

@main
struct OttoMobileApp: App {
  @UIApplicationDelegateAdaptor(OttoMobileAppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      OttoMobileBootstrapView()
        .preferredColorScheme(.dark)
        .tint(OttoMobileGlassPalette.accent)
    }
  }
}

private struct OttoMobileBootstrapView: View {
  private let pairingStore = OttoMobileKeychainPairingStore()
  private let managedPairingStore = OttoManagedMobileKeychainStore()
  @State private var activeConnection: (any OttoMobileConnecting)?
  @State private var pairingCode =
    ottoEnvironment("MOBILE_PAIRING_QR") ?? ""
  @State private var pendingPairing: PendingPairing?
  @State private var isLoading = true
  @State private var isPairing = false
  @State private var showingScanner = false
  @State private var showingManualCode = false
  @State private var validationError: String?

  var body: some View {
    Group {
      if let activeConnection {
        ConfiguredOttoMobileView(connection: activeConnection)
      } else if isLoading {
        loadingView
      } else {
        setup
      }
    }
    .task {
      showingManualCode = !pairingCode.isEmpty
      await loadPairing()
    }
    .sheet(isPresented: $showingScanner) {
      OttoMobilePairingScannerSheet { value in
        showingScanner = false
        review(value)
      }
    }
  }

  private var demoConfiguration: OttoMobileConnectionConfiguration? {
    guard let rawURL = ottoEnvironment("MOBILE_DEMO_HOST_URL"),
      let url = URL(string: rawURL),
      let token = ottoEnvironment("MOBILE_DEMO_TOKEN"),
      let rawDeviceID = ottoEnvironment("MOBILE_DEMO_DEVICE_ID"),
      let deviceID = UUID(uuidString: rawDeviceID)
    else { return nil }
    return OttoMobileConnectionConfiguration(baseURL: url, token: token, deviceID: deviceID)
  }

  private var setup: some View {
    ZStack {
      OttoMobileGlassBackdrop()
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack {
            Text("OTTO / NIGHTGLASS")
            Spacer()
            Image(systemName: "iphone")
              .foregroundStyle(PairingPalette.accent)
          }
          .font(.system(.caption, design: .monospaced, weight: .bold))
          .tracking(1.8)
          .foregroundStyle(PairingPalette.mutedInk)
          Text("Your Otto.\nNow in your pocket.")
            .font(.system(.largeTitle, design: .serif, weight: .medium))
            .tracking(-1.1)
            .foregroundStyle(PairingPalette.ink)

          if let pendingPairing {
            pairingConfirmation(pendingPairing)
          } else {
            scanPrompt
          }

          if pendingPairing == nil, let validationError {
            Text(validationError)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(PairingPalette.coral)
              .accessibilityLabel("Pairing error: \(validationError)")
          }
        }
        .padding(26)
      }
    }
  }

  private var scanPrompt: some View {
    VStack(alignment: .leading, spacing: 18) {
      Button {
        validationError = nil
        showingScanner = true
      } label: {
        ZStack {
          RoundedRectangle(cornerRadius: 28)
            .fill(
              LinearGradient(
                colors: [
                  PairingPalette.accent.opacity(0.18),
                  OttoMobileGlassPalette.cyan.opacity(0.06),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
          VStack(spacing: 16) {
            Image(systemName: "viewfinder")
              .font(.system(size: 46, weight: .light))
              .foregroundStyle(PairingPalette.accent)
            Text("Scan your Mac’s QR code")
              .font(.headline)
          }
          .foregroundStyle(.white)
        }
        .frame(height: 172)
        .ottoMobileGlassSurface(cornerRadius: 30, tint: PairingPalette.accent, interactive: true)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Scan Otto pairing QR code")

      Text(
        "Open Otto on your Mac, then Settings → Mobile to show a pairing code. Scan it and confirm the connection. Your iPhone remembers it securely."
      )
      .font(.system(.body, design: .default))
      .foregroundStyle(PairingPalette.mutedInk)

      Text(
        "Use Pair nearby on the same network, or Remote Access to connect away from home. Your agents continue running on your Mac."
      )
      .font(.subheadline)
      .foregroundStyle(PairingPalette.mutedInk)

      DisclosureGroup("Have a pairing code?", isExpanded: $showingManualCode) {
        VStack(alignment: .leading, spacing: 12) {
          TextField("Paste otto:// code", text: $pairingCode, axis: .vertical)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.caption, design: .monospaced))
            .lineLimit(2...5)
            .padding(14)
            .ottoMobileGlassSurface(cornerRadius: 18, interactive: true)
          Button("REVIEW CONNECTION") { review(pairingCode) }
            .buttonStyle(PairingPrimaryButtonStyle())
            .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.top, 12)
      }
      .padding(18)
      .ottoMobileGlassSurface(cornerRadius: 24)
    }
  }

  @ViewBuilder
  private func pairingConfirmation(_ pairing: PendingPairing) -> some View {
    switch pairing {
    case .local(let payload):
      localPairingConfirmation(payload)
    case .managed(let payload):
      managedPairingConfirmation(payload)
    }
  }

  private func localPairingConfirmation(_ payload: OttoMobilePairingPayload) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("CONFIRM ENVIRONMENT")
        .font(.system(.caption2, design: .monospaced, weight: .bold))
        .tracking(1.4)
        .foregroundStyle(PairingPalette.coral)
      Text(payload.environmentName)
        .font(.system(.title, design: .serif, weight: .semibold))
      Label(payload.baseURL.host ?? payload.baseURL.absoluteString, systemImage: "network")
      Label("Fingerprint \(payload.fingerprint.prefix(12))…", systemImage: "checkmark.seal")
      Label(
        "Expires \(payload.expiresAt.formatted(date: .omitted, time: .shortened))",
        systemImage: "timer")
      Text(
        "Only this device receives the scoped credential. Verify the Mac name before continuing."
      )
      .font(.system(.body, design: .default))
      .foregroundStyle(PairingPalette.mutedInk)
      Button(isPairing ? "PAIRING…" : "PAIR THIS IPHONE") {
        Task { await pair(payload) }
      }
      .buttonStyle(PairingPrimaryButtonStyle())
      .disabled(isPairing)
      pairingErrorBanner
      Button("Scan a different code") {
        pendingPairing = nil
        validationError = nil
      }
      .font(.system(.subheadline, design: .monospaced, weight: .semibold))
      .foregroundStyle(PairingPalette.mutedInk)
    }
    .font(.system(.subheadline, design: .rounded))
    .padding(22)
    .ottoMobileGlassSurface(cornerRadius: 28)
  }

  private func managedPairingConfirmation(
    _ payload: OttoManagedMobilePairingPayload
  ) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("CONFIRM REMOTE ACCESS")
        .font(.system(.caption2, design: .monospaced, weight: .bold))
        .tracking(1.4)
        .foregroundStyle(PairingPalette.coral)
      Text("Your Otto, wherever you are.")
        .font(.system(.title, design: .serif, weight: .semibold))
      Label(
        payload.controlPlaneURL.host ?? "Otto control plane",
        systemImage: "network.badge.shield.half.filled")
      Label("One-time device registration", systemImage: "iphone.gen3.badge.checkmark")
      Label(
        "Expires \(payload.expiresAt.formatted(date: .omitted, time: .shortened))",
        systemImage: "timer"
      )
      Text(
        "This registers only this iPhone. Agents, files, and credentials remain on your Mac; the control plane relays short-lived, scoped commands."
      )
      .font(.system(.body, design: .default))
      .foregroundStyle(PairingPalette.mutedInk)
      Button(isPairing ? "PAIRING…" : "ENABLE REMOTE ACCESS") {
        Task { await pair(payload) }
      }
      .buttonStyle(PairingPrimaryButtonStyle())
      .disabled(isPairing)
      pairingErrorBanner
      Button("Scan a different code") {
        pendingPairing = nil
        validationError = nil
      }
      .font(.system(.subheadline, design: .monospaced, weight: .semibold))
      .foregroundStyle(PairingPalette.mutedInk)
    }
    .font(.system(.subheadline, design: .rounded))
    .padding(22)
    .ottoMobileGlassSurface(cornerRadius: 28)
  }

  private var loadingView: some View {
    ZStack {
      OttoMobileGlassBackdrop()
      ProgressView("Opening paired environments…")
        .font(.system(.caption, design: .monospaced))
    }
  }

  @ViewBuilder
  private var pairingErrorBanner: some View {
    if let validationError {
      Label(validationError, systemImage: "exclamationmark.circle.fill")
        .font(.system(.caption, design: .monospaced, weight: .semibold))
        .foregroundStyle(PairingPalette.coral)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ottoMobileGlassSurface(cornerRadius: 16, tint: PairingPalette.coral)
        .accessibilityLabel("Pairing error: \(validationError)")
    }
  }

  private func loadPairing() async {
    defer { isLoading = false }
    if let demoConfiguration {
      activeConnection = OttoMobileConnection(configuration: demoConfiguration)
      return
    }
    do {
      if ottoEnvironment("MOBILE_RESET_PAIRING") == "1" {
        for record in try await pairingStore.records() {
          try await pairingStore.delete(environmentID: record.environmentID)
        }
        for record in try await managedPairingStore.records() {
          try await managedPairingStore.delete(deviceID: record.deviceID)
        }
      }
      let localRecord = try await pairingStore.records().first
      let managedRecord = try await managedPairingStore.records().first
      if let managedRecord,
        localRecord == nil || managedRecord.registeredAt >= (localRecord?.pairedAt ?? .distantPast)
      {
        do {
          activeConnection = try await managedConnection(for: managedRecord)
          return
        } catch {
          validationError = error.localizedDescription
        }
      }
      if let localRecord {
        activeConnection = OttoMobileConnection(configuration: localRecord.connectionConfiguration)
        return
      }
      if let managedRecord {
        activeConnection = try await managedConnection(for: managedRecord)
      }
    } catch {
      validationError = error.localizedDescription
    }
  }

  private func review(_ value: String) {
    do {
      let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
      // muse:// codes from before the rename still pair.
      let lowered = code.lowercased()
      if lowered.hasPrefix("otto://remote?") || lowered.hasPrefix("muse://remote?") {
        let payload = try OttoManagedMobilePairingPayload(qrString: code)
        guard payload.expiresAt > .now else { throw OttoManagedMobilePairingError.expired }
        pendingPairing = .managed(payload)
      } else {
        let payload = try OttoMobilePairingPayload(qrString: code)
        guard payload.expiresAt > .now else { throw OttoMobilePairingError.expired }
        pendingPairing = .local(payload)
      }
      pairingCode = value
      validationError = nil
    } catch {
      pendingPairing = nil
      validationError = error.localizedDescription
    }
  }

  private func pair(_ payload: OttoMobilePairingPayload) async {
    guard !isPairing else { return }
    isPairing = true
    defer { isPairing = false }
    do {
      let client = OttoMobilePairingClient(store: pairingStore)
      let record = try await client.pair(
        payload: payload,
        deviceName: UIDevice.current.name
      )
      activeConnection = OttoMobileConnection(configuration: record.connectionConfiguration)
      pendingPairing = nil
      validationError = nil
    } catch {
      validationError = error.localizedDescription
    }
  }

  private func pair(_ payload: OttoManagedMobilePairingPayload) async {
    guard !isPairing else { return }
    isPairing = true
    defer { isPairing = false }
    do {
      let client = OttoManagedMobilePairingClient(store: managedPairingStore)
      let record = try await client.pair(
        payload: payload,
        deviceName: UIDevice.current.name
      )
      activeConnection = try await managedConnection(for: record)
      pendingPairing = nil
      validationError = nil
    } catch {
      validationError = error.localizedDescription
    }
  }

  private func managedConnection(
    for record: OttoManagedMobileDeviceRecord
  ) async throws -> OttoManagedMobileConnection {
    let controlPlane = OttoManagedMobileControlPlaneClient(record: record)
    let environments = try await controlPlane.environments()
    guard
      let environment = environments.first(where: { $0.state == .online })
        ?? environments.first
    else { throw OttoManagedMobileError.environmentUnavailable }
    return await controlPlane.connection(environmentID: environment.environmentID)
  }

  private enum PendingPairing {
    case local(OttoMobilePairingPayload)
    case managed(OttoManagedMobilePairingPayload)
  }
}

private struct OttoMobilePairingScannerSheet: View {
  @Environment(\.dismiss) private var dismiss
  let onScan: (String) -> Void

  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
          OttoMobileQRCodeScanner(onScan: onScan)
            .ignoresSafeArea()
          RoundedRectangle(cornerRadius: 28)
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
            .frame(width: 270, height: 270)
            .allowsHitTesting(false)
        } else {
          ContentUnavailableView(
            "Camera scanning unavailable",
            systemImage: "camera.fill",
            description: Text("Paste the pairing code on the previous screen instead.")
          )
          .foregroundStyle(.white)
        }
      }
      .navigationTitle("Scan your Mac")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .toolbarColorScheme(.dark, for: .navigationBar)
    }
  }
}

private struct OttoMobileQRCodeScanner: UIViewControllerRepresentable {
  let onScan: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let controller = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced,
      recognizesMultipleItems: false,
      isHighFrameRateTrackingEnabled: true,
      isPinchToZoomEnabled: true,
      isGuidanceEnabled: true,
      isHighlightingEnabled: true
    )
    controller.delegate = context.coordinator
    try? controller.startScanning()
    return controller
  }

  func updateUIViewController(_: DataScannerViewController, context _: Context) {}

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let onScan: (String) -> Void
    private var didScan = false

    init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

    func dataScanner(
      _: DataScannerViewController,
      didAdd addedItems: [RecognizedItem],
      allItems _: [RecognizedItem]
    ) {
      guard !didScan else { return }
      for item in addedItems {
        guard case .barcode(let barcode) = item,
          let value = barcode.payloadStringValue,
          ["otto://pair?", "otto://remote?", "muse://pair?", "muse://remote?"].contains(where: {
            value.hasPrefix($0)
          })
        else { continue }
        didScan = true
        onScan(value)
        return
      }
    }
  }
}

private struct PairingPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(.subheadline, design: .monospaced, weight: .bold))
      .tracking(1)
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 16)
      .background(PairingPalette.accent.opacity(0.76), in: Capsule())
      .ottoMobileGlassSurface(
        cornerRadius: 28,
        tint: PairingPalette.accent,
        interactive: true
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .opacity(configuration.isPressed ? 0.84 : 1)
  }
}

private enum PairingPalette {
  static let paper = Color.primary
  static let card = Color.clear
  static let ink = Color.primary
  static let mutedInk = Color.secondary
  static let accent = OttoMobileGlassPalette.accent
  static let coral = OttoMobileGlassPalette.danger
  static let rule = Color.primary.opacity(0.12)
}

private struct ConfiguredOttoMobileView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var store: OttoMobileStore
  @State private var notificationPermission: OttoMobileNotificationPermissionState = .unknown
  @State private var requestedThreadID: UUID? = OttoMobileAppDelegate.consumePendingThreadID()
  @State private var runBackgroundLease = OttoMobileRunBackgroundLease()

  init(connection: any OttoMobileConnecting) {
    _store = State(
      initialValue: OttoMobileStore(
        connection: connection,
        notifications: OttoMobileSystemNotificationDelivery.shared
      ))
  }

  var body: some View {
    OttoMobileRootView(
      store: store,
      requestedThreadID: $requestedThreadID,
      notificationPermission: notificationPermission
    ) {
      Task { await enableNotifications() }
    }
    .task { await refreshNotificationPermission() }
    .task {
      if let token = OttoMobileAppDelegate.existingPushToken() {
        await registerPush(token)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .ottoMobileOpenThread)) { note in
      requestedThreadID = note.object as? UUID
    }
    .onReceive(NotificationCenter.default.publisher(for: .ottoMobilePushTokenUpdated)) { note in
      guard let token = note.object as? String else { return }
      Task { await registerPush(token) }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background, store.activeRunID != nil {
        runBackgroundLease.begin()
      } else if phase == .active {
        runBackgroundLease.end()
      }
    }
    .onChange(of: store.activeRunID) { _, runID in
      if runID == nil {
        runBackgroundLease.end()
      } else if scenePhase == .background {
        runBackgroundLease.begin()
      }
    }
  }

  private func enableNotifications() async {
    if notificationPermission == .denied {
      guard let settings = URL(string: UIApplication.openNotificationSettingsURLString) else {
        return
      }
      await UIApplication.shared.open(settings)
    } else {
      _ = await OttoMobileSystemNotificationDelivery.shared.requestAuthorization()
    }
    await refreshNotificationPermission()
  }

  private func refreshNotificationPermission() async {
    notificationPermission = await OttoMobileSystemNotificationDelivery.shared.permissionState()
  }

  private func registerPush(_ token: String) async {
    #if DEBUG
      let environment = OttoPushEnvironment.sandbox
    #else
      let environment = OttoPushEnvironment.production
    #endif
    await store.registerPush(token: token, environment: environment)
  }
}

@MainActor
private final class OttoMobileRunBackgroundLease {
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  func begin() {
    guard identifier == .invalid else { return }
    identifier = UIApplication.shared.beginBackgroundTask(withName: "Finish active Otto run") {
      Task { @MainActor [weak self] in self?.end() }
    }
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }

  deinit {
    if identifier != .invalid {
      UIApplication.shared.endBackgroundTask(identifier)
    }
  }
}

private actor OttoMobileSystemNotificationDelivery: OttoMobileNotificationDelivering {
  static let shared = OttoMobileSystemNotificationDelivery()

  func permissionState() async -> OttoMobileNotificationPermissionState {
    switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
    case .notDetermined: .unknown
    case .authorized, .provisional, .ephemeral: .authorized
    case .denied: .denied
    @unknown default: .unavailable
    }
  }

  func requestAuthorization() async -> Bool {
    do {
      let allowed = try await UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .badge, .sound]
      )
      if allowed { await UIApplication.shared.registerForRemoteNotifications() }
      return allowed
    } catch {
      return false
    }
  }

  func deliver(_ notification: OttoMobileNotificationDelivery) async {
    guard await permissionState() == .authorized else { return }
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.sound = .default
    content.userInfo = ["thread_id": notification.threadID.uuidString]
    let request = UNNotificationRequest(
      identifier: notification.eventID.uuidString,
      content: content,
      // Avoid losing a completion banner in the narrow foreground-to-background transition.
      // If Otto remains foregrounded the delegate still suppresses it; after Home it is shown.
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
    )
    try? await UNUserNotificationCenter.current().add(request)
  }
}

private final class OttoMobileAppDelegate: NSObject, UIApplicationDelegate,
  @preconcurrency UNUserNotificationCenterDelegate
{
  private static let pendingThreadKey = "otto.mobile.pending-thread-id"
  private static let pushTokenKey = "otto.mobile.apns-device-token"
  /// Written by builds from before the rename.
  private static let legacyPushTokenKey = "muse.mobile.apns-device-token"

  func application(
    _: UIApplication,
    didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return true
  }

  func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    let value = token.map { String(format: "%02x", $0) }.joined()
    UserDefaults.standard.set(value, forKey: Self.pushTokenKey)
    NotificationCenter.default.post(name: .ottoMobilePushTokenUpdated, object: value)
  }

  func userNotificationCenter(
    _: UNUserNotificationCenter,
    willPresent _: UNNotification
  ) async -> UNNotificationPresentationOptions {
    []
  }

  func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard let value = response.notification.request.content.userInfo["thread_id"] as? String,
      let threadID = UUID(uuidString: value)
    else { return }
    UserDefaults.standard.set(threadID.uuidString, forKey: Self.pendingThreadKey)
    await MainActor.run {
      NotificationCenter.default.post(name: .ottoMobileOpenThread, object: threadID)
    }
  }

  static func consumePendingThreadID() -> UUID? {
    guard let value = UserDefaults.standard.string(forKey: pendingThreadKey) else { return nil }
    UserDefaults.standard.removeObject(forKey: pendingThreadKey)
    return UUID(uuidString: value)
  }

  static func existingPushToken() -> String? {
    UserDefaults.standard.string(forKey: pushTokenKey)
      ?? UserDefaults.standard.string(forKey: legacyPushTokenKey)
  }
}

extension Notification.Name {
  fileprivate static let ottoMobileOpenThread = Notification.Name("OttoMobileOpenThread")
  fileprivate static let ottoMobilePushTokenUpdated = Notification.Name(
    "OttoMobilePushTokenUpdated")
}

/// `OTTO_<name>` from the launch environment, falling back to the pre-rename `MUSE_<name>`.
private func ottoEnvironment(_ name: String) -> String? {
  let environment = ProcessInfo.processInfo.environment
  return environment["OTTO_" + name] ?? environment["MUSE_" + name]
}
