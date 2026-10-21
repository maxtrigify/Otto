import AppKit
import Foundation
import OttoBrowser
import OttoModels
import SwiftUI

enum OttoBrowserDefaults {
  static let bookmarks = [
    BrowserBookmark(title: "Gmail", url: "https://mail.google.com"),
    BrowserBookmark(title: "Linear", url: "https://linear.app"),
    BrowserBookmark(title: "GitHub", url: "https://github.com"),
    BrowserBookmark(title: "Google", url: "https://www.google.com"),
  ]
}

struct OttoBrowserToolbar: View {
  @Environment(\.ottoPalette) private var palette
  @FocusState private var addressFocused: Bool
  @Binding var address: String
  let addressFocusRequest: Int
  let scale: Double
  let state: BrowserRuntimeState?
  let sidebarSelected: Bool
  let agentRailSelected: Bool
  let captureStatus: String?
  let toggleSidebar: () -> Void
  let newTab: () -> Void
  let goHome: () -> Void
  let goBack: () -> Void
  let goForward: () -> Void
  let reloadOrStop: () -> Void
  let submit: () -> Void
  let capture: () -> Void
  let toggleAgentRail: () -> Void

  var body: some View {
    HStack(spacing: 3 * scale) {
      ChromeButton(
        symbol: "sidebar.left", help: "Toggle tabs", selected: sidebarSelected,
        scale: scale, action: toggleSidebar)
      ChromeButton(symbol: "plus", help: "New tab", scale: scale, action: newTab)
      ChromeButton(symbol: "house", help: "Otto Start", scale: scale, action: goHome)
      ChromeButton(
        symbol: "chevron.left", help: "Back",
        disabled: state.map { BrowserDefaults.isStartURL($0.url) } == true
          || state?.canGoBack != true,
        scale: scale, action: goBack)
      ChromeButton(
        symbol: "chevron.right", help: "Forward", disabled: state?.canGoForward != true,
        scale: scale, action: goForward)
      ChromeButton(
        symbol: state?.isLoading == true ? "xmark" : "arrow.clockwise",
        help: state?.isLoading == true ? "Stop loading" : "Reload", scale: scale,
        action: reloadOrStop)

      HStack(spacing: 5 * scale) {
        Image(systemName: secureConnection ? "lock.fill" : "globe")
          .font(.system(size: max(5.5, 6.5 * scale), weight: .semibold))
          .foregroundStyle(secureConnection ? palette.cyan.opacity(0.8) : palette.muted)
        TextField("Search or enter address", text: $address)
          .textFieldStyle(.plain)
          .font(.ottoMono(max(6.5, 7.5 * scale)))
          .foregroundStyle(palette.paper.opacity(0.82))
          .focused($addressFocused)
          .onSubmit(submit)
        if state?.isLoading == true {
          ProgressView().controlSize(.mini).tint(palette.cyan)
        }
      }
      .padding(.horizontal, 9 * scale)
      .frame(height: max(21, 25 * scale))
      .background(palette.ink.opacity(0.48), in: RoundedRectangle(cornerRadius: 7 * scale))
      .overlay(RoundedRectangle(cornerRadius: 7 * scale).stroke(.white.opacity(0.055)))
      .layoutPriority(1)

      ChromeButton(
        symbol: captureStatus?.hasPrefix("Saved") == true ? "checkmark" : "camera",
        help: captureStatus ?? "Save screenshot", scale: scale, action: capture)
      ChromeButton(
        symbol: "sparkles", help: "Otto Agent", selected: agentRailSelected,
        accent: palette.cyan, scale: scale, action: toggleAgentRail)
    }
    .padding(.horizontal, 6 * scale)
    .frame(height: max(31, 34 * scale))
    .background(palette.raised.opacity(0.94))
    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.055)).frame(height: 1) }
    .task(id: addressFocusRequest) {
      guard addressFocusRequest > 0 else { return }
      await Task.yield()
      addressFocused = true
      await Task.yield()
      NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
    }
  }

  private var secureConnection: Bool {
    URL(string: address)?.scheme?.lowercased() == "https"
  }
}

enum OttoBrowserInputAction: Equatable {
  case newTab
  case closeTab
  case reopenTab
  case focusAddress
  case reload
  case nextTab
  case previousTab
  case back
  case forward
}

enum OttoBrowserInputPolicy {
  static func keyAction(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
  ) -> OttoBrowserInputAction? {
    let significant = modifiers.intersection([.command, .option, .control, .shift])
    switch (keyCode, significant) {
    case (17, [.command]), (17, [.control]): return .newTab
    case (13, [.command]): return .closeTab
    case (17, [.command, .shift]): return .reopenTab
    case (37, [.command]): return .focusAddress
    case (15, [.command]): return .reload
    case (30, [.command, .shift]), (48, [.control]): return .nextTab
    case (33, [.command, .shift]), (48, [.control, .shift]): return .previousTab
    case (33, [.command]): return .back
    case (30, [.command]): return .forward
    default: return nil
    }
  }

  static func mouseAction(buttonNumber: Int) -> OttoBrowserInputAction? {
    switch buttonNumber {
    case 3: .back
    case 4: .forward
    default: nil
    }
  }
}

/// Browser-local input routing. Keyboard commands follow the selected node; mouse history buttons
/// additionally require the pointer to be inside this browser so another app surface is untouched.
struct OttoBrowserInputMonitor: NSViewRepresentable {
  let isEnabled: Bool
  let perform: (OttoBrowserInputAction) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    context.coordinator.update(
      view: view,
      isEnabled: isEnabled,
      perform: perform
    )
    context.coordinator.install()
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.update(
      view: view,
      isEnabled: isEnabled,
      perform: perform
    )
  }

  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator: NSObject {
    private weak var view: NSView?
    private var monitor: Any?
    private var isEnabled = false
    private var perform: ((OttoBrowserInputAction) -> Void)?

    func update(
      view: NSView,
      isEnabled: Bool,
      perform: @escaping (OttoBrowserInputAction) -> Void
    ) {
      self.view = view
      self.isEnabled = isEnabled
      self.perform = perform
    }

    func install() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) {
        [weak self] event in
        guard let self, self.isEnabled, let window = self.view?.window,
          event.window === window, window.isKeyWindow
        else { return event }
        let action: OttoBrowserInputAction?
        if event.type == .keyDown {
          action = OttoBrowserInputPolicy.keyAction(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
          )
        } else {
          guard self.contains(event) else { return event }
          action = OttoBrowserInputPolicy.mouseAction(buttonNumber: event.buttonNumber)
        }
        guard let action else { return event }
        self.perform?(action)
        return nil
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    private func contains(_ event: NSEvent) -> Bool {
      guard let view, event.window === view.window else { return false }
      return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }
  }
}

struct OttoBrowserSidebar: View {
  @Environment(\.ottoPalette) private var palette
  let session: BrowserSession
  let scale: Double
  let selectTab: (UUID) -> Void
  let closeTab: (UUID) -> Void
  let newTab: () -> Void
  let showImport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 7 * scale) {
        Circle()
          .fill(palette.cyan.opacity(0.9))
          .frame(width: 7 * scale, height: 7 * scale)
        Text("PERSONAL")
          .font(.ottoMono(max(5.5, 6.5 * scale), weight: .black))
          .tracking(0.9 * scale)
        Spacer()
        Button(action: newTab) {
          Image(systemName: "plus")
            .font(.system(size: max(6, 7 * scale), weight: .bold))
            .frame(width: 18 * scale, height: 18 * scale)
        }
        .buttonStyle(.ottoChrome(cornerRadius: 4))
        .help("New tab")
      }
      .foregroundStyle(palette.paper.opacity(0.78))
      .padding(.horizontal, 9 * scale)
      .frame(height: max(29, 33 * scale))

      Rectangle().fill(.white.opacity(0.055)).frame(height: 1)

      ScrollView {
        // The active plate and the hover wash both glide between tabs.
        OttoFluidHover(
          axis: .vertical,
          style: OttoFluidHoverStyle(
            fill: palette.paper.opacity(0.05),
            selectedFill: palette.paper.opacity(0.075),
            cornerRadius: 6 * scale),
          selected: session.activeTabID
        ) {
          LazyVStack(spacing: 2 * scale) {
            ForEach(session.tabs) { tab in
              BrowserTabRow(
                tab: tab,
                isActive: session.activeTabID == tab.id,
                scale: scale,
                select: { selectTab(tab.id) },
                close: { closeTab(tab.id) }
              )
              .ottoHoverItem(tab.id)
            }
          }
          .padding(.horizontal, 5 * scale)
          .padding(.vertical, 5 * scale)
        }
      }
      .ottoScrollChrome(fade: 12)

      VStack(spacing: 2 * scale) {
        SidebarAction(title: "New Tab", symbol: "plus", scale: scale, action: newTab)
        SidebarAction(
          title: "Import", symbol: "square.and.arrow.down", scale: scale, action: showImport)
      }
      .padding(5 * scale)
      .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.055)).frame(height: 1) }
    }
    .frame(width: max(102, 122 * scale))
    .background(palette.ink.opacity(0.74))
    .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.055)).frame(width: 1) }
  }
}

struct OttoBrowserBookmarksBar: View {
  @Environment(\.ottoPalette) private var palette
  let bookmarks: [BrowserBookmark]
  let scale: Double
  let navigate: (String) -> Void
  let showImport: () -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 2 * scale) {
        ForEach(displayedBookmarks) { bookmark in
          Button {
            navigate(bookmark.url)
          } label: {
            HStack(spacing: 5 * scale) {
              BrowserFavicon(url: bookmark.url, size: 13 * scale)
              Text(bookmark.title)
                .font(.ottoMono(max(5.5, 6.5 * scale), weight: .medium))
                .foregroundStyle(palette.paper.opacity(0.76))
                .lineLimit(1)
            }
            .padding(.horizontal, 7 * scale)
            .frame(height: max(22, 25 * scale))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(bookmark.url)
        }
        if bookmarks.isEmpty {
          Button(action: showImport) {
            Label("Import bookmarks", systemImage: "square.and.arrow.down")
              .font(.ottoMono(max(5.5, 6.5 * scale), weight: .medium))
              .foregroundStyle(palette.muted)
              .padding(.horizontal, 7 * scale)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 4 * scale)
    }
    .frame(height: max(25, 28 * scale))
    .background(palette.surface.opacity(0.92))
    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.045)).frame(height: 1) }
  }

  private var displayedBookmarks: [BrowserBookmark] {
    bookmarks.isEmpty ? OttoBrowserDefaults.bookmarks : bookmarks
  }
}

struct OttoBrowserStartSurface: View {
  @Environment(\.ottoPalette) private var palette
  @FocusState private var queryFocused: Bool
  @Binding var query: String
  let focusRequest: Int
  let scale: Double
  let submit: () -> Void
  let newTab: () -> Void

  var body: some View {
    ZStack {
      palette.ink
      RadialGradient(
        colors: [palette.cyan.opacity(0.045), .clear],
        center: .center,
        startRadius: 0,
        endRadius: 300 * scale
      )

      VStack(spacing: 16 * scale) {
        OttoMark(size: 42 * scale).opacity(0.6)

        VStack(alignment: .leading, spacing: 8 * scale) {
          HStack(spacing: 8 * scale) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: max(8, 10 * scale), weight: .medium))
              .foregroundStyle(palette.muted)
            TextField("Search, open, or ask Otto…", text: $query)
              .textFieldStyle(.plain)
              .font(.ottoDisplay(max(11, 14 * scale)))
              .foregroundStyle(palette.paper)
              .focused($queryFocused)
              .onSubmit(submit)
            Button(action: submit) {
              Image(systemName: "arrow.up")
                .font(.system(size: max(7, 8 * scale), weight: .bold))
                .foregroundStyle(palette.ink)
                .frame(width: 25 * scale, height: 25 * scale)
                .background(palette.paper.opacity(0.78), in: Circle())
            }
            .buttonStyle(.plain)
          }

          Button(action: newTab) {
            Label("New tab", systemImage: "plus")
              .font(.ottoMono(max(6, 7 * scale), weight: .medium))
              .foregroundStyle(palette.muted)
              .padding(.horizontal, 9 * scale)
              .frame(height: 23 * scale)
              .background(.white.opacity(0.04), in: Capsule())
              .overlay(Capsule().stroke(.white.opacity(0.06)))
          }
          .buttonStyle(.plain)
        }
        .padding(12 * scale)
        .frame(maxWidth: 470 * scale)
        .background(palette.raised.opacity(0.66), in: RoundedRectangle(cornerRadius: 12 * scale))
        .overlay(RoundedRectangle(cornerRadius: 12 * scale).stroke(.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.22), radius: 24 * scale, y: 10 * scale)
      }
      .padding(24 * scale)
    }
    .task(id: focusRequest) {
      // Buttons keep keyboard focus after creating a tab. Defer one turn so the new start
      // surface is mounted, then put typing where the user expects it to go.
      await Task.yield()
      queryFocused = true
    }
  }
}

struct OttoBrowserAgentRail: View {
  @Environment(\.ottoPalette) private var palette
  let state: BrowserRuntimeState?
  let activities: [BrowserActivityEntry]
  let isBuildMode: Bool
  let scale: Double
  let inspect: () -> Void
  let capture: () -> Void
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(isBuildMode ? "BUILD MODE" : "OTTO AGENT")
          .font(.ottoMono(max(5.5, 6.3 * scale), weight: .black))
          .tracking(0.9 * scale)
        Spacer()
        Button(action: close) {
          Image(systemName: "chevron.right")
            .font(.system(size: max(5, 6 * scale), weight: .bold))
        }
        .buttonStyle(.plain)
      }
      .foregroundStyle(palette.paper.opacity(0.76))
      .padding(9 * scale)

      VStack(alignment: .leading, spacing: 9 * scale) {
        HStack(spacing: 7 * scale) {
          Circle()
            .fill(statusColor)
            .frame(width: 6 * scale, height: 6 * scale)
          Text(statusTitle)
            .font(.ottoDisplay(max(7.5, 9 * scale)))
            .foregroundStyle(palette.paper)
        }
        Text(statusDetail)
          .font(.ottoMono(max(5.5, 6.2 * scale)))
          .foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)

        if isBuildMode {
          HStack(spacing: 5 * scale) {
            BrowserRailAction(title: "Inspect", symbol: "scope", scale: scale, action: inspect)
            BrowserRailAction(title: "Evidence", symbol: "camera", scale: scale, action: capture)
          }
        }
      }
      .padding(.horizontal, 9 * scale)
      .padding(.vertical, 7 * scale)

      Rectangle().fill(.white.opacity(0.055)).frame(height: 1)

      HStack {
        Text("ACTIVITY")
          .font(.ottoMono(max(5, 5.7 * scale), weight: .black))
          .tracking(0.8 * scale)
        Spacer()
        Text("\(activities.count)")
          .font(.ottoMono(max(5, 5.7 * scale)))
      }
      .foregroundStyle(palette.muted)
      .padding(.horizontal, 9 * scale)
      .padding(.top, 9 * scale)

      if activities.isEmpty {
        VStack(alignment: .leading, spacing: 5 * scale) {
          Image(systemName: "sparkle.magnifyingglass")
            .foregroundStyle(palette.cyan.opacity(0.8))
          Text("Agent actions and verification evidence will appear here.")
            .font(.ottoMono(max(5.3, 6 * scale)))
            .foregroundStyle(palette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9 * scale)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(activities.suffix(12).reversed())) { activity in
              BrowserActivityRow(activity: activity, scale: scale)
            }
          }
          .padding(.horizontal, 9 * scale)
          .padding(.vertical, 5 * scale)
        }
      }

      HStack(spacing: 5 * scale) {
        Image(systemName: "hand.raised.fill")
        Text("You can take over at any time")
      }
      .font(.ottoMono(max(4.8, 5.5 * scale)))
      .foregroundStyle(palette.muted.opacity(0.8))
      .padding(9 * scale)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.raised.opacity(0.32))
    }
    .frame(width: max(148, 176 * scale))
    .background(palette.ink.opacity(0.8))
    .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.055)).frame(width: 1) }
  }

  private var statusTitle: String {
    switch state?.agentControlPhase {
    case .observing: "Reading page"
    case .acting: "Agent is driving"
    case nil: isBuildMode ? "Local preview ready" : "Agent tools ready"
    }
  }

  private var statusDetail: String {
    if isBuildMode {
      return "Inspect, exercise and capture this local build without leaving the canvas."
    }
    return "Otto can read and navigate this page. Commitment actions pause for you."
  }

  private var statusColor: Color {
    state?.agentControlPhase == .acting ? palette.signal : palette.cyan
  }
}

private struct BrowserRailAction: View {
  @Environment(\.ottoPalette) private var palette
  let title: String
  let symbol: String
  let scale: Double
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.ottoMono(max(4.8, 5.7 * scale), weight: .semibold))
        .padding(.horizontal, 7 * scale)
        .frame(height: 21 * scale)
        .background(palette.raised.opacity(0.7), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.07)))
    }
    .buttonStyle(.plain)
    .foregroundStyle(palette.paper.opacity(0.78))
  }
}

private struct BrowserActivityRow: View {
  @Environment(\.ottoPalette) private var palette
  let activity: BrowserActivityEntry
  let scale: Double

  var body: some View {
    HStack(alignment: .top, spacing: 7 * scale) {
      ZStack {
        Circle().fill(activityColor.opacity(0.14))
        Image(systemName: activitySymbol)
          .font(.system(size: max(4.5, 5.5 * scale), weight: .semibold))
          .foregroundStyle(activityColor)
      }
      .frame(width: 17 * scale, height: 17 * scale)

      VStack(alignment: .leading, spacing: 2 * scale) {
        Text(activity.title)
          .font(.ottoMono(max(5.2, 6.1 * scale), weight: .semibold))
          .foregroundStyle(palette.paper.opacity(0.82))
          .lineLimit(2)
        if let detail = activity.detail, !detail.isEmpty {
          Text(detail)
            .font(.ottoMono(max(4.6, 5.3 * scale)))
            .foregroundStyle(palette.muted)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 6 * scale)
    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.04)).frame(height: 1) }
  }

  private var activitySymbol: String {
    switch activity.kind {
    case .navigation: "arrow.up.right"
    case .observation: "eye"
    case .interaction: "cursorarrow.click.2"
    case .evidence: "checkmark.seal"
    case .warning: "exclamationmark.triangle"
    }
  }

  private var activityColor: Color {
    activity.succeeded ? (activity.kind == .evidence ? palette.signal : palette.cyan) : palette.red
  }
}

struct BrowserFavicon: View {
  @Environment(\.ottoPalette) private var palette
  let url: String
  let size: Double

  var body: some View {
    Group {
      if let faviconURL {
        AsyncImage(url: faviconURL) { phase in
          switch phase {
          case .success(let image): image.resizable().scaledToFit()
          default: fallback
          }
        }
      } else {
        fallback
      }
    }
    .frame(width: max(11, size), height: max(11, size))
    .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.2)))
  }

  private var faviconURL: URL? {
    guard let page = URL(string: url), let host = page.host else { return nil }
    return URL(string: "https://\(host)/favicon.ico")
  }

  private var fallback: some View {
    ZStack {
      RoundedRectangle(cornerRadius: max(2, size * 0.2)).fill(palette.paper.opacity(0.09))
      if BrowserDefaults.isStartURL(url) {
        Image(systemName: "sparkles")
          .font(.system(size: max(5, size * 0.48), weight: .semibold))
          .foregroundStyle(palette.cyan)
      } else {
        Text(browserHost(url)?.prefix(1).uppercased() ?? "•")
          .font(.ottoMono(max(5, size * 0.46), weight: .black))
          .foregroundStyle(palette.paper.opacity(0.68))
      }
    }
  }
}

private struct BrowserTabRow: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.ottoMotion) private var motion
  let tab: BrowserTab
  let isActive: Bool
  let scale: Double
  let select: () -> Void
  let close: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 6 * scale) {
      BrowserFavicon(url: tab.url, size: 13 * scale)
      Text(tab.title.nilIfEmpty ?? "New Tab")
        .font(.ottoDisplay(max(7.5, 9.5 * scale)))
        .foregroundStyle(isActive ? palette.paper : palette.paper.opacity(0.7))
        .lineLimit(1)
      Spacer(minLength: 0)
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: max(5, 6 * scale), weight: .bold))
          .foregroundStyle(palette.muted)
          .frame(width: 14 * scale, height: 14 * scale)
      }
      .buttonStyle(.ottoChrome(cornerRadius: 3))
      // Reserved, not inserted: revealing the close glyph never shifts the title.
      .opacity(hovering || isActive ? 1 : 0)
      .animation(motion.fade, value: hovering || isActive)
      .accessibilityHidden(!(hovering || isActive))
    }
    .padding(.horizontal, 7 * scale)
    .frame(height: max(23, 27 * scale))
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(tab.title)
    .accessibilityAddTraits(isActive ? .isSelected : [])
  }
}

private struct SidebarAction: View {
  @Environment(\.ottoPalette) private var palette
  let title: String
  let symbol: String
  let scale: Double
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.ottoMono(max(5.5, 6.5 * scale), weight: .medium))
        .foregroundStyle(palette.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6 * scale)
        .frame(height: max(21, 24 * scale))
        .contentShape(Rectangle())
    }
    .buttonStyle(.ottoChrome(cornerRadius: 5 * scale))
  }
}

private struct ChromeButton: View {
  @Environment(\.ottoPalette) private var palette
  let symbol: String
  let help: String
  var selected = false
  var disabled = false
  var accent: Color? = nil
  let scale: Double
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: max(6.5, 7.5 * scale), weight: .semibold))
        .foregroundStyle(selected ? (accent ?? palette.cyan) : palette.paper.opacity(0.62))
        .frame(width: max(20, 23 * scale), height: max(20, 23 * scale))
        .background(selected ? (accent ?? palette.cyan).opacity(0.1) : .clear, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.ottoChrome(cornerRadius: max(10, 11.5 * scale)))
    .disabled(disabled)
    .opacity(disabled ? 0.24 : 1)
    .help(help)
  }
}

private func browserHost(_ value: String?) -> String? {
  guard let value, let host = URL(string: value)?.host else { return nil }
  return host.replacingOccurrences(of: "www.", with: "")
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
