import AppKit
import OttoServices
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Backup: save the current setup to a file, or restore one on the next launch.
struct BackupSettingsView: View {
  let workspacePath: String
  @AppStorage(OttoBackup.lastRestoreKey) private var lastRestore = ""
  @State private var status: String?
  @State private var isWorking = false

  private static let backupType =
    UTType(filenameExtension: OttoBackup.fileExtension, conformingTo: .zip) ?? .zip

  var body: some View {
    Form {
      Section("Back up") {
        Text(
          "Saves your bots, their looks and notes, connector choices, the SMTP server, routines, commands, your profile notes and Otto's settings to one file."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Text(
          "Passwords, tokens and sign-ins are not included; they stay in this Mac's Keychain. Sessions, memory and activity history are not included either."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Button("Export Backup…", action: exportBackup)
          .disabled(isWorking)
      }
      Section("Restore") {
        Text(
          "Replaces the setup files and settings that are in the backup, then restarts Otto. Your current setup is saved first, so you can go back."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        HStack {
          Button("Restore from Backup…", action: restoreBackup)
            .disabled(isWorking)
          Button("Show Backups in Finder", action: showBackups)
        }
        if !lastRestore.isEmpty {
          LabeledContent("Last restore") {
            Text(lastRestore).textSelection(.enabled)
          }
        }
      }
      if let status {
        Text(status)
          .font(.callout)
          .textSelection(.enabled)
      }
    }
    .formStyle(.grouped)
    .padding(24)
  }

  private func exportBackup() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [Self.backupType]
    panel.nameFieldStringValue =
      "Otto Backup \(OttoBackup.fileStamp(.now)).\(OttoBackup.fileExtension)"
    panel.directoryURL = OttoBackup.Locations.live.backups
    try? FileManager.default.createDirectory(
      at: OttoBackup.Locations.live.backups, withIntermediateDirectories: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    isWorking = true
    status = "Saving…"
    let workspacePath = workspacePath
    Task.detached {
      let result: String
      do {
        let manifest = try OttoBackup.export(
          workspacePath: workspacePath, defaults: .standard, to: url,
          appVersion: await appVersionString())
        result =
          "Saved \(manifest.files.count) files and \(manifest.settingsCount) settings to “\(url.lastPathComponent)”."
      } catch {
        result = "Could not save the backup: \(error.localizedDescription)"
      }
      await MainActor.run {
        status = result
        isWorking = false
      }
    }
  }

  private func restoreBackup() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [Self.backupType]
    panel.allowsMultipleSelection = false
    panel.directoryURL = OttoBackup.Locations.live.backups
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let manifest: OttoBackup.Manifest
    do {
      manifest = try OttoBackup.inspect(url)
    } catch {
      status = error.localizedDescription
      return
    }

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Restore this backup and restart Otto?"
    alert.informativeText = """
      Made \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened)) with Otto \
      \(manifest.appVersion).

      \(Self.describe(manifest))

      Files and settings in the backup replace the current ones; your current setup is saved \
      first. Passwords and sign-ins are not in backups, so re-enter them if this is another \
      Mac. Running agents stop when Otto restarts.
      """
    alert.addButton(withTitle: "Restore and Restart")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    do {
      try OttoBackup.stageRestore(
        from: url, workspacePath: workspacePath, locations: .live)
      try Self.relaunch()
    } catch {
      status = "Could not restore: \(error.localizedDescription)"
    }
  }

  private func showBackups() {
    let folder = OttoBackup.Locations.live.backups
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    NSWorkspace.shared.activateFileViewerSelecting([folder])
  }

  /// A plain list of what the backup holds, for the confirmation alert.
  static func describe(_ manifest: OttoBackup.Manifest) -> String {
    let avatars = manifest.files.filter { $0.hasPrefix("\(OttoBackup.avatarFolder)/") }.count
    let names = manifest.files.filter { !$0.hasPrefix("\(OttoBackup.avatarFolder)/") }
    var lines = names.map { "• \($0)" }
    if avatars > 0 { lines.append("• \(avatars) bot picture\(avatars == 1 ? "" : "s")") }
    lines.append("• \(manifest.settingsCount) setting\(manifest.settingsCount == 1 ? "" : "s")")
    return lines.joined(separator: "\n")
  }

  /// Quits and reopens Otto. A detached shell waits for this process to exit, so the staged
  /// restore is applied by the next launch.
  private static func relaunch() throws {
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = [
      "-c",
      "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
      "otto-restore-relaunch", String(ProcessInfo.processInfo.processIdentifier),
      Bundle.main.bundleURL.path,
    ]
    try helper.run()
    UpdateRelaunchRequest.shared.begin()
    NSApp.terminate(nil)
  }
}
