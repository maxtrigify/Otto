import AppKit
import Carbon.HIToolbox
import Combine
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoServices
import ScreenCaptureKit
import SwiftUI

// Otto on screen: an opt-in desktop buddy that floats over every app. He strolls along the bottom
// of the screen, can be picked up and dropped, opens quick shortcuts when clicked, says when work
// finishes or needs approval, and brings answers to questions back in a speech bubble. Every
// question still becomes an ordinary chat, so nothing lives only in a bubble.

enum OttoBuddyPreferences {
  static let enabledKey = "otto.buddy.enabled"
  static let walkKey = "otto.buddy.walk"
  static let speakKey = "otto.buddy.speak"
  static let hideInFullScreenKey = "otto.buddy.hideInFullScreen"
  static let sizeKey = "otto.buddy.size"
  static let providerKey = "otto.buddy.provider"
  static let chatNodeKey = "otto.buddy.chatNodeID"
  static let positionKey = "otto.buddy.position"
  /// Set the first time he appears, for Home's Getting started checklist.
  static let everShownKey = "otto.buddy.everShown"
  static let summonShortcut = "⌥⌘O"

  /// Off until the person chooses him; every other switch defaults on.
  static func bool(_ key: String, defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: key) == nil ? key != enabledKey : defaults.bool(forKey: key)
  }

  static func size(defaults: UserDefaults = .standard) -> OttoBuddySize {
    OttoBuddySize(rawValue: defaults.string(forKey: sizeKey) ?? "") ?? .medium
  }

  static func provider(defaults: UserDefaults = .standard) -> AgentProvider {
    AgentProvider(rawValue: defaults.string(forKey: providerKey) ?? "") ?? .codex
  }

  static let providers: [AgentProvider] = [.codex, .claudeCode, .cursor, .openCode, .grok, .kimi]
}

enum OttoBuddySize: String, CaseIterable, Identifiable {
  case small, medium, large
  var id: String { rawValue }
  var width: CGFloat {
    switch self {
    case .small: 74
    case .medium: 96
    case .large: 128
    }
  }
  var height: CGFloat { (width * 0.8).rounded() }
  var title: String {
    switch self {
    case .small: "S"
    case .medium: "M"
    case .large: "L"
    }
  }
  /// Room around the drawing for the badge, the "z z" and the drop shadow.
  static let margin: CGFloat = 14
  /// Transparent space under his feet so the drop shadow isn't clipped.
  static let footroom: CGFloat = 6
  var panelSize: CGSize { CGSize(width: width + Self.margin * 2, height: height + Self.margin * 2) }
  /// Extra room either side of his window. He walks across it so the window itself (the costly
  /// part for the window server) moves about once a second instead of every frame.
  static let slack: CGFloat = 24
  var windowSize: CGSize {
    CGSize(width: panelSize.width + Self.slack * 2, height: panelSize.height)
  }
}

enum OttoBuddyPose: String, CaseIterable {
  case idle, thinking, waving, working, sleeping

  @MainActor private static var cache: [OttoBuddyPose: NSImage] = [:]

  @MainActor var image: NSImage? {
    if let image = Self.cache[self] { return image }
    let image = OttoAppResources.url(
      forResource: rawValue, withExtension: "png", subdirectory: "Brand/Buddy"
    ).flatMap(NSImage.init(contentsOf:))
    Self.cache[self] = image
    return image
  }
}

enum OttoBuddyMotion: Equatable {
  case still, waddle, carry, held, ponder, hop, shake

  private var spec: (angle: Double, lift: CGFloat, stretch: CGFloat, period: Double) {
    switch self {
    case .still: (0, 0, 1, 1)
    case .waddle: (4, -3, 1, 0.48)
    case .carry: (2.5, -5, 1, 0.42)
    case .held: (9, 0, 1.05, 0.9)
    case .ponder: (2, -2, 1, 1.6)
    case .hop: (0, -14, 1.04, 0.5)
    case .shake: (5, 0, 1, 0.24)
    }
  }

  /// The pose offset at a moment. Driven from the same 30 Hz tick that moves his window, so
  /// walking costs one update per frame instead of a separate display-rate animation.
  func wobble(at time: TimeInterval) -> OttoBuddyWobble {
    guard self != .still else { return .rest }
    let spec = spec
    let swing = sin(2 * .pi * time / spec.period)
    let up = (swing + 1) / 2
    return OttoBuddyWobble(
      angle: spec.angle * swing, lift: spec.lift * up, stretch: 1 + (spec.stretch - 1) * up)
  }
}

struct OttoBuddyWobble: Equatable {
  var angle: Double
  var lift: CGFloat
  var stretch: CGFloat
  static let rest = OttoBuddyWobble(angle: 0, lift: 0, stretch: 1)
}

/// Who a question goes to. Otto is the default; the rest come from Chat and the bot roster.
enum OttoBuddyTarget: Hashable, Identifiable {
  case otto
  case session(id: UUID, name: String)
  case bot(profileID: UUID, name: String, handle: String)

  var id: String {
    switch self {
    case .otto: "otto"
    case .session(let id, _): "session-\(id)"
    case .bot(let id, _, _): "bot-\(id)"
    }
  }

  var name: String {
    switch self {
    case .otto: "Otto"
    case .session(_, let name): name
    case .bot(_, let name, _): "@\(name)"
    }
  }
}

struct OttoBuddyReply: Equatable {
  var nodeID: UUID
  var question: String
  var from: String
  var thread: String
  var text: String
  var target: OttoBuddyTarget
  var screenshot: Bool = false

  /// Long answers show their opening lines and a way into Chat.
  var isLong: Bool { text.count > 320 || text.components(separatedBy: "\n").count > 6 }
}

struct OttoBuddyBubble: Identifiable, Equatable {
  enum Tone: Equatable { case info, working, success, attention, failure }
  enum Kind: Equatable {
    case note
    case reply(OttoBuddyReply)
    case finished(nodeID: UUID)
    case approval(nodeID: UUID)
    case needsYou(nodeID: UUID)
    case screenPermission
  }

  let id = UUID()
  var kind: Kind
  var tone: Tone
  var header: String
  var lead: String
  var detail: String?

  /// Short notes clear themselves; anything you might act on stays until handled.
  var lifetime: TimeInterval? {
    switch kind {
    case .note: 2.4
    case .finished: 9
    default: nil
    }
  }

  var isTransient: Bool { kind == .note }
}

@MainActor
final class OttoBuddyModel: ObservableObject {
  @Published var pose: OttoBuddyPose = .idle
  @Published var motion: OttoBuddyMotion = .still
  @Published var wobble = OttoBuddyWobble.rest
  /// Where the drawing sits inside his window, relative to the centre.
  @Published var strideOffset: CGFloat = 0
  @Published var facingLeft = false
  @Published var size = OttoBuddySize.medium
  @Published var bubble: OttoBuddyBubble?
  @Published var menuOpen = false
  @Published var inboxCount = 0
  @Published var running = 0
  @Published var tailX: CGFloat = 60
  @Published var draft = ""
  @Published var replyDraft = ""
  @Published var expanded = false
  @Published var target = OttoBuddyTarget.otto
  @Published var targets: [OttoBuddyTarget] = [.otto]

  var isSleeping: Bool { pose == .sleeping }
  var bots: [OttoBuddyTarget] {
    targets.filter { if case .bot = $0 { true } else { false } }
  }

  /// Bots whose handle starts with the "@word" being typed at the end of the draft.
  var mentionSuggestions: [OttoBuddyTarget] {
    guard let fragment = OttoBuddyMentions.trailingFragment(in: draft) else { return [] }
    return bots.filter {
      guard case .bot(_, let name, let handle) = $0 else { return false }
      return fragment.isEmpty || handle.lowercased().hasPrefix(fragment.lowercased())
        || name.lowercased().hasPrefix(fragment.lowercased())
    }
  }
}

enum OttoBuddyMentions {
  /// The word after a trailing "@", or nil when the draft doesn't end in a mention.
  static func trailingFragment(in text: String) -> String? {
    guard let at = text.lastIndex(of: "@") else { return nil }
    if at != text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
    let fragment = text[text.index(after: at)...]
    return fragment.allSatisfy { $0.isLetter || $0.isNumber } ? String(fragment) : nil
  }

  static func removingTrailingFragment(from text: String) -> String {
    guard trailingFragment(in: text) != nil, let at = text.lastIndex(of: "@") else { return text }
    return String(text[..<at]).trimmingCharacters(in: .whitespaces)
  }

  /// "@Follow-ups draft a reply" → the bot and the question without the mention.
  static func resolve(_ text: String, bots: [OttoBuddyTarget]) -> (OttoBuddyTarget, String)? {
    for case .bot(let id, let name, let handle) in bots {
      for token in ["@\(handle)", "@\(name)"] {
        guard let range = text.range(of: token, options: .caseInsensitive) else { continue }
        let after = range.upperBound
        if after < text.endIndex, text[after].isLetter || text[after].isNumber { continue }
        var question = text
        question.removeSubrange(range)
        question = question.replacingOccurrences(of: "  ", with: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return (.bot(profileID: id, name: name, handle: handle), question)
      }
    }
    return nil
  }
}

/// Everything the bubble and menu can ask the controller to do.
struct OttoBuddyActions {
  var submit: () -> Void = {}
  var pickTarget: (OttoBuddyTarget) -> Void = { _ in }
  var close: () -> Void = {}
  var open: (UUID) -> Void = { _ in }
  var sendReply: () -> Void = {}
  var approve: (UUID, Bool) -> Void = { _, _ in }
  var showNext: () -> Void = {}
  var askAboutScreen: () -> Void = {}
  var backToLastChat: () -> Void = {}
  var openOtto: () -> Void = {}
  var nap: () -> Void = {}
  var openScreenSettings: () -> Void = {}
}

/// The top edge of an app window, in Cocoa screen coordinates.
struct OttoBuddyLedge: Equatable {
  var windowID: CGWindowID
  var frame: CGRect
  var top: CGFloat { frame.maxY }
}

enum OttoBuddyLedges {
  struct Window: Equatable {
    var id: CGWindowID
    var frame: CGRect
  }

  /// Ordinary app windows (Otto's own included; his panels float above that level), front to
  /// back, in Cocoa coordinates. Bounds are readable without Screen Recording permission.
  static func onScreenWindows() -> [Window] {
    guard
      let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      let primaryHeight = NSScreen.screens.first?.frame.maxY
    else { return [] }
    return list.compactMap { info in
      guard (info[kCGWindowLayer as String] as? Int) == 0,
        (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
        let id = info[kCGWindowNumber as String] as? CGWindowID,
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
        let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"],
        let height = bounds["Height"]
      else { return nil }
      return Window(
        id: id, frame: CGRect(x: x, y: primaryHeight - y - height, width: width, height: height))
    }
  }

  /// The highest window top between two heights under `centerX` whose edge is actually visible
  /// (no window in front covers where he would stand). Small windows and edges at or below the
  /// Dock line don't count.
  static func find(
    in windows: [Window], centerX: CGFloat, from upper: CGFloat, to lower: CGFloat,
    above minimum: CGFloat
  ) -> OttoBuddyLedge? {
    var best: OttoBuddyLedge?
    for (index, window) in windows.enumerated() {
      let top = window.frame.maxY
      guard window.frame.width >= 240, window.frame.height >= 120, top <= upper, top >= lower,
        top > minimum, centerX > window.frame.minX + 24, centerX < window.frame.maxX - 24
      else { continue }
      let edge = CGPoint(x: centerX, y: top - 2)
      let standing = CGPoint(x: centerX, y: top + 8)
      if windows[..<index].contains(where: {
        $0.frame.contains(edge) || $0.frame.contains(standing)
      }) {
        continue
      }
      if best.map({ top > $0.top }) ?? true {
        best = OttoBuddyLedge(windowID: window.id, frame: window.frame)
      }
    }
    return best
  }
}

/// ⌥⌘O from any app. A Carbon hot key needs no Accessibility or Input Monitoring permission,
/// and is only registered while Otto is on screen so it never claims the keys otherwise.
final class OttoBuddyHotKey: @unchecked Sendable {
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private let action: @MainActor () -> Void

  init(action: @escaping @MainActor () -> Void) { self.action = action }

  func register() {
    guard hotKey == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData in
        guard let userData else { return noErr }
        let hotKey = Unmanaged<OttoBuddyHotKey>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { MainActor.assumeIsolated { hotKey.action() } }
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_O), UInt32(cmdKey | optionKey),
      EventHotKeyID(signature: OSType(0x4F54_544F), id: 1), GetApplicationEventTarget(), 0,
      &hotKey)
    // Another app already owns ⌥⌘O: leave the hot key off rather than half-registered.
    if status != noErr { hotKey = nil }
  }

  var isRegistered: Bool { hotKey != nil }

  func unregister() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
    hotKey = nil
    handler = nil
  }
}

/// A borderless panel that floats over every app and Space without activating Otto.
final class OttoBuddyPanel: NSPanel {
  init(size: CGSize) {
    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    isReleasedWhenClosed = false
    animationBehavior = .none
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Hosts the drawing and turns raw mouse input into pick-up, drop, click and right-click.
final class OttoBuddyCharacterHostingView: NSHostingView<OttoBuddyCharacterView> {
  var onPress: (CGPoint) -> Void = { _ in }
  var onDrag: (CGPoint) -> Void = { _ in }
  var onRelease: (CGPoint) -> Void = { _ in }
  var contextMenu: () -> NSMenu? = { nil }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { onPress(NSEvent.mouseLocation) }
  override func mouseDragged(with event: NSEvent) { onDrag(NSEvent.mouseLocation) }
  override func mouseUp(with event: NSEvent) { onRelease(NSEvent.mouseLocation) }
  override func rightMouseDown(with event: NSEvent) {
    guard let menu = contextMenu() else { return }
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }
}

@MainActor
final class OttoBuddyController: NSObject {
  static let shared = OttoBuddyController()

  let model = OttoBuddyModel()
  private weak var services: ApplicationServices?
  private var store: CanvasStore?
  private var characterPanel: OttoBuddyPanel?
  private var characterHost: OttoBuddyCharacterHostingView?
  private var bubblePanel: OttoBuddyPanel?
  private var bubbleHost: NSHostingView<OttoBuddyBubbleHost>?
  private var statusItem: NSStatusItem?
  private var eventTask: Task<Void, Never>?
  private var timer: Timer?
  private var fullScreenTimer: Timer?
  private var bubbleTimer: Timer?
  private var observers: [NSObjectProtocol] = []
  private var monitors: [Any] = []
  private var modelChanges: AnyCancellable?
  private var layoutScheduled = false
  private var bubbleSize = CGSize.zero

  // Where he is: the bottom-left of the character panel, in screen coordinates.
  private var origin = CGPoint.zero
  private var velocity = CGVector.zero
  private var direction: CGFloat = 1
  private enum Behaviour: Equatable {
    case walking
    case resting(until: Date)
    case held(offset: CGVector)
    case falling
    case sleeping
    case napping(until: Date)
  }
  private var behaviour = Behaviour.resting(until: .now.addingTimeInterval(2))
  private var press: (start: CGPoint, offset: CGVector, moved: Bool)?
  private var dragSamples: [(CGPoint, Date)] = []
  private var cheerUntil = Date.distantPast
  private var lastActivity = Date.now
  private var lastTick = Date.now
  private var hiddenForFullScreen = false

  // Work he is following.
  private struct PendingAsk {
    var question: String
    var target: OttoBuddyTarget
    var thread: String
    var screenshot: Bool
    var sawWork = false
  }
  private var pendingAsks: [UUID: PendingAsk] = [:]
  private var working: Set<UUID> = []
  private var waiting: [UUID: AgentLifecycleState] = [:]
  private var completions = CompletionEventFilter()
  private var inbox: [OttoBuddyBubble] = []
  private var lastNodeID: UUID?

  private var enabled: Bool { OttoBuddyPreferences.bool(OttoBuddyPreferences.enabledKey) }
  private lazy var hotKey = OttoBuddyHotKey { [weak self] in self?.summon() }

  /// While he's out and speaking up, he announces finished work instead of macOS banners.
  var replacesCompletionBanners: Bool {
    guard enabled, characterPanel != nil, !hiddenForFullScreen,
      OttoBuddyPreferences.bool(OttoBuddyPreferences.speakKey)
    else { return false }
    if case .napping = behaviour { return false }
    return true
  }
  func replacesCompletionBanners(for services: ApplicationServices) -> Bool {
    self.services === services && replacesCompletionBanners
  }

  private var isEngaged: Bool {
    model.menuOpen || (model.bubble.map { !$0.isTransient } ?? false)
  }

  // MARK: Lifecycle

  func start(services: ApplicationServices, store: CanvasStore) {
    guard self.services !== services else { return }
    eventTask?.cancel()
    self.services = services
    self.store = store
    let bus = services.supervisor.eventBus
    let stream = bus.stream(afterSequence: bus.latestSequence)
    eventTask = Task { [weak self] in
      for await event in stream {
        guard let self, !Task.isCancelled else { return }
        await self.consume(event)
      }
    }
    guard observers.isEmpty else { return }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.applyPreferences() }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.settleOnScreen() }
      })
    modelChanges = model.objectWillChange.sink { [weak self] _ in self?.scheduleBubbleLayout() }
    applyPreferences()
    #if DEBUG
      installDebugHook()
    #endif
  }

  #if DEBUG
    /// Development only: lets scripts drive the real panels and capture what they draw, since
    /// agent shells usually lack Screen Recording permission.
    ///   menu | ask:<question> | note:<text> | snapshot:<path prefix>
    private func installDebugHook() {
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("app.otto.buddy.debug"), object: nil, queue: .main
      ) { [weak self] note in
        let command = note.object as? String ?? ""
        MainActor.assumeIsolated { self?.debug(command) }
      }
    }

    private func debug(_ command: String) {
      if command == "menu" {
        openMenu()
      } else if command.hasPrefix("draft:") {
        model.draft = String(command.dropFirst(6))
      } else if command.hasPrefix("ask:") {
        Task { await ask(String(command.dropFirst(4)), target: .otto) }
      } else if command.hasPrefix("drop:") {
        let parts = command.dropFirst(5).split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        ledge = nil
        origin = CGPoint(x: parts[0], y: parts[1])
        velocity = .zero
        behaviour = .falling
        moveCharacter()
      } else if command == "walk" {
        behaviour = .walking
        refreshPose()
      } else if command == "experiment:nowobble" {
        debugNoWobble = true
      } else if command == "experiment:nomove" {
        debugNoMove = true
      } else if command == "summon" {
        summon()
      } else if command.hasPrefix("status:") {
        let state = """
          origin=\(origin) ledge=\(ledge.map { "\($0.windowID) \($0.frame)" } ?? "none") \
          behaviour=\(behaviour) hotkey=\(hotKey.isRegistered) banners=\(replacesCompletionBanners)

          """
        try? state.write(
          toFile: String(command.dropFirst(7)), atomically: true, encoding: .utf8)
      } else if command.hasPrefix("note:") {
        say(lead: String(command.dropFirst(5)))
      } else if command.hasPrefix("snapshot:") {
        let prefix = String(command.dropFirst(9))
        for (name, panel) in [("character", characterPanel), ("bubble", bubblePanel)] {
          guard let panel, let view = panel.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
          else { continue }
          view.cacheDisplay(in: view.bounds, to: rep)
          try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
          let frame = panel.frame
          let state = "\(name) visible=\(panel.isVisible) key=\(panel.isKeyWindow) frame=\(frame)\n"
          if let handle = FileHandle(forWritingAtPath: "\(prefix)-state.txt") {
            handle.seekToEndOfFile()
            handle.write(Data(state.utf8))
            try? handle.close()
          } else {
            try? state.write(toFile: "\(prefix)-state.txt", atomically: true, encoding: .utf8)
          }
        }
      }
    }
  #endif

  private func applyPreferences() {
    let size = OttoBuddyPreferences.size()
    if enabled {
      if characterPanel == nil { show() }
      if model.size != size {
        model.size = size
        resizeCharacter()
      }
      if !OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey), behaviour == .walking {
        behaviour = .resting(until: .distantFuture)
      } else if OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey),
        case .resting(let until) = behaviour, until == .distantFuture
      {
        behaviour = .walking
      }
      updateStatusItem()
      refreshPose()
    } else if characterPanel != nil {
      hide()
    }
  }

  private func show() {
    model.size = OttoBuddyPreferences.size()
    let size = model.size.windowSize
    let panel = OttoBuddyPanel(size: size)
    let host = OttoBuddyCharacterHostingView(rootView: OttoBuddyCharacterView(model: model))
    host.frame = NSRect(origin: .zero, size: size)
    host.onPress = { [weak self] point in self?.pressed(at: point) }
    host.onDrag = { [weak self] point in self?.dragged(to: point) }
    host.onRelease = { [weak self] point in self?.released(at: point) }
    host.contextMenu = { [weak self] in self?.contextMenu() }
    host.setAccessibilityLabel("Otto")
    host.setAccessibilityRole(.button)
    panel.contentView = host
    characterPanel = panel
    characterHost = host

    let bubble = OttoBuddyPanel(size: CGSize(width: 300, height: 120))
    let bubbleHost = NSHostingView(
      rootView: OttoBuddyBubbleHost(model: model, actions: actions) { [weak self] size in
        guard let self, size != self.bubbleSize else { return }
        self.bubbleSize = size
        self.layoutBubble()
      })
    bubble.contentView = bubbleHost
    bubblePanel = bubble
    self.bubbleHost = bubbleHost

    origin = restoredOrigin(for: model.size.panelSize)
    moveCharacter(precise: true)
    panel.orderFrontRegardless()
    lastActivity = .now
    lastTick = .now
    behaviour =
      OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey)
      ? .resting(until: .now.addingTimeInterval(1.5)) : .resting(until: .distantFuture)
    timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    fullScreenTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkFullScreen() }
    }
    installMonitors()
    hotKey.register()
    UserDefaults.standard.set(true, forKey: OttoBuddyPreferences.everShownKey)
    updateStatusItem()
    refreshPose()
    if UserDefaults.standard.string(forKey: OttoBuddyPreferences.positionKey) == nil {
      say(
        lead: "Hi! I’ll hang out down here.",
        detail: "Click me for shortcuts, or drag me somewhere.")
    }
  }

  private func hide() {
    saveOrigin()
    timer?.invalidate()
    fullScreenTimer?.invalidate()
    bubbleTimer?.invalidate()
    timer = nil
    fullScreenTimer = nil
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    hotKey.unregister()
    ledge = nil
    characterPanel?.orderOut(nil)
    bubblePanel?.orderOut(nil)
    characterPanel = nil
    characterHost = nil
    bubblePanel = nil
    bubbleHost = nil
    model.menuOpen = false
    model.bubble = nil
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }

  private func installMonitors() {
    // A click anywhere else closes the quick menu, like any other popover.
    if let global = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown],
      handler: { [weak self] _ in
        MainActor.assumeIsolated { self?.closeMenuFromOutside() }
      })
    {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown],
      handler: { [weak self] event in
        MainActor.assumeIsolated {
          if let self, !(event.window is OttoBuddyPanel),
            !(event.window.map { String(describing: type(of: $0)).contains("Menu") } ?? false)
          {
            self.closeMenuFromOutside()
          }
        }
        return event
      })
    {
      monitors.append(local)
    }
  }

  private func closeMenuFromOutside() {
    if model.menuOpen { closeMenu() }
  }

  // MARK: Movement

  private var screen: NSScreen {
    let center = CGPoint(
      x: origin.x + model.size.panelSize.width / 2, y: origin.y + model.size.panelSize.height / 2)
    return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
      ?? NSScreen.screens[0]
  }

  /// He stands on the top edge of the Dock (or the screen bottom when the Dock is elsewhere).
  private var floorY: CGFloat { screen.visibleFrame.minY - OttoBuddySize.footroom + 1 }

  /// The top edge of another app's window he's standing on, if any.
  private var ledge: OttoBuddyLedge?
  private var ledgeCheckedAt = Date.distantPast

  /// Where his feet rest: a window ledge, or the Dock.
  private var groundY: CGFloat {
    ledge.map { $0.top - OttoBuddySize.footroom + 1 } ?? floorY
  }

  private var walkRange: ClosedRange<CGFloat> {
    let frame = ledge?.frame ?? screen.visibleFrame
    let width = model.size.panelSize.width
    return
      (frame.minX - OttoBuddySize.margin)...(max(
        frame.minX, frame.maxX - width + OttoBuddySize.margin))
  }

  private func tick() {
    let now = Date.now
    let dt = min(0.1, now.timeIntervalSince(lastTick))
    lastTick = now
    guard characterPanel != nil, !hiddenForFullScreen else { return }
    updateHitArea()

    switch behaviour {
    case .walking:
      guard !isEngaged, pendingAsks.isEmpty, !reduceMotion else {
        behaviour = .resting(until: now.addingTimeInterval(1))
        refreshPose()
        return
      }
      origin.x += 34 * direction * dt
      if origin.x <= walkRange.lowerBound || origin.x >= walkRange.upperBound {
        origin.x = min(max(origin.x, walkRange.lowerBound), walkRange.upperBound)
        direction *= -1
        refreshPose()
      }
      origin.y = groundY
      if Double.random(in: 0...1) < dt * 0.1 {
        behaviour = .resting(until: now.addingTimeInterval(.random(in: 2...6)))
        refreshPose()
      }
      moveCharacter()
    case .resting(let until):
      if until != .distantFuture, now >= until, !isEngaged, pendingAsks.isEmpty,
        OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey), !reduceMotion
      {
        if Bool.random() { direction *= -1 }
        behaviour = .walking
        refreshPose()
      }
    case .falling:
      let feetBefore = origin.y + OttoBuddySize.footroom - 1
      velocity.dy -= 2600 * dt
      origin.x += velocity.dx * dt
      origin.y += velocity.dy * dt
      velocity.dx *= 0.985
      origin.x = min(max(origin.x, walkRange.lowerBound), walkRange.upperBound)
      let feet = origin.y + OttoBuddySize.footroom - 1
      // He lands on the first visible window top he passes on the way down, else the Dock.
      if let landing = ledgeBetween(feetBefore, and: feet) {
        ledge = landing
        land(on: landing.top - OttoBuddySize.footroom + 1, now: now)
      } else if origin.y <= floorY {
        land(on: floorY, now: now)
      }
      moveCharacter()
    case .napping(let until):
      if now >= until { wake() }
    case .held, .sleeping:
      break
    }
    if ledge != nil, behaviour != .falling, now.timeIntervalSince(ledgeCheckedAt) > 0.1 {
      followLedge()
      ledgeCheckedAt = now
    }

    if case .napping = behaviour { return }
    if behaviour != .sleeping, now.timeIntervalSince(lastActivity) > 10 * 60, working.isEmpty,
      pendingAsks.isEmpty, !isEngaged
    {
      behaviour = .sleeping
      refreshPose()
    }
    if now > cheerUntil, model.motion == .hop { refreshPose() }
    let wobble =
      reduceMotion || debugNoWobble
      ? .rest : model.motion.wobble(at: now.timeIntervalSinceReferenceDate)
    if wobble != model.wobble { model.wobble = wobble }
  }

  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  private func land(on y: CGFloat, now: Date) {
    origin.y = y
    velocity = .zero
    behaviour = .resting(until: now.addingTimeInterval(1.2))
    cheer(for: 0.6)
    saveOrigin()
  }

  private func ledgeBetween(_ above: CGFloat, and below: CGFloat) -> OttoBuddyLedge? {
    guard below < above else { return nil }
    let centerX = origin.x + model.size.panelSize.width / 2
    return OttoBuddyLedges.find(
      in: OttoBuddyLedges.onScreenWindows(), centerX: centerX, from: above, to: below,
      above: floorY + OttoBuddySize.footroom)
  }

  /// Rides along when the window moves, and falls when it closes, hides or gets covered.
  private func followLedge() {
    guard let current = ledge else { return }
    let windows = OttoBuddyLedges.onScreenWindows()
    let centerX = origin.x + model.size.panelSize.width / 2
    guard let index = windows.firstIndex(where: { $0.id == current.windowID }) else {
      return dropOffLedge()
    }
    let frame = windows[index].frame
    let standing = CGPoint(x: centerX, y: frame.maxY + 8)
    if windows[..<index].contains(where: { $0.frame.contains(standing) }) {
      return dropOffLedge()
    }
    guard frame != current.frame else { return }
    origin.x += frame.minX - current.frame.minX
    ledge = OttoBuddyLedge(windowID: current.windowID, frame: frame)
    if case .held = behaviour { return }
    origin.y = groundY
    origin.x = min(max(origin.x, walkRange.lowerBound), walkRange.upperBound)
    moveCharacter()
    scheduleBubbleLayout()
  }

  private func dropOffLedge() {
    ledge = nil
    guard OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey) else { return }
    if case .held = behaviour { return }
    velocity = .zero
    behaviour = .falling
    refreshPose()
  }

  private var debugNoWobble = false
  private var debugNoMove = false

  private var windowOrigin = CGPoint(x: CGFloat.nan, y: .nan)

  /// `origin` is where he is; his window only follows when he walks out of its slack, or at
  /// once for vertical moves, drags and jumps.
  private func moveCharacter(precise: Bool = false) {
    if debugNoMove { return }
    guard let panel = characterPanel else { return }
    let slack = OttoBuddySize.slack
    let y = origin.y.rounded()
    var offset = origin.x - (windowOrigin.x + slack)
    if precise || y != windowOrigin.y || abs(offset) > slack || offset.isNaN {
      // Walking: park him at the trailing side so the next stretch fits inside the window.
      let lead: CGFloat = behaviour == .walking && !precise ? 0.9 * slack * direction : 0
      windowOrigin = CGPoint(x: (origin.x - slack + lead).rounded(), y: y)
      panel.setFrameOrigin(windowOrigin)
      offset = origin.x - (windowOrigin.x + slack)
    }
    let rounded = (offset * 2).rounded() / 2
    if model.strideOffset != rounded { model.strideOffset = rounded }
  }

  /// Clicks only land on him; the slack beside him lets them through to the app underneath.
  private func updateHitArea() {
    guard let panel = characterPanel else { return }
    let size = model.size.panelSize
    let mine = CGRect(origin: origin, size: size).insetBy(dx: 10, dy: 8)
    let ignore = press == nil && !mine.contains(NSEvent.mouseLocation)
    if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
  }

  private func resizeCharacter() {
    guard let panel = characterPanel else { return }
    let size = model.size.windowSize
    let bottom = origin.y
    panel.setContentSize(size)
    characterHost?.frame = NSRect(origin: .zero, size: size)
    origin.y = bottom
    origin.x = min(max(origin.x, walkRange.lowerBound), walkRange.upperBound)
    moveCharacter(precise: true)
    scheduleBubbleLayout()
  }

  private func settleOnScreen() {
    guard characterPanel != nil else { return }
    ledge = nil
    origin.x = min(max(origin.x, walkRange.lowerBound), walkRange.upperBound)
    if OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey) { origin.y = floorY }
    origin.y = max(origin.y, floorY)
    moveCharacter()
  }

  private func restoredOrigin(for size: CGSize) -> CGPoint {
    let parts = (UserDefaults.standard.string(forKey: OttoBuddyPreferences.positionKey) ?? "")
      .split(separator: ",").compactMap { Double($0) }
    let main = NSScreen.main ?? NSScreen.screens[0]
    var point =
      parts.count == 2
      ? CGPoint(x: parts[0], y: parts[1])
      : CGPoint(x: main.visibleFrame.minX + 120, y: main.visibleFrame.minY)
    if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -20, dy: -20).contains(point) }) {
      point = CGPoint(x: main.visibleFrame.minX + 120, y: main.visibleFrame.minY)
    }
    origin = point
    if OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey) || parts.count != 2 {
      point.y = floorY
    }
    return point
  }

  private func saveOrigin() {
    UserDefaults.standard.set(
      "\(Int(origin.x)),\(Int(origin.y))", forKey: OttoBuddyPreferences.positionKey)
  }

  // MARK: Pick up, drop, click

  private func pressed(at point: CGPoint) {
    press = (point, CGVector(dx: point.x - origin.x, dy: point.y - origin.y), false)
    dragSamples = [(point, .now)]
    lastActivity = .now
  }

  private func dragged(to point: CGPoint) {
    guard var current = press else { return }
    if !current.moved {
      guard hypot(point.x - current.start.x, point.y - current.start.y) > 4 else { return }
      current.moved = true
      press = current
      if model.menuOpen { closeMenu() }
      ledge = nil
      behaviour = .held(offset: current.offset)
      refreshPose()
    }
    origin = CGPoint(x: point.x - current.offset.dx, y: point.y - current.offset.dy)
    dragSamples.append((point, .now))
    if dragSamples.count > 6 { dragSamples.removeFirst() }
    moveCharacter(precise: true)
    scheduleBubbleLayout()
  }

  private func released(at point: CGPoint) {
    guard let current = press else { return }
    press = nil
    guard current.moved else {
      clicked()
      return
    }
    if OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey), origin.y > floorY + 1 {
      // A toss keeps a little of the throw; he never flies upward off the screen.
      if let first = dragSamples.first, let last = dragSamples.last {
        let seconds = max(0.016, last.1.timeIntervalSince(first.1))
        velocity = CGVector(
          dx: max(-900, min(900, (last.0.x - first.0.x) / seconds)),
          dy: min(0, (last.0.y - first.0.y) / seconds))
        if abs(velocity.dx) > 30 { direction = velocity.dx > 0 ? 1 : -1 }
      }
      behaviour = .falling
    } else {
      origin.y = max(origin.y, floorY)
      moveCharacter()
      behaviour = .resting(
        until: OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey)
          ? .now.addingTimeInterval(1.5) : .distantFuture)
      saveOrigin()
    }
    refreshPose()
  }

  private func clicked() {
    lastActivity = .now
    if case .napping = behaviour {
      wake()
      return
    }
    if behaviour == .sleeping {
      wake()
      return
    }
    model.menuOpen ? closeMenu() : openMenu()
  }

  /// The shortcut: wakes him if needed and opens his menu with the ask box ready.
  private func summon() {
    guard characterPanel != nil else { return }
    lastActivity = .now
    if hiddenForFullScreen {
      hiddenForFullScreen = false
      characterPanel?.orderFrontRegardless()
    }
    if case .napping = behaviour { wake() }
    if behaviour == .sleeping { wake() }
    if model.menuOpen { closeMenu() } else { openMenu() }
  }

  private func contextMenu() -> NSMenu {
    let menu = NSMenu()
    let napping: Bool = if case .napping = behaviour { true } else { false }
    menu.addItem(
      closureItem(napping ? "Wake Otto" : "Nap for an Hour") { [weak self] in
        napping ? self?.wake() : self?.nap()
      })
    menu.addItem(closureItem("Open Otto") { [weak self] in self?.openOtto() })
    menu.addItem(.separator())
    menu.addItem(closureItem("Otto on Screen Settings…") { [weak self] in self?.openSettings() })
    menu.addItem(
      closureItem("Hide Otto") {
        UserDefaults.standard.set(false, forKey: OttoBuddyPreferences.enabledKey)
      })
    return menu
  }

  // MARK: Pose

  private func refreshPose() {
    let running = !working.isEmpty
    let (pose, motion): (OttoBuddyPose, OttoBuddyMotion)
    switch behaviour {
    case .held: (pose, motion) = (.waving, .held)
    case .falling: (pose, motion) = (.waving, .still)
    case .sleeping, .napping: (pose, motion) = (.sleeping, .still)
    case .walking: (pose, motion) = running ? (.working, .carry) : (.idle, .waddle)
    case .resting:
      if Date.now < cheerUntil {
        (pose, motion) = (.waving, .hop)
      } else if let bubble = model.bubble,
        bubble.tone == .attention || bubble.tone == .failure, !bubble.isTransient
      {
        (pose, motion) = (.thinking, .shake)
      } else if !pendingAsks.isEmpty {
        (pose, motion) = (.thinking, .ponder)
      } else if running {
        (pose, motion) = (.working, .still)
      } else {
        (pose, motion) = (.idle, .still)
      }
    }
    let facingLeft = direction < 0
    if model.pose != pose { model.pose = pose }
    if model.motion != motion { model.motion = motion }
    if motion == .still, model.wobble != .rest { model.wobble = .rest }
    if model.facingLeft != facingLeft { model.facingLeft = facingLeft }
    if model.running != working.count { model.running = working.count }
  }

  private func cheer(for seconds: TimeInterval) {
    cheerUntil = .now.addingTimeInterval(seconds)
    if case .walking = behaviour {
      behaviour = .resting(until: .now.addingTimeInterval(seconds + 1))
    }
    refreshPose()
  }

  private func wake() {
    lastActivity = .now
    behaviour = .resting(
      until: OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey)
        ? .now.addingTimeInterval(1) : .distantFuture)
    cheer(for: 0.8)
    updateStatusItem()
  }

  private func nap() {
    closeMenu()
    dismissBubble()
    behaviour = .napping(until: .now.addingTimeInterval(60 * 60))
    refreshPose()
    updateStatusItem()
  }

  // MARK: Bubble and menu

  private var actions: OttoBuddyActions {
    OttoBuddyActions(
      submit: { [weak self] in self?.submitDraft() },
      pickTarget: { [weak self] target in
        guard let self else { return }
        model.target = target
        model.draft = OttoBuddyMentions.removingTrailingFragment(from: model.draft)
      },
      close: { [weak self] in
        self?.closeMenu()
        self?.dismissBubble()
      },
      open: { [weak self] nodeID in
        self?.dismissBubble()
        self?.openConversation(nodeID)
      },
      sendReply: { [weak self] in self?.sendReply() },
      approve: { [weak self] nodeID, approved in self?.resolveApproval(nodeID, approved: approved)
      },
      showNext: { [weak self] in self?.showNextFromInbox() },
      askAboutScreen: { [weak self] in
        guard let self else { return }
        let question = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.draft = ""
        closeMenu()
        Task { await self.askAboutScreen(question.isEmpty ? nil : question) }
      },
      backToLastChat: { [weak self] in self?.backToLastChat() },
      openOtto: { [weak self] in
        self?.closeMenu()
        self?.openOtto()
      },
      nap: { [weak self] in self?.nap() },
      openScreenSettings: { [weak self] in
        self?.dismissBubble()
        if let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        {
          NSWorkspace.shared.open(url)
        }
      })
  }

  private func openMenu() {
    if model.bubble?.isTransient == false, case .reply = model.bubble?.kind {
      // Keep an unread reply: it goes back into the waiting list.
      if let bubble = model.bubble { inbox.insert(bubble, at: 0) }
    }
    dismissBubble()
    model.targets = availableTargets()
    if !model.targets.contains(model.target) { model.target = .otto }
    model.inboxCount = inbox.count
    model.menuOpen = true
    behaviour = .resting(
      until: OttoBuddyPreferences.bool(OttoBuddyPreferences.walkKey)
        ? .now.addingTimeInterval(3) : .distantFuture)
    refreshPose()
    layoutBubble()
    bubblePanel?.makeKeyAndOrderFront(nil)
  }

  private func closeMenu() {
    guard model.menuOpen else { return }
    model.menuOpen = false
    bubblePanel?.resignKey()
  }

  private func present(_ bubble: OttoBuddyBubble, queueIfBusy: Bool = true) {
    if isEngaged {
      if queueIfBusy, !bubble.isTransient {
        inbox.append(bubble)
        model.inboxCount = inbox.count
      }
      return
    }
    if case .napping = behaviour, bubble.isTransient { return }
    if case .napping = behaviour { wake() }
    if behaviour == .sleeping { wake() }
    model.expanded = false
    model.replyDraft = ""
    model.bubble = bubble
    model.inboxCount = inbox.count
    if case .walking = behaviour { behaviour = .resting(until: .now.addingTimeInterval(2)) }
    refreshPose()
    layoutBubble()
    bubblePanel?.orderFrontRegardless()
    bubbleTimer?.invalidate()
    if let lifetime = bubble.lifetime {
      let id = bubble.id
      bubbleTimer = Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) {
        [weak self] _ in
        MainActor.assumeIsolated {
          if self?.model.bubble?.id == id { self?.dismissBubble() }
        }
      }
    }
  }

  private func say(lead: String, detail: String? = nil, tone: OttoBuddyBubble.Tone = .info) {
    present(
      OttoBuddyBubble(kind: .note, tone: tone, header: "Otto", lead: lead, detail: detail),
      queueIfBusy: false)
  }

  private func dismissBubble() {
    bubbleTimer?.invalidate()
    guard model.bubble != nil else { return }
    model.bubble = nil
    bubblePanel?.resignKey()
    refreshPose()
  }

  private func showNextFromInbox() {
    guard !inbox.isEmpty else { return }
    closeMenu()
    model.bubble = nil
    let next = inbox.removeFirst()
    model.inboxCount = inbox.count
    present(next)
  }

  private func scheduleBubbleLayout() {
    guard !layoutScheduled else { return }
    layoutScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.layoutScheduled = false
        self?.layoutBubble()
      }
    }
  }

  /// Sizes the bubble panel to its content and parks it just above his head.
  private func layoutBubble() {
    guard let panel = bubblePanel, bubbleHost != nil else { return }
    guard model.menuOpen || model.bubble != nil, !hiddenForFullScreen, bubbleSize.width > 2 else {
      if panel.isVisible { panel.orderOut(nil) }
      return
    }
    let size = bubbleSize
    let character = model.size.panelSize
    let headX = origin.x + character.width / 2
    let frame = screen.visibleFrame
    var x = headX - min(size.width / 2, 70)
    x = min(max(frame.minX + 6, x), frame.maxX - size.width - 6)
    var y = origin.y + OttoBuddySize.footroom + model.size.height - 14
    if y + size.height > frame.maxY { y = max(frame.minY, origin.y - size.height) }
    panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    let tail = (headX - x).rounded()
    if abs(model.tailX - tail) > 1 { model.tailX = tail }
    if model.menuOpen, !panel.isKeyWindow {
      // The ask field needs keyboard focus; a non-activating panel takes it without stealing
      // the app you're in.
      panel.makeKeyAndOrderFront(nil)
    } else if !panel.isVisible {
      panel.orderFrontRegardless()
    }
  }

  // MARK: Full screen

  /// Steps aside while another app owns the whole screen (video, slides, games).
  private func checkFullScreen() {
    // Something you summoned or are reading stays until you're done with it.
    let hide =
      OttoBuddyPreferences.bool(OttoBuddyPreferences.hideInFullScreenKey) && !isEngaged
      && frontmostAppIsFullScreen()
    guard hide != hiddenForFullScreen else { return }
    hiddenForFullScreen = hide
    if hide {
      characterPanel?.orderOut(nil)
      bubblePanel?.orderOut(nil)
    } else {
      characterPanel?.orderFrontRegardless()
      layoutBubble()
    }
  }

  private func frontmostAppIsFullScreen() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return false }
    let screens = NSScreen.screens.map(\.frame.size)
    return windows.contains { info in
      guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
        (info[kCGWindowLayer as String] as? Int) == 0,
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
        let width = bounds["Width"], let height = bounds["Height"]
      else { return false }
      return screens.contains { abs($0.width - width) < 1 && abs($0.height - height) < 1 }
    }
  }

  // MARK: Menu bar

  private func updateStatusItem() {
    guard enabled else { return }
    if statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      item.button?.image = NSImage(systemSymbolName: "eyes", accessibilityDescription: "Otto")
      item.button?.image?.isTemplate = true
      statusItem = item
    }
    let menu = NSMenu()
    let napping: Bool = if case .napping = behaviour { true } else { false }
    let showItem = closureItem("Show Otto on Screen") {
      UserDefaults.standard.set(false, forKey: OttoBuddyPreferences.enabledKey)
    }
    showItem.state = .on
    menu.addItem(showItem)
    menu.addItem(
      closureItem(napping ? "Wake Otto" : "Nap for an Hour") { [weak self] in
        napping ? self?.wake() : self?.nap()
      })
    menu.addItem(.separator())
    menu.addItem(closureItem("Open Otto") { [weak self] in self?.openOtto() })
    menu.addItem(closureItem("Settings…") { [weak self] in self?.openSettings() })
    statusItem?.menu = menu
  }

  private func closureItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
    let item = NSMenuItem(
      title: title, action: #selector(OttoBuddyMenuAction.run), keyEquivalent: "")
    let target = OttoBuddyMenuAction(action)
    item.target = target
    item.representedObject = target
    return item
  }

  // MARK: Opening Otto

  private func openOtto() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
  }

  private func openSettings() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
  }

  private func openConversation(_ nodeID: UUID) {
    lastNodeID = nodeID
    openOtto()
    NotificationCenter.default.post(name: .ottoOpenCompletedConversation, object: nodeID)
  }

  private func backToLastChat() {
    closeMenu()
    if let lastNodeID, node(lastNodeID) != nil {
      openConversation(lastNodeID)
    } else if let recent = recentSessions().first {
      openConversation(recent.id)
    } else {
      openOtto()
    }
  }

  // MARK: Asking

  private func availableTargets() -> [OttoBuddyTarget] {
    guard let services else { return [.otto] }
    let buddyChat = buddyChatNodeID()
    let sessions = recentSessions().filter { $0.id != buddyChat }.prefix(5).map {
      OttoBuddyTarget.session(id: $0.id, name: $0.displayName)
    }
    let bots = services.botRoster().map {
      OttoBuddyTarget.bot(
        profileID: $0.profile.id, name: $0.profile.name, handle: $0.profile.handle)
    }
    return [.otto] + sessions + bots
  }

  private func recentSessions() -> [OttoNode] {
    guard let services, let store else { return [] }
    let roster = services.botRoster()
    return homeSessionNodes(
      canvases: store.snapshot.canvases,
      botProfileIDs: Set(roster.map { $0.profile.id }),
      botNodeIDs: Set(roster.compactMap(\.nodeID)),
      backgroundNodeIDs: services.office.boundSessionIDs)
  }

  private func node(_ id: UUID) -> OttoNode? {
    store?.snapshot.canvases.lazy.flatMap(\.nodes).first { $0.id == id }
  }

  private func buddyChatNodeID() -> UUID? {
    guard let raw = UserDefaults.standard.string(forKey: OttoBuddyPreferences.chatNodeKey),
      let id = UUID(uuidString: raw), node(id) != nil
    else { return nil }
    return id
  }

  private func submitDraft() {
    var question = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else { return }
    var target = model.target
    if let (mentioned, rest) = OttoBuddyMentions.resolve(question, bots: model.bots), !rest.isEmpty
    {
      target = mentioned
      question = rest
    }
    model.draft = ""
    model.target = .otto
    closeMenu()
    Task { await ask(question, target: target) }
  }

  private func sendReply() {
    guard case .reply(let reply) = model.bubble?.kind else { return }
    let question = model.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else { return }
    model.replyDraft = ""
    dismissBubble()
    // Follow-ups stay in the conversation that answered.
    Task {
      await send(
        question, to: reply.nodeID, target: reply.target, thread: reply.thread,
        screenshot: reply.screenshot)
    }
  }

  func ask(_ question: String, target: OttoBuddyTarget) async {
    guard let services, let store else { return }
    lastActivity = .now
    do {
      let nodeID: UUID
      let thread: String
      switch target {
      case .otto:
        nodeID = try await ensureBuddyChat()
        thread = "Buddy chat"
      case .session(let id, let name):
        guard node(id) != nil else { throw BuddyError.unavailable(name) }
        nodeID = id
        thread = name
      case .bot(let profileID, let name, _):
        guard let entry = services.botRoster().first(where: { $0.profile.id == profileID }) else {
          throw BuddyError.unavailable("@\(name)")
        }
        if let existing = existingHomeBotNodeID(
          profileID: profileID, canonicalNodeID: entry.nodeID, canvases: store.snapshot.canvases)
        {
          nodeID = existing
        } else {
          nodeID = try await services.openBotChannel(entry.profile, at: placementPoint())
        }
        thread = "\(name) chat"
      }
      await send(question, to: nodeID, target: target, thread: thread, screenshot: false)
    } catch {
      present(
        OttoBuddyBubble(
          kind: .note, tone: .failure, header: "Otto", lead: "I couldn’t send that.",
          detail: error.localizedDescription))
    }
  }

  private func send(
    _ prompt: String, to nodeID: UUID, target: OttoBuddyTarget, thread: String, screenshot: Bool,
    displayQuestion: String? = nil
  ) async {
    guard let services else { return }
    pendingAsks[nodeID] = PendingAsk(
      question: displayQuestion ?? prompt, target: target, thread: thread, screenshot: screenshot)
    lastNodeID = nodeID
    present(
      OttoBuddyBubble(
        kind: .note, tone: .working, header: "Otto",
        lead: target == .otto ? "On it…" : "Asking \(target.name)…", detail: thread),
      queueIfBusy: false)
    refreshPose()
    do {
      try await services.sendPrompt(agentID: nodeID, prompt: prompt)
    } catch {
      pendingAsks[nodeID] = nil
      await services.recordConversationSendFailure(agentID: nodeID, prompt: prompt, error: error)
      present(
        OttoBuddyBubble(
          kind: .finished(nodeID: nodeID), tone: .failure, header: thread,
          lead: "That didn’t go through.", detail: error.localizedDescription))
    }
  }

  /// One ongoing conversation for questions asked of Otto himself.
  private func ensureBuddyChat() async throws -> UUID {
    if let existing = buddyChatNodeID() { return existing }
    guard let services else { throw BuddyError.unavailable("Otto") }
    let provider = OttoBuddyPreferences.provider()
    let id = try await services.spawnAgent(
      provider: provider, displayName: "Buddy chat", at: placementPoint(),
      permissionMode: Self.permissionMode(for: provider)
    ).agentID
    UserDefaults.standard.set(id.uuidString, forKey: OttoBuddyPreferences.chatNodeKey)
    return id
  }

  static func permissionMode(for provider: AgentProvider) -> AgentPermissionMode {
    let key =
      switch provider {
      case .claudeCode: OttoPreferenceKey.claudePermissionMode
      case .codex, .openAI: OttoPreferenceKey.codexPermissionMode
      case .hermes: OttoPreferenceKey.hermesPermissionMode
      case .cursor: OttoPreferenceKey.cursorPermissionMode
      case .kimi: OttoPreferenceKey.kimiPermissionMode
      case .openCode: OttoPreferenceKey.openCodePermissionMode
      case .grok: OttoPreferenceKey.grokPermissionMode
      case .shell: OttoPreferenceKey.shellPermissionMode
      }
    return AgentPermissionMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "")
      ?? .workspaceWrite
  }

  private func placementPoint() -> WorldPoint {
    guard let canvas = store?.activeCanvas else { return WorldPoint(x: 0, y: 0) }
    let offset = Double(canvas.nodes.count * 22)
    return WorldPoint(
      x: canvas.viewport.centerX - 170 + offset, y: canvas.viewport.centerY - 100 + offset)
  }

  enum BuddyError: LocalizedError {
    case unavailable(String)
    case capture(String)
    var errorDescription: String? {
      switch self {
      case .unavailable(let name): "\(name) isn’t available any more."
      case .capture(let reason): reason
      }
    }
  }

  // MARK: Ask about this screen

  private func askAboutScreen(_ question: String?) async {
    guard CGPreflightScreenCaptureAccess() else {
      CGRequestScreenCaptureAccess()
      present(
        OttoBuddyBubble(
          kind: .screenPermission, tone: .attention, header: "Otto",
          lead: "I can’t see your screen yet.",
          detail: "Allow Otto in Privacy & Security › Screen Recording, then try again."))
      return
    }
    guard let services else { return }
    let app = NSWorkspace.shared.frontmostApplication
    let appName =
      app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
      ? "Otto" : (app?.localizedName ?? "this app")
    do {
      let path = try await captureScreen()
      let ask = question ?? "What am I looking at, and is there anything here you can help with?"
      let prompt = """
        I’m looking at \(appName). A screenshot of my screen is saved at \(path). Open it and \
        answer briefly: \(ask)
        """
      let provider = OttoBuddyPreferences.provider()
      let nodeID = try await services.spawnAgent(
        provider: provider, displayName: "Screen: \(appName)", at: placementPoint(),
        permissionMode: Self.permissionMode(for: provider)
      ).agentID
      await send(
        prompt, to: nodeID, target: .session(id: nodeID, name: "Screen: \(appName)"),
        thread: "New chat · \(appName)", screenshot: true, displayQuestion: ask)
    } catch {
      present(
        OttoBuddyBubble(
          kind: .note, tone: .failure, header: "Otto", lead: "I couldn’t see the screen.",
          detail: error.localizedDescription))
    }
  }

  /// Captures the display under the pointer, leaving Otto's own windows out of the picture.
  private func captureScreen() async throws -> String {
    guard let services else { throw BuddyError.capture("Otto isn’t ready yet.") }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    let displayID =
      screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    guard
      let display = content.displays.first(where: { $0.displayID == displayID })
        ?? content.displays.first
    else { throw BuddyError.capture("No display was available to capture.") }
    let ours = content.applications.filter {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    let filter = SCContentFilter(
      display: display, excludingApplications: ours, exceptingWindows: [])
    let configuration = SCStreamConfiguration()
    let scale = min(2, 2560 / CGFloat(max(display.width, 1)))
    configuration.width = Int(CGFloat(display.width) * scale)
    configuration.height = Int(CGFloat(display.height) * scale)
    configuration.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    let folder = URL(fileURLWithPath: services.defaultWorkspacePath)
      .appending(path: ".otto/attachments/buddy", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let url = folder.appending(path: "screen-\(formatter.string(from: .now)).png")
    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw BuddyError.capture("The screenshot couldn’t be saved.") }
    try data.write(to: url, options: .atomic)
    return url.path
  }

  // MARK: Events

  private func consume(_ event: OttoEvent) async {
    guard enabled, let nodeID = event.nodeID else { return }
    switch event.type {
    case .agentStatusChanged:
      guard let state = event.state else { return }
      if state == .working || state == .starting {
        working.insert(nodeID)
        if state == .working { pendingAsks[nodeID]?.sawWork = true }
      } else {
        working.remove(nodeID)
      }
      if state == .waitingPermission || state == .waitingUser {
        if waiting[nodeID] != state {
          waiting[nodeID] = state
          await needsUser(nodeID, state: state)
        }
      } else {
        waiting[nodeID] = nil
        if model.bubble.map({
          $0.kind == .approval(nodeID: nodeID) || $0.kind == .needsYou(nodeID: nodeID)
        })
          == true
        {
          dismissBubble()
        }
      }
      // Some providers settle to idle without a separate completion event.
      if state == .idle || state == .done, pendingAsks[nodeID]?.sawWork == true {
        Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(1200))
          if self?.pendingAsks[nodeID] != nil { await self?.deliverReply(nodeID, failed: false) }
        }
      }
      refreshPose()
    case .agentRunCompleted, .agentRunFailed:
      working.remove(nodeID)
      guard completions.accept(event) else { return }
      let failed = event.type == .agentRunFailed
      if pendingAsks[nodeID] != nil {
        await deliverReply(nodeID, failed: failed)
      } else {
        finished(nodeID, failed: failed)
      }
      refreshPose()
    default:
      break
    }
  }

  private func deliverReply(_ nodeID: UUID, failed: Bool) async {
    guard let ask = pendingAsks.removeValue(forKey: nodeID), let services else { return }
    lastActivity = .now
    if failed {
      present(
        OttoBuddyBubble(
          kind: .finished(nodeID: nodeID), tone: .failure, header: ask.thread,
          lead: "Hmm, that hit a snag.", detail: "Open the chat to see what happened."))
      return
    }
    let status = try? await services.status(agentID: nodeID)
    let snapshot = services.fleetStore.snapshot(for: nodeID)
    let text =
      [
        status?.result, snapshot?.result,
        snapshot?.transcript.last(where: { $0.role == .assistant && $0.kind == .text })?.text,
      ]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty } ?? "Done. The answer is in the chat."
    let reply = OttoBuddyReply(
      nodeID: nodeID, question: ask.question,
      from: ask.target == .otto ? "Otto" : ask.target.name, thread: ask.thread, text: text,
      target: ask.target, screenshot: ask.screenshot)
    cheer(for: 1.2)
    present(
      OttoBuddyBubble(
        kind: .reply(reply), tone: .success, header: "\(reply.from) · \(reply.thread)",
        lead: reply.isLong ? "Here’s what I found." : "Got it.", detail: nil))
  }

  private func finished(_ nodeID: UUID, failed: Bool) {
    guard let services, let node = node(nodeID), node.isStandaloneAgent,
      !services.office.boundSessionIDs.contains(nodeID), nodeID != buddyChatNodeID()
    else { return }
    // Already looking at it in Otto: nothing to announce.
    if NSApp.isActive, CompletionNotifications.shared.visibleConversations.values.contains(nodeID) {
      return
    }
    let bubble = OttoBuddyBubble(
      kind: .finished(nodeID: nodeID), tone: failed ? .failure : .success,
      header: node.displayName,
      lead: failed ? "\(node.displayName) hit a snag." : "\(node.displayName) is done ✓",
      detail: failed ? "Open it to see what went wrong." : "The result is ready in Chat.")
    if failed || OttoBuddyPreferences.bool(OttoBuddyPreferences.speakKey) {
      cheer(for: failed ? 0 : 1)
      present(bubble)
    } else {
      inbox.append(bubble)
      model.inboxCount = inbox.count
    }
  }

  private func needsUser(_ nodeID: UUID, state: AgentLifecycleState) async {
    guard let services, let node = node(nodeID), node.isStandaloneAgent,
      !services.office.boundSessionIDs.contains(nodeID) || pendingAsks[nodeID] != nil
    else { return }
    let reason = services.fleetStore.snapshot(for: nodeID)?.attentionReason
    lastActivity = .now
    if state == .waitingPermission {
      present(
        OttoBuddyBubble(
          kind: .approval(nodeID: nodeID), tone: .attention, header: node.displayName,
          lead: "Can I go ahead?", detail: reason ?? "\(node.displayName) is asking for permission."
        ))
    } else {
      present(
        OttoBuddyBubble(
          kind: .needsYou(nodeID: nodeID), tone: .attention, header: node.displayName,
          lead: "\(node.displayName) has a question.",
          detail: reason ?? "Open the chat to answer."))
    }
  }

  private func resolveApproval(_ nodeID: UUID, approved: Bool) {
    dismissBubble()
    Task {
      await services?.resolveAgentPermission(agentID: nodeID, approved: approved)
      if approved { say(lead: "Approved ✓", tone: .success) }
    }
  }
}

/// NSMenuItem targets are weak; the item keeps this alive through `representedObject`.
private final class OttoBuddyMenuAction: NSObject {
  let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  @MainActor @objc func run() { action() }
}
