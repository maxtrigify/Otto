import Foundation

/// What someone typed or attached in a chat but hasn't sent, kept per chat so going elsewhere in the app
/// and coming back finds it still there. Survives relaunch; sending clears it.
@MainActor
enum ComposerDrafts {
  private static let defaultsKey = "otto.composerDrafts"
  /// Plenty for every open chat; the oldest-written drafts go first beyond this.
  private static let limit = 200
  private static var drafts: [String: String] =
    UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
  private static var order: [String] = Array(drafts.keys)

  static func text(for key: String) -> String { drafts[key] ?? "" }

  static func save(_ text: String, for key: String) {
    let next = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    guard drafts[key] != next else { return }
    drafts[key] = next
    order.removeAll { $0 == key }
    if next != nil { order.append(key) }
    while order.count > limit { drafts[order.removeFirst()] = nil }
    schedulePersist()
  }

  /// Saving runs on every keystroke, and writing all drafts to defaults each time made typing
  /// lag. Memory stays current immediately; the disk copy follows once typing pauses.
  private static var persistTask: Task<Void, Never>?

  private static func schedulePersist() {
    persistTask?.cancel()
    persistTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      UserDefaults.standard.set(drafts, forKey: defaultsKey)
      UserDefaults.standard.set(attachmentDrafts, forKey: attachmentsDefaultsKey)
    }
  }

  static func agentKey(_ nodeID: UUID) -> String { "agent:\(nodeID.uuidString)" }

  // MARK: - Attachments

  /// Screenshots and long pastes added to a chat but not yet sent. Images are already saved
  /// files, so only their paths are kept; a path whose file has gone is dropped on restore.
  struct Attachments: Equatable {
    var imagePaths: [String] = []
    var pastes: [String] = []
    var isEmpty: Bool { imagePaths.isEmpty && pastes.isEmpty }
  }

  private static let attachmentsDefaultsKey = "otto.composerDraftAttachments"
  private static var attachmentDrafts: [String: [String: [String]]] =
    UserDefaults.standard.dictionary(forKey: attachmentsDefaultsKey)
    as? [String: [String: [String]]]
    ?? [:]
  private static var attachmentOrder: [String] = Array(attachmentDrafts.keys)

  static func attachments(for key: String) -> Attachments {
    guard let stored = attachmentDrafts[key] else { return Attachments() }
    return Attachments(
      imagePaths: (stored["images"] ?? []).filter { FileManager.default.fileExists(atPath: $0) },
      pastes: stored["pastes"] ?? [])
  }

  static func saveAttachments(_ attachments: Attachments, for key: String) {
    let next =
      attachments.isEmpty
      ? nil : ["images": attachments.imagePaths, "pastes": attachments.pastes]
    guard attachmentDrafts[key] != next else { return }
    attachmentDrafts[key] = next
    attachmentOrder.removeAll { $0 == key }
    if next != nil { attachmentOrder.append(key) }
    while attachmentOrder.count > limit { attachmentDrafts[attachmentOrder.removeFirst()] = nil }
    schedulePersist()
  }
}
