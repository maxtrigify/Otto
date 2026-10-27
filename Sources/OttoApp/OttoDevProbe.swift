#if DEBUG
  import AppKit
  import Foundation
  import OttoServices
  import OttoTools

  /// Development only: lets agent shells, which usually lack Screen Recording and Accessibility
  /// permission, exercise Otto Dev end to end. Post the distributed notification
  /// `io.openotto.dev.probe` with a string object:
  ///   snapshot:<directory>                    one PNG per visible window, plus windows.txt
  ///   tool:<output file>\n<tool name>\n<json>  call an Otto tool in the active space
  ///   permission:<agent UUID>:approve|deny:<report file>  what the chat card's Approve/Deny do
  @MainActor
  final class OttoDevProbe {
    static let shared = OttoDevProbe()
    private weak var services: ApplicationServices?
    private var installed = false

    func attach(services: ApplicationServices) {
      self.services = services
      guard !installed else { return }
      installed = true
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("io.openotto.dev.probe"), object: nil, queue: .main
      ) { note in
        let command = note.object as? String ?? ""
        MainActor.assumeIsolated { OttoDevProbe.shared.handle(command) }
      }
    }

    private func handle(_ command: String) {
      if command.hasPrefix("snapshot:") {
        snapshot(into: String(command.dropFirst(9)))
      } else if command.hasPrefix("permission:") {
        // permission:<agent UUID>:approve|deny:<report file>
        let parts = command.dropFirst(11).split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        let report = parts[2]
        func log(_ line: String) {
          let text = (try? String(contentsOfFile: report, encoding: .utf8)) ?? ""
          try? (text + line + "\n").write(toFile: report, atomically: true, encoding: .utf8)
        }
        log("received \(parts[0]) \(parts[1]) services=\(services != nil)")
        guard let agentID = UUID(uuidString: parts[0]), let services else { return }
        let approved = parts[1] == "approve"
        Task {
          let before = await services.supervisor.hasPendingPermission(agentID: agentID)
          log("pendingBefore=\(before)")
          await services.resolveAgentPermission(agentID: agentID, approved: approved)
          let after = await services.supervisor.hasPendingPermission(agentID: agentID)
          log("pendingAfter=\(after) error=\(services.errorMessage ?? "none")")
        }
      } else if command.hasPrefix("tool:") {
        let parts = command.dropFirst(5).split(separator: "\n", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        let output = parts[0]
        let input = parts.count == 3 ? parts[2] : "{}"
        Task { await self.callTool(parts[1], json: input, output: output) }
      }
    }

    private func snapshot(into directory: String) {
      try? FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true)
      var listing = ""
      for (index, window) in NSApp.windows.enumerated() where window.isVisible {
        guard let view = window.contentView?.superview ?? window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        let name = "window-\(index).png"
        try? rep.representation(using: .png, properties: [:])?
          .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        listing +=
          "\(name) title=\(window.title) key=\(window.isKeyWindow) frame=\(window.frame)\n"
      }
      try? listing.write(
        toFile: (directory as NSString).appendingPathComponent("windows.txt"), atomically: true,
        encoding: .utf8)
    }

    private func callTool(_ name: String, json: String, output: String) async {
      let text: String
      do {
        guard let services else { throw CocoaError(.featureUnsupported) }
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let result = try await services.callUserTool(name: name, input: input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        text = String(decoding: try encoder.encode(result), as: UTF8.self)
      } catch {
        text = "ERROR: \(error)"
      }
      try? text.write(toFile: output, atomically: true, encoding: .utf8)
    }
  }
#endif
