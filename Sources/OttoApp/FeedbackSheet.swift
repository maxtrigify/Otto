import AppKit
import OttoServices
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
  /// Opens the Send Feedback sheet from anywhere (sidebar button, command palette).
  static let ottoSendFeedback = Notification.Name("io.openotto.send-feedback")
}

/// Help › Send Feedback…: a bug report or idea, filed as a public GitHub issue through the
/// feedback service. Written for people who have never opened GitHub.
struct FeedbackSheet: View {
  enum Phase: Equatable {
    case editing
    case sending
    case sent(FeedbackSubmission)
    case failed(String)
  }

  let client: FeedbackClient
  let close: () -> Void
  @State var draft: FeedbackDraft
  @State var phase: Phase
  @State private var imageMessage: String?
  @State private var dropTargeted = false
  @Environment(\.ottoPalette) private var palette
  @Environment(\.ottoMotion) private var motion

  init(
    client: FeedbackClient = FeedbackClient(), draft: FeedbackDraft = FeedbackDraft(),
    phase: Phase = .editing, close: @escaping () -> Void
  ) {
    self.client = client
    self.close = close
    _draft = State(initialValue: draft)
    _phase = State(initialValue: phase)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 14)
      Divider().overlay(palette.paper.opacity(0.08))
      if case .sent(let submission) = phase {
        sentContent(submission)
      } else {
        form
          .padding(.horizontal, 22)
          .padding(.vertical, 16)
          .disabled(phase == .sending)
      }
      Divider().overlay(palette.paper.opacity(0.08))
      footer
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
    .frame(width: 560)
    .background(palette.ink)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(palette.signal)
        .frame(width: 34, height: 34)
        .background(palette.signal.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
      VStack(alignment: .leading, spacing: 2) {
        Text("Send feedback")
          .font(.ottoDisplay(15).weight(.bold))
          .foregroundStyle(palette.paper)
        Text("Tell us what went wrong or what you'd like Otto to do.")
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.paper.opacity(0.6))
      }
      Spacer()
    }
  }

  // MARK: Form

  private var form: some View {
    VStack(alignment: .leading, spacing: 14) {
      Picker("Kind", selection: $draft.kind) {
        Text("Bug").tag(FeedbackKind.bug)
        Text("Idea").tag(FeedbackKind.idea)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .accessibilityLabel("Is this a bug or an idea?")

      VStack(alignment: .leading, spacing: 6) {
        label("TITLE (OPTIONAL)")
        TextField("", text: $draft.title)
          .textFieldStyle(.plain)
          .font(.ottoDisplay(13))
          .foregroundStyle(palette.paper)
          .padding(.horizontal, 10)
          .frame(height: 30)
          .overlay(alignment: .leading) {
            if draft.title.isEmpty {
              Text(titlePlaceholder)
                .font(.ottoDisplay(13))
                .foregroundStyle(palette.muted.opacity(0.8))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .allowsHitTesting(false)
            }
          }
          .accessibilityLabel("Title (optional)")
          .background(palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.paper.opacity(0.1)))
          .onChange(of: draft.title) { _, value in
            if value.count > FeedbackLimits.maximumTitle {
              draft.title = String(value.prefix(FeedbackLimits.maximumTitle))
            }
          }
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          label(draft.kind == .bug ? "WHAT HAPPENED?" : "WHAT WOULD YOU LIKE?")
          Spacer()
          Text(
            "\(draft.trimmedDescription.count.formatted()) / \(FeedbackLimits.maximumDescription.formatted())"
          )
          .font(.ottoMono(8.5))
          .foregroundStyle(
            draft.trimmedDescription.count > FeedbackLimits.maximumDescription
              ? palette.red : palette.muted)
        }
        TextEditor(text: $draft.description)
          .font(.ottoDisplay(13))
          .foregroundStyle(palette.paper)
          .scrollContentBackground(.hidden)
          .padding(8)
          .frame(height: 150)
          .background(palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
          .overlay(alignment: .topLeading) {
            if draft.description.isEmpty {
              Text(descriptionPlaceholder)
                .font(.ottoDisplay(13))
                .foregroundStyle(palette.muted.opacity(0.8))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
            }
          }
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.paper.opacity(0.1)))
          .accessibilityLabel(draft.kind == .bug ? "What happened?" : "What would you like?")
      }

      screenshotSection
      environmentSection
      publicNotice
    }
  }

  private var titlePlaceholder: String {
    let firstLine =
      draft.trimmedDescription.split(separator: "\n", omittingEmptySubsequences: true).first
      .map(String.init) ?? ""
    return firstLine.isEmpty ? "We'll use your first line if you leave this empty" : firstLine
  }

  private var descriptionPlaceholder: String {
    draft.kind == .bug
      ? "What were you doing, what did you expect, and what happened instead?"
      : "Describe the idea and what it would help you do."
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(.ottoMono(8, weight: .black))
      .tracking(1.2)
      .foregroundStyle(palette.muted)
  }

  // MARK: Screenshot

  private var screenshotSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      label("SCREENSHOT (OPTIONAL)")
      HStack(alignment: .center, spacing: 10) {
        if let screenshot = draft.screenshot, let image = NSImage(data: screenshot.data) {
          ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: 112, height: 70)
              .clipShape(RoundedRectangle(cornerRadius: 7))
              .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.paper.opacity(0.14)))
            Button {
              draft.screenshot = nil
              imageMessage = nil
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(palette.paper)
                .frame(width: 18, height: 18)
                .background(palette.ink.opacity(0.85), in: Circle())
                .overlay(Circle().stroke(palette.paper.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .help("Remove screenshot")
            .accessibilityLabel("Remove screenshot")
          }
          VStack(alignment: .leading, spacing: 3) {
            Text("\(String(screenshot.pixelWidth)) × \(String(screenshot.pixelHeight)) px")
              .font(.ottoMono(9))
              .foregroundStyle(palette.paper.opacity(0.75))
            Text(
              ByteCountFormatter.string(
                fromByteCount: Int64(screenshot.data.count), countStyle: .file)
            )
            .font(.ottoMono(9))
            .foregroundStyle(palette.muted)
          }
        } else {
          Button {
            captureOttoWindow()
          } label: {
            Label("Add screenshot of Otto", systemImage: "camera.viewfinder")
              .font(.ottoDisplay(12))
              .foregroundStyle(palette.paper.opacity(0.85))
              .padding(.horizontal, 10)
              .frame(height: 28)
              .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.paper.opacity(0.14)))
          }
          .buttonStyle(.ottoChrome(cornerRadius: 7))
          .help("Capture Otto's window (not the rest of your screen)")
          Button {
            chooseImage()
          } label: {
            Label("Choose image…", systemImage: "photo")
              .font(.ottoDisplay(12))
              .foregroundStyle(palette.paper.opacity(0.85))
              .padding(.horizontal, 10)
              .frame(height: 28)
              .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.paper.opacity(0.14)))
          }
          .buttonStyle(.ottoChrome(cornerRadius: 7))
          Text("or drop one here")
            .font(.ottoDisplay(11))
            .foregroundStyle(palette.muted)
        }
        Spacer(minLength: 0)
      }
      .padding(8)
      .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 9)
          .fill(dropTargeted ? palette.cyan.opacity(0.08) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 9)
          .strokeBorder(
            dropTargeted ? palette.cyan.opacity(0.6) : palette.paper.opacity(0.08),
            style: StrokeStyle(lineWidth: 1, dash: draft.screenshot == nil ? [4, 3] : []))
      )
      .dropDestination(for: URL.self) { urls, _ in
        guard let url = urls.first(where: \.isFileURL) else { return false }
        load(url)
        return true
      } isTargeted: {
        dropTargeted = $0
      }
      if let imageMessage {
        Text(imageMessage)
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.red)
      }
    }
  }

  private func captureOttoWindow() {
    imageMessage = nil
    guard let image = OttoWindowSnapshot.capture() else {
      imageMessage = "Couldn't capture Otto's window. Try Choose image… instead."
      return
    }
    apply { try FeedbackScreenshot.prepare(image: image) }
  }

  private func chooseImage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.png, .jpeg, .heic]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.prompt = "Add"
    panel.message = "Choose a screenshot or picture to attach"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    load(url)
  }

  private func load(_ url: URL) {
    imageMessage = nil
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
      data.count < 60_000_000
    else {
      imageMessage = "That file couldn't be read."
      return
    }
    apply { try FeedbackScreenshot.prepare(imageData: data) }
  }

  private func apply(_ prepare: () throws -> FeedbackScreenshot) {
    do {
      draft.screenshot = try prepare()
    } catch FeedbackImageError.tooLarge {
      imageMessage = "That image is too detailed to send. Try a smaller one."
    } catch {
      imageMessage = "That doesn't look like a PNG, JPEG or HEIC image."
    }
  }

  // MARK: Environment and notice

  private var environmentSection: some View {
    VStack(alignment: .leading, spacing: 5) {
      Toggle(isOn: $draft.includeEnvironment) {
        Text("Include app and Mac version")
          .font(.ottoDisplay(12))
          .foregroundStyle(palette.paper.opacity(0.9))
      }
      .toggleStyle(.checkbox)
      if draft.includeEnvironment {
        Text(client.environment.summaryLines.joined(separator: "  ·  "))
          .font(.ottoMono(9))
          .foregroundStyle(palette.muted)
          .padding(.leading, 20)
          .textSelection(.enabled)
          .accessibilityLabel(
            "Will send: \(client.environment.summaryLines.joined(separator: ", "))")
      }
    }
  }

  private var publicNotice: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "globe")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(palette.amber)
        .padding(.top, 1)
      Text(
        "This is posted publicly on GitHub. Don't include passwords, emails or anything private — check your screenshot."
      )
      .font(.ottoDisplay(11.5))
      .foregroundStyle(palette.paper.opacity(0.85))
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.amber.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.amber.opacity(0.22)))
  }

  // MARK: Sent

  private func sentContent(_ submission: FeedbackSubmission) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 38))
        .foregroundStyle(palette.signal)
      Text("Thanks! It's on GitHub")
        .font(.ottoDisplay(17).weight(.bold))
        .foregroundStyle(palette.paper)
      Text(
        "Your \(draft.kind == .bug ? "report" : "idea") is issue #\(submission.issueNumber). You can follow it, or add more detail there."
      )
      .font(.ottoDisplay(12))
      .foregroundStyle(palette.paper.opacity(0.7))
      .multilineTextAlignment(.center)
      Button {
        NSWorkspace.shared.open(submission.issueURL)
      } label: {
        Label("View it", systemImage: "arrow.up.right.square")
          .font(.ottoDisplay(12).weight(.semibold))
          .foregroundStyle(palette.cyan)
      }
      .buttonStyle(.plain)
      .help(submission.issueURL.absoluteString)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 22)
    .padding(.vertical, 36)
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 10) {
      switch phase {
      case .sent:
        Spacer()
        Button("Done", action: close)
          .keyboardShortcut(.defaultAction)
      case .editing, .sending, .failed:
        footerStatus
        Spacer(minLength: 8)
        Button("Cancel", action: close)
          .keyboardShortcut(.cancelAction)
        Button(action: send) {
          HStack(spacing: 6) {
            if phase == .sending {
              ProgressView().controlSize(.small)
              Text("Sending…")
            } else {
              Text(isFailed ? "Try again" : "Send")
            }
          }
          .font(.ottoDisplay(12).weight(.semibold))
          .padding(.horizontal, 14)
          .frame(height: 28)
        }
        .buttonStyle(.ottoPrimary(cornerRadius: 7))
        .keyboardShortcut(.defaultAction)
        .disabled(phase == .sending || draft.validationMessage != nil)
        .help(draft.validationMessage ?? "Post this on GitHub")
      }
    }
  }

  private var isFailed: Bool {
    if case .failed = phase { return true }
    return false
  }

  @ViewBuilder private var footerStatus: some View {
    if case .failed(let message) = phase {
      HStack(alignment: .top, spacing: 6) {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(palette.red)
        Text(message)
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.paper.opacity(0.85))
          .fixedSize(horizontal: false, vertical: true)
      }
    } else if phase == .editing, !draft.description.isEmpty,
      let message = draft.validationMessage
    {
      Text(message)
        .font(.ottoDisplay(11))
        .foregroundStyle(palette.muted)
    }
  }

  private func send() {
    guard phase != .sending, draft.validationMessage == nil else { return }
    phase = .sending
    let draft = draft
    let client = client
    Task {
      do {
        let submission = try await client.send(draft)
        withAnimation(motion.enter(OttoMotion.fast)) { phase = .sent(submission) }
      } catch {
        phase = .failed((error as? FeedbackError ?? .server).userMessage)
      }
    }
  }
}

/// Renders Otto's own main window from its view hierarchy. Works without Screen Recording
/// permission because it never reads the screen, only Otto's views.
@MainActor
enum OttoWindowSnapshot {
  static func capture() -> CGImage? {
    guard let window = mainWindow, let view = window.contentView, view.bounds.width > 0 else {
      return nil
    }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep.cgImage
  }

  /// The frontmost normal Otto window, skipping sheets, panels and the Settings window.
  private static var mainWindow: NSWindow? {
    let candidates = NSApp.orderedWindows.filter {
      $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel) && $0.contentView != nil
        && $0.styleMask.contains(.titled)
        && $0.identifier?.rawValue.contains("Settings") != true
    }
    if let main = NSApp.mainWindow, candidates.contains(main) { return main }
    return candidates.first { $0.identifier?.rawValue.contains("otto-workspace") == true }
      ?? candidates.first
  }
}
