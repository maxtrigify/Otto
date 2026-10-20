import SwiftUI

/// Modal surfaced when a newer release is available (or after a manual check). Shows the
/// version jump and the release changelog, and drives the verified install-and-relaunch flow.
struct AppUpdateSheet: View {
  @ObservedObject var controller: AppUpdateController
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
      Divider().overlay(palette.paper.opacity(0.08))
      content
      Divider().overlay(palette.paper.opacity(0.08))
      footer
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
    .frame(width: 520)
    .background(palette.ink)
  }

  @ViewBuilder
  private var header: some View {
    HStack(spacing: 12) {
      OttoMark(size: 34)
      VStack(alignment: .leading, spacing: 2) {
        Text(headline)
          .font(.ottoDisplay(15).weight(.bold))
          .foregroundStyle(palette.paper)
        Text(subheadline)
          .font(.ottoMono(9))
          .foregroundStyle(palette.paper.opacity(0.6))
      }
      Spacer()
    }
  }

  private var headline: String {
    if case .failed = controller.phase { return "Update check failed" }
    if controller.availableRelease != nil { return "A new version of Otto is here" }
    return "Otto is up to date"
  }

  private var subheadline: String {
    if let release = controller.availableRelease {
      return
        "Otto \(release.version) (build \(release.build)) — you have \(controller.currentVersion)"
    }
    return "Otto \(controller.currentVersion)"
  }

  @ViewBuilder
  private var content: some View {
    if let release = controller.availableRelease {
      ScrollView {
        MarkdownMessageView(text: release.changelog, scale: 1, palette: palette)
          .padding(.horizontal, 22)
          .padding(.vertical, 16)
      }
      .frame(height: 280)
    } else if case .failed(let message) = controller.phase {
      Text(message)
        .font(.ottoDisplay(11))
        .foregroundStyle(palette.paper.opacity(0.75))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
    } else {
      Text("You're running the latest release. Otto checks for updates automatically.")
        .font(.ottoDisplay(11))
        .foregroundStyle(palette.paper.opacity(0.75))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
    }
  }

  @ViewBuilder
  private var footer: some View {
    HStack(spacing: 10) {
      if controller.availableRelease != nil {
        Button("Skip This Version") { controller.skipAvailableVersion() }
          .buttonStyle(.plain)
          .font(.ottoMono(9))
          .foregroundStyle(palette.paper.opacity(0.5))
      }
      Spacer()
      Button("Later") { controller.isPresentingUpdateSheet = false }
        .keyboardShortcut(.cancelAction)
      if controller.availableRelease != nil {
        Button(action: { controller.downloadAndInstall() }) {
          HStack(spacing: 6) {
            if controller.phase.isInstalling {
              ProgressView().controlSize(.small)
              Text(controller.phase.installLabel)
            } else {
              Text("Download & Restart")
            }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(controller.phase.isInstalling)
      }
    }
  }
}

extension AppUpdateController.Phase {
  fileprivate var isInstalling: Bool {
    switch self {
    case .downloading, .preparing, .restarting: true
    case .idle, .checking, .upToDate, .failed: false
    }
  }

  fileprivate var installLabel: String {
    switch self {
    case .downloading(let progress):
      "Downloading \(Int((progress * 100).rounded()))%"
    case .preparing:
      "Preparing…"
    case .restarting:
      "Restarting…"
    case .idle, .checking, .upToDate, .failed:
      "Download & Restart"
    }
  }
}
