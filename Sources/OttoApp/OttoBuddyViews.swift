import AppKit
import OttoModels
import SwiftUI

/// Otto's sketchbook colours from openotto.io: cream paper, navy ink, ballpoint blue, one spark.
enum OttoBuddyInk {
  static let paper = Color(red: 1, green: 0.992, blue: 0.973)
  static let ink = Color(red: 0.086, green: 0.110, blue: 0.180)
  static let soft = ink.opacity(0.62)
  static let hair = ink.opacity(0.14)
  static let pen = Color(red: 0.169, green: 0.247, blue: 0.659)
  static let spark = Color(red: 1, green: 0.353, blue: 0.122)
  static let success = Color(red: 0.122, green: 0.616, blue: 0.333)
  static let failure = Color(red: 0.82, green: 0.23, blue: 0.23)
  static let working = Color(red: 0.878, green: 0.631, blue: 0)

  static func tone(_ tone: OttoBuddyBubble.Tone) -> Color {
    switch tone {
    case .info: pen
    case .working: working
    case .success: success
    case .attention: spark
    case .failure: failure
    }
  }
}

enum OttoBuddyFonts {
  static let registered: Bool = {
    guard
      let url = OttoAppResources.url(
        forResource: "NanumPenScript-Regular", withExtension: "ttf", subdirectory: "Fonts")
    else { return false }
    var error: Unmanaged<CFError>?
    return CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
      || (CTFontManagerCopyAvailableFontFamilyNames() as? [String])?.contains("Nanum Pen")
        == true
  }()

  /// Otto's notes are handwritten, as on the website.
  static func hand(_ size: CGFloat) -> Font {
    _ = registered
    return .custom("NanumPen-Regular", fixedSize: size)
  }
}

// MARK: Character

struct OttoBuddyCharacterView: View {
  @ObservedObject var model: OttoBuddyModel

  var body: some View {
    let size = model.size
    let wobble = model.wobble
    ZStack(alignment: .bottom) {
      // A soft ground shadow that stays put; a blurred shadow on the moving drawing would be
      // re-rendered every frame.
      Ellipse().fill(.black.opacity(0.22))
        .frame(width: size.width * 0.62 * (1 + wobble.lift / 60), height: size.width * 0.07)
        .offset(y: size.width * 0.03)
        .opacity(model.motion == .held ? 0 : 1)
      Group {
        if let image = model.pose.image {
          Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
          Image(systemName: "eyes").resizable().aspectRatio(contentMode: .fit)
            .foregroundStyle(OttoBuddyInk.ink)
        }
      }
      .frame(width: size.width, height: size.height, alignment: .bottom)
      .scaleEffect(x: model.facingLeft ? -1 : 1, y: wobble.stretch, anchor: .bottom)
      .rotationEffect(.degrees(wobble.angle), anchor: .bottom)
      .offset(y: wobble.lift)
    }
    .padding(.bottom, OttoBuddySize.footroom)
    .frame(width: size.panelSize.width, height: size.panelSize.height, alignment: .bottom)
    .overlay(alignment: .topTrailing) {
      if model.isSleeping {
        Text("z z").font(OttoBuddyFonts.hand(size.width * 0.26)).foregroundStyle(.white)
          .shadow(color: .black.opacity(0.4), radius: 2)
          .padding(.trailing, 2)
      } else if model.inboxCount > 0 {
        Text("\(model.inboxCount)")
          .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
          .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
          .background(Capsule().fill(OttoBuddyInk.spark))
          .padding(.top, 6).padding(.trailing, 10)
      }
    }
    .accessibilityElement()
    .accessibilityLabel(model.inboxCount > 0 ? "Otto, \(model.inboxCount) updates waiting" : "Otto")
    .offset(x: model.strideOffset)
    .frame(width: size.windowSize.width, height: size.windowSize.height)
  }
}

// MARK: Bubble

/// A speech bubble whose tail points down at Otto's head.
struct OttoBuddyBubbleShape: Shape {
  var tailX: CGFloat
  var radius: CGFloat = 18
  var tail: CGFloat = 10

  func path(in rect: CGRect) -> Path {
    let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tail)
    let x = min(max(tailX, body.minX + radius + tail), body.maxX - radius - tail)
    var path = Path()
    path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
    path.addArc(
      tangent1End: CGPoint(x: body.maxX, y: body.minY),
      tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
    path.addArc(
      tangent1End: CGPoint(x: body.maxX, y: body.maxY),
      tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
    path.addLine(to: CGPoint(x: x + tail, y: body.maxY))
    path.addLine(to: CGPoint(x: x, y: body.maxY + tail))
    path.addLine(to: CGPoint(x: x - tail, y: body.maxY))
    path.addArc(
      tangent1End: CGPoint(x: body.minX, y: body.maxY),
      tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
    path.addArc(
      tangent1End: CGPoint(x: body.minX, y: body.minY),
      tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
    path.closeSubpath()
    return path
  }
}

/// The bubble panel's content: the quick menu while open, otherwise the current bubble.
struct OttoBuddyBubbleHost: View {
  @ObservedObject var model: OttoBuddyModel
  var actions: OttoBuddyActions
  /// The panel is sized from what SwiftUI actually laid out, never from a stale fitting size.
  var onSize: (CGSize) -> Void = { _ in }

  var body: some View {
    Group {
      if model.menuOpen {
        OttoBuddyMenuView(model: model, actions: actions)
      } else if let bubble = model.bubble {
        OttoBuddyBubbleView(model: model, bubble: bubble, actions: actions)
      } else {
        Color.clear.frame(width: 1, height: 1)
      }
    }
    .fixedSize()
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: {
      onSize($0)
    }
    .environment(\.colorScheme, .light)
  }
}

private struct OttoBuddyCard<Content: View>: View {
  var tailX: CGFloat
  var width: CGFloat
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12 + 10)
      .frame(width: width, alignment: .leading)
      .background {
        let shape = OttoBuddyBubbleShape(tailX: tailX - 16)
        shape.fill(OttoBuddyInk.paper)
          .overlay(shape.stroke(OttoBuddyInk.ink, lineWidth: 2))
          .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 8)
      }
      .padding(16)
  }
}

struct OttoBuddyBubbleView: View {
  @ObservedObject var model: OttoBuddyModel
  let bubble: OttoBuddyBubble
  var actions: OttoBuddyActions
  @FocusState private var replyFocused: Bool

  private var reply: OttoBuddyReply? {
    if case .reply(let reply) = bubble.kind { reply } else { nil }
  }

  var body: some View {
    OttoBuddyCard(tailX: model.tailX, width: reply == nil ? 300 : 360) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Circle().fill(OttoBuddyInk.tone(bubble.tone)).frame(width: 7, height: 7)
          Text(bubble.header.uppercased())
            .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
            .foregroundStyle(OttoBuddyInk.soft).lineLimit(1)
          if reply?.screenshot == true {
            Label("Screenshot", systemImage: "paperclip").font(.system(size: 10.5))
              .foregroundStyle(OttoBuddyInk.soft)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Capsule().fill(OttoBuddyInk.hair))
          }
          Spacer(minLength: 8)
          if !bubble.isTransient {
            Button(action: actions.close) {
              Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                .foregroundStyle(OttoBuddyInk.soft)
            }
            .buttonStyle(.plain).accessibilityLabel("Close")
          }
        }
        if let reply {
          Text("You: “\(reply.question)”").font(.system(size: 11.5)).italic()
            .foregroundStyle(OttoBuddyInk.soft).lineLimit(1)
        }
        Text(bubble.lead).font(OttoBuddyFonts.hand(25)).foregroundStyle(OttoBuddyInk.pen)
          .fixedSize(horizontal: false, vertical: true)
        if let reply {
          answer(reply)
        } else if let detail = bubble.detail {
          // An approval can carry a whole email; it scrolls instead of outgrowing the screen.
          Text(detail).font(.system(size: 12)).foregroundStyle(OttoBuddyInk.soft)
            .cappedScroll(maxHeight: 240)
        }
        buttons
        if let reply { replyBox(reply) }
      }
    }
  }

  @ViewBuilder private func answer(_ reply: OttoBuddyReply) -> some View {
    let text = Text(Self.markdown(reply.text)).font(.system(size: 13.5))
      .foregroundStyle(OttoBuddyInk.ink).textSelection(.enabled)
    if model.expanded {
      ScrollView { text.frame(maxWidth: .infinity, alignment: .leading) }
        .frame(maxHeight: 320)
    } else {
      text.lineLimit(reply.isLong ? 4 : 12).fixedSize(horizontal: false, vertical: true)
    }
    if reply.isLong {
      Text("\(reply.text.split(whereSeparator: \.isWhitespace).count) words · saved in Chat")
        .font(.system(size: 11)).foregroundStyle(OttoBuddyInk.soft)
    }
  }

  @ViewBuilder private var buttons: some View {
    switch bubble.kind {
    case .note:
      EmptyView()
    case .reply(let reply):
      HStack(spacing: 8) {
        OttoBuddyButton(title: reply.isLong ? "Open in Chat" : "Open chat", style: .primary) {
          actions.open(reply.nodeID)
        }
        if reply.isLong {
          OttoBuddyButton(title: model.expanded ? "Show less" : "Show more") {
            model.expanded.toggle()
          }
        }
        if model.inboxCount > 0 {
          OttoBuddyButton(title: "Next (\(model.inboxCount))", action: actions.showNext)
        }
      }
    case .finished(let nodeID), .needsYou(let nodeID):
      HStack(spacing: 8) {
        OttoBuddyButton(title: "Open", style: .primary) { actions.open(nodeID) }
        OttoBuddyButton(title: "Later", action: actions.close)
        if model.inboxCount > 0 {
          OttoBuddyButton(title: "Next (\(model.inboxCount))", action: actions.showNext)
        }
      }
    case .approval(let nodeID):
      HStack(spacing: 8) {
        OttoBuddyButton(title: "Approve", style: .spark) { actions.approve(nodeID, true) }
        OttoBuddyButton(title: "Deny") { actions.approve(nodeID, false) }
        OttoBuddyButton(title: "Review") { actions.open(nodeID) }
      }
    case .screenPermission:
      HStack(spacing: 8) {
        OttoBuddyButton(title: "Open Settings", style: .primary, action: actions.openScreenSettings)
        OttoBuddyButton(title: "Not now", action: actions.close)
      }
    }
  }

  private func replyBox(_ reply: OttoBuddyReply) -> some View {
    VStack(spacing: 0) {
      Rectangle().fill(OttoBuddyInk.hair).frame(height: 1).padding(.vertical, 6)
      HStack(spacing: 6) {
        OttoBuddyField(placeholder: "Reply to \(reply.from)…", text: $model.replyDraft)
          .focused($replyFocused)
          .onSubmit(actions.sendReply)
        OttoBuddyButton(title: "Send", action: actions.sendReply)
      }
    }
  }

  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

// MARK: Quick menu

struct OttoBuddyMenuView: View {
  @ObservedObject var model: OttoBuddyModel
  var actions: OttoBuddyActions
  @FocusState private var focused: Bool

  var body: some View {
    OttoBuddyCard(tailX: model.tailX, width: 290) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text("To").font(.system(size: 12)).foregroundStyle(OttoBuddyInk.soft)
          targetMenu
          Spacer()
          Text("or type @").font(.system(size: 11)).foregroundStyle(OttoBuddyInk.soft)
        }
        .padding(.bottom, 4)
        OttoBuddyField(
          placeholder: model.target == .otto
            ? "Ask Otto anything…" : "Message \(model.target.name)…",
          text: $model.draft, prominent: true
        )
        .focused($focused)
        .onSubmit(actions.submit)
        .onExitCommand(perform: actions.close)
        if !model.mentionSuggestions.isEmpty {
          suggestions
        }
        Text(
          model.running == 0
            ? "Nothing running right now"
            : "\(model.running) agent\(model.running == 1 ? "" : "s") working"
        )
        .font(.system(size: 11.5)).foregroundStyle(OttoBuddyInk.soft)
        .padding(.horizontal, 8).padding(.top, 4)
        if model.inboxCount > 0 {
          row(
            "bubble.left.and.text.bubble.right",
            "\(model.inboxCount) update\(model.inboxCount == 1 ? "" : "s") waiting",
            highlight: true, action: actions.showNext)
        }
        row("eye", "Ask about this screen", action: actions.askAboutScreen)
        row("arrow.uturn.backward", "Back to last chat", action: actions.backToLastChat)
        Rectangle().fill(OttoBuddyInk.hair).frame(height: 1).padding(.vertical, 4)
        row("macwindow", "Open Otto", action: actions.openOtto)
        row("moon.zzz", "Nap for an hour", action: actions.nap)
      }
    }
    .onAppear { DispatchQueue.main.async { focused = true } }
  }

  private var targetMenu: some View {
    Menu {
      Section("Default") {
        Button("Otto · Buddy chat") { actions.pickTarget(.otto) }
      }
      let sessions = model.targets.filter { if case .session = $0 { true } else { false } }
      if !sessions.isEmpty {
        Section("Recent chats") {
          ForEach(sessions) { target in Button(target.name) { actions.pickTarget(target) } }
        }
      }
      if !model.bots.isEmpty {
        Section("Bots") {
          ForEach(model.bots) { target in Button(target.name) { actions.pickTarget(target) } }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Text(model.target.name).lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
          .foregroundStyle(OttoBuddyInk.soft)
      }
      .font(.system(size: 12, weight: .medium)).foregroundStyle(OttoBuddyInk.ink)
      .padding(.horizontal, 10).padding(.vertical, 3)
      .background(Capsule().strokeBorder(OttoBuddyInk.ink, lineWidth: 1.5))
      .frame(maxWidth: 170)
    }
    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    .accessibilityLabel("Send to \(model.target.name)")
  }

  private var suggestions: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("BOTS").font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
        .foregroundStyle(OttoBuddyInk.soft).padding(.horizontal, 8).padding(.top, 6)
      ForEach(model.mentionSuggestions.prefix(5)) { target in
        Button {
          actions.pickTarget(target)
        } label: {
          Text(target.name).font(.system(size: 13)).foregroundStyle(OttoBuddyInk.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(OttoBuddyRowStyle())
      }
    }
    .padding(.bottom, 4)
    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(OttoBuddyInk.ink, lineWidth: 1.5))
    .padding(.top, 4)
  }

  private func row(
    _ symbol: String, _ title: String, highlight: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol).frame(width: 20).foregroundStyle(
          highlight ? OttoBuddyInk.spark : OttoBuddyInk.ink.opacity(0.75))
        Text(title).foregroundStyle(OttoBuddyInk.ink)
          .fontWeight(highlight ? .medium : .regular)
        Spacer()
      }
      .font(.system(size: 13.5))
      .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
      .background(
        RoundedRectangle(cornerRadius: 8).fill(highlight ? OttoBuddyInk.spark.opacity(0.1) : .clear)
      )
    }
    .buttonStyle(OttoBuddyRowStyle())
  }
}

// MARK: Controls

struct OttoBuddyRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    OttoBuddyRow(configuration: configuration)
  }

  private struct OttoBuddyRow: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    var body: some View {
      configuration.label
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(OttoBuddyInk.ink.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0))
        )
        .onHover { hovering = $0 }
    }
  }
}

struct OttoBuddyButton: View {
  enum Style { case plain, primary, spark }
  let title: String
  var style: Style = .plain
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title).font(.system(size: 12, weight: .medium))
        .foregroundStyle(style == .plain ? OttoBuddyInk.ink : .white)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 9).fill(
            style == .primary
              ? OttoBuddyInk.ink
              : style == .spark
                ? OttoBuddyInk.spark
                : OttoBuddyInk.paper)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 9).strokeBorder(
            style == .spark ? OttoBuddyInk.spark : OttoBuddyInk.ink, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct OttoBuddyField: View {
  let placeholder: String
  @Binding var text: String
  var prominent = false

  var body: some View {
    TextField(
      "", text: $text,
      prompt: Text(placeholder).foregroundStyle(OttoBuddyInk.ink.opacity(0.4))
    )
    .textFieldStyle(.plain)
    .font(.system(size: prominent ? 14 : 13))
    .foregroundStyle(OttoBuddyInk.ink)
    .padding(.horizontal, 10).padding(.vertical, prominent ? 8 : 6)
    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(OttoBuddyInk.hair, lineWidth: 1.5))
  }
}

// MARK: Settings

struct OttoBuddySettingsView: View {
  @AppStorage(OttoBuddyPreferences.enabledKey) private var enabled = false
  @AppStorage(OttoBuddyPreferences.walkKey) private var walk = true
  @AppStorage(OttoBuddyPreferences.speakKey) private var speak = true
  @AppStorage(OttoBuddyPreferences.hideInFullScreenKey) private var hideInFullScreen = true
  @AppStorage(OttoBuddyPreferences.sizeKey) private var size = OttoBuddySize.medium.rawValue
  @AppStorage(OttoBuddyPreferences.providerKey) private var provider = AgentProvider.codex.rawValue
  @State private var canSeeScreen = CGPreflightScreenCaptureAccess()

  var body: some View {
    Form {
      Section {
        HStack(alignment: .center, spacing: 14) {
          if let image = OttoBuddyPose.waving.image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 64)
          }
          VStack(alignment: .leading, spacing: 3) {
            Toggle("Show Otto on screen", isOn: $enabled).font(.headline)
            Text(
              "Otto stays on your screen over every app. Click him for shortcuts, drag him anywhere, and he’ll tell you when work finishes or needs you."
            )
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.vertical, 4)
      }
      Section("Behaviour") {
        Toggle("Walk around", isOn: $walk)
        Text(
          "Drop him on a window and he walks along its top, riding with it when it moves. When off, he sits wherever you put him."
        ).font(.callout).foregroundStyle(.secondary)
        Toggle("Say when things finish", isOn: $speak)
        Text(
          "Approvals and answers to your questions always show. While he speaks up, he replaces the macOS banners. When off, finished work waits behind his badge and banners return."
        )
        .font(.callout).foregroundStyle(.secondary)
        Toggle("Hide when an app is full screen", isOn: $hideInFullScreen)
        LabeledContent("Summon from any app") {
          Text(OttoBuddyPreferences.summonShortcut)
            .font(.system(.body, design: .monospaced).weight(.semibold))
        }
        Picker("Size", selection: $size) {
          ForEach(OttoBuddySize.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented).frame(maxWidth: 260)
      }
      .disabled(!enabled)
      Section("Questions") {
        Picker("Otto answers with", selection: $provider) {
          ForEach(OttoBuddyPreferences.providers, id: \.rawValue) {
            Text($0.rawValue).tag($0.rawValue)
          }
        }
        Text(
          "Questions to Otto go into one ongoing “Buddy chat” in Chat. Pick a chat or bot in his menu, or type @ to ask a bot."
        )
        .font(.callout).foregroundStyle(.secondary)
      }
      .disabled(!enabled)
      Section("Ask about this screen") {
        HStack {
          Image(systemName: canSeeScreen ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(canSeeScreen ? .green : .orange)
          Text(
            canSeeScreen
              ? "Otto can take a screenshot when you ask about your screen."
              : "Needs Screen Recording permission. macOS asks the first time you use it."
          )
          .foregroundStyle(.secondary)
        }
        Button("Open Screen Recording Settings") {
          if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
          {
            NSWorkspace.shared.open(url)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 540, height: 560)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in canSeeScreen = CGPreflightScreenCaptureAccess() }
  }
}
