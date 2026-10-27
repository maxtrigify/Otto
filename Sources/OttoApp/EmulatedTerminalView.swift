import AppKit
import OttoModels
import OttoRuntime
import SwiftTerm
import SwiftUI

struct EmulatedTerminalView: NSViewRepresentable {
  @Environment(\.ottoPalette) private var palette
  @AppStorage(OttoPreferenceKey.fontScale) private var fontScaleRaw = OttoFontScale.standard
    .rawValue
  let output: String
  let outputStartOffset: Int
  let outputEndOffset: Int
  let sessionKey: String
  let acceptsInput: Bool
  let replayExistingOutput: Bool
  let send: (Data) -> Void
  let resize: (UInt16, UInt16) -> Void
  /// Changing this puts keyboard focus in the terminal, so typing and paste go to the process.
  var focusToken: Int = 0

  func makeCoordinator() -> Coordinator {
    Coordinator(
      replayExistingOutput: replayExistingOutput,
      send: send,
      resize: resize
    )
  }

  func makeNSView(context: Context) -> TerminalView {
    let view = TerminalView(frame: .zero)
    view.terminalDelegate = context.coordinator
    view.optionAsMetaKey = true
    view.allowMouseReporting = true
    view.changeScrollback(10_000)
    // Pin the palette the contrast filter judges against: the classic 16 colours plus the
    // standard xterm cube, instead of a cube re-derived from (and flipped by) the theme.
    view.getTerminal().ansi256PaletteStrategy = .xterm
    view.installColors(
      OttoTerminalColors.ansi16.map {
        SwiftTerm.Color(
          red: UInt16($0.red * 65535), green: UInt16($0.green * 65535),
          blue: UInt16($0.blue * 65535))
      })
    view.setAccessibilityLabel("Interactive terminal. Click to type or paste.")
    let scale = OttoFontScale(rawValue: fontScaleRaw) ?? .standard
    context.coordinator.applyAppearance(
      fontSize: 11 * scale.multiplier,
      foreground: NSColor(palette.paper),
      background: NSColor(palette.ink),
      contrast: (palette.terminalForeground, palette.terminalBackground),
      to: view
    )
    return view
  }

  func updateNSView(_ view: TerminalView, context: Context) {
    let scale = OttoFontScale(rawValue: fontScaleRaw) ?? .standard
    context.coordinator.applyAppearance(
      fontSize: 11 * scale.multiplier,
      foreground: NSColor(palette.paper),
      background: NSColor(palette.ink),
      contrast: (palette.terminalForeground, palette.terminalBackground),
      to: view
    )
    context.coordinator.send = acceptsInput ? send : { _ in }
    context.coordinator.resize = resize
    context.coordinator.replayExistingOutput = replayExistingOutput
    context.coordinator.render(
      output: output,
      startOffset: outputStartOffset,
      endOffset: outputEndOffset,
      sessionKey: sessionKey,
      in: view
    )
    if focusToken != context.coordinator.appliedFocusToken {
      context.coordinator.appliedFocusToken = focusToken
      // The view may not be in a window yet on the update that reveals it.
      DispatchQueue.main.async { [weak view] in
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
      }
    }
  }

  static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) {
    view.terminalDelegate = nil
  }

  final class Coordinator: NSObject, TerminalViewDelegate {
    var send: (Data) -> Void
    var resize: (UInt16, UInt16) -> Void
    var replayExistingOutput: Bool
    var appliedFocusToken = 0
    private var renderedSessionKey: String?
    private var renderedEndOffset = 0
    private var refreshedSessionKey: String?
    private var renderedFontSize: CGFloat?
    private var renderedForeground: NSColor?
    private var renderedBackground: NSColor?
    /// Rewrites explicit text colours so output written for some other terminal background
    /// (white text from a dark-tuned TUI on a light theme, say) stays readable here.
    private var contrastFilter = TerminalContrastFilter(theme: OttoThemeCatalog.fieldNotes)

    init(
      replayExistingOutput: Bool,
      send: @escaping (Data) -> Void,
      resize: @escaping (UInt16, UInt16) -> Void
    ) {
      self.replayExistingOutput = replayExistingOutput
      self.send = send
      self.resize = resize
    }

    @MainActor
    func applyAppearance(
      fontSize: CGFloat,
      foreground: NSColor,
      background: NSColor,
      contrast: (foreground: ThemeColor, background: ThemeColor),
      to view: TerminalView
    ) {
      if contrast.foreground != contrastFilter.foreground
        || contrast.background != contrastFilter.background
      {
        let hadOutput = renderedSessionKey != nil
        contrastFilter.setColors(foreground: contrast.foreground, background: contrast.background)
        // Replayable transcripts re-render through the new theme's contrast; live sessions
        // can't be replayed, so they pick the new colours up from their next output.
        if hadOutput, replayExistingOutput { renderedSessionKey = nil }
      }
      let changed =
        renderedFontSize != fontSize
        || renderedForeground?.isEqual(foreground) != true
        || renderedBackground?.isEqual(background) != true
      guard changed else { return }
      renderedFontSize = fontSize
      renderedForeground = foreground
      renderedBackground = background
      view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
      view.nativeForegroundColor = foreground
      view.nativeBackgroundColor = background
      view.layer?.backgroundColor = background.cgColor
      view.getTerminal().updateFullScreen()
      view.needsDisplay = true
    }

    @MainActor
    func render(
      output: String,
      startOffset: Int,
      endOffset: Int,
      sessionKey: String,
      in view: TerminalView
    ) {
      let update = TerminalRenderPlanner.update(
        output: output,
        startOffset: startOffset,
        endOffset: endOffset,
        sessionKey: sessionKey,
        renderedSessionKey: renderedSessionKey,
        renderedEndOffset: renderedEndOffset,
        replayExistingOutput: replayExistingOutput
      )
      if update.resetsTerminal {
        view.feed(text: "\u{001B}c")
        contrastFilter.reset()
      }
      let bytes = contrastFilter.process(update.bytes)
      if !bytes.isEmpty { view.feed(byteArray: bytes[...]) }
      renderedSessionKey = sessionKey
      renderedEndOffset = update.renderedEndOffset
      if update.resetsTerminal, !replayExistingOutput {
        requestLiveRefresh(sessionKey: sessionKey, in: view)
      }
    }

    @MainActor
    private func requestLiveRefresh(sessionKey: String, in view: TerminalView) {
      guard refreshedSessionKey != sessionKey else { return }
      refreshedSessionKey = sessionKey
      DispatchQueue.main.async { [weak self, weak view] in
        guard let self, let view else { return }
        view.layoutSubtreeIfNeeded()
        let terminal = view.getTerminal()
        guard let columns = UInt16(exactly: terminal.cols),
          let rows = UInt16(exactly: terminal.rows),
          columns > 0, rows > 0
        else { return }
        self.resize(columns, rows)
      }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
      send(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
      guard let columns = UInt16(exactly: newCols), let rows = UInt16(exactly: newRows) else {
        return
      }
      resize(columns, rows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
  }
}
