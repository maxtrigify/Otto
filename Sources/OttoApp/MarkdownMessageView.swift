import AppKit
import OttoModels
import SwiftUI

/// Renders agent prose as structured markdown: headings, fenced code (including ASCII/Mermaid
/// diagrams), lists, tables, quotes, and inline emphasis. Built for the conversation surface —
/// calm typography over the Otto palette rather than a general-purpose markdown engine.
/// Equatable so streaming snapshot updates skip re-parsing unchanged messages.
struct MarkdownMessageView: View, Equatable {
  let text: String
  let scale: Double
  let palette: OttoPalette
  let assetDirectory: URL?
  let presentedBlocks: [MarkdownBlock]?
  let resultScope: String

  init(
    text: String,
    scale: Double,
    palette: OttoPalette,
    assetDirectory: URL? = nil,
    presentedBlocks: [MarkdownBlock]? = nil,
    resultScope: String = ""
  ) {
    self.text = text
    self.scale = scale
    self.palette = palette
    self.assetDirectory = assetDirectory
    self.presentedBlocks = presentedBlocks
    self.resultScope = resultScope
  }

  nonisolated static func == (lhs: MarkdownMessageView, rhs: MarkdownMessageView) -> Bool {
    lhs.text == rhs.text && lhs.scale == rhs.scale && lhs.palette == rhs.palette
      && lhs.assetDirectory == rhs.assetDirectory && lhs.presentedBlocks == rhs.presentedBlocks
      && lhs.resultScope == rhs.resultScope
  }

  private var baseSize: Double { max(9, 11.5 * scale) }

  var body: some View {
    VStack(alignment: .leading, spacing: 9 * scale) {
      ForEach(presentedBlocks ?? MarkdownBlockParser.parse(text)) { block in
        blockView(block.content)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func blockView(_ block: MarkdownBlockContent) -> some View {
    switch block {
    case .paragraph(let source):
      if let chip = MarkdownLinkChip.standalone(from: source) {
        LinkChipView(chip: chip, scale: scale)
      } else {
        Text(inline(source))
          .font(.ottoDisplay(baseSize))
          .foregroundStyle(palette.paper)
          .lineSpacing(4 * scale)
          .fixedSize(horizontal: false, vertical: true)
          .modifier(MarkdownInlineLinkInteraction(source: source))
      }

    case .heading(let level, let source):
      Text(inline(source))
        .font(.ottoDisplay(baseSize * headingMultiplier(level)).weight(.bold))
        .foregroundStyle(palette.paper)
        .padding(.top, level <= 2 ? 5 * scale : 3 * scale)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MarkdownInlineLinkInteraction(source: source))

    case .code(let language, let code):
      if language?.lowercased() == "mermaid" {
        MermaidDiagramView(source: code, scale: scale)
      } else {
        CodeBlockView(language: language, code: code, scale: scale)
      }

    case .list(let items):
      VStack(alignment: .leading, spacing: 4 * scale) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 7 * scale) {
            Text(item.marker)
              .font(.ottoMono(baseSize * 0.72, weight: .bold))
              .foregroundStyle(palette.signal.opacity(0.85))
              .frame(minWidth: 13 * scale, alignment: .trailing)
            Text(inline(item.text))
              .font(.ottoDisplay(baseSize))
              .foregroundStyle(palette.paper)
              .lineSpacing(3.5 * scale)
              .fixedSize(horizontal: false, vertical: true)
              .modifier(MarkdownInlineLinkInteraction(source: item.text))
          }
          .padding(.leading, Double(item.indent) * 14 * scale)
        }
      }

    case .quote(let source):
      HStack(alignment: .top, spacing: 9 * scale) {
        RoundedRectangle(cornerRadius: 2)
          .fill(palette.signal.opacity(0.55))
          .frame(width: 3)
        Text(inline(source))
          .font(.ottoDisplay(baseSize))
          .foregroundStyle(palette.muted)
          .lineSpacing(3.5 * scale)
          .fixedSize(horizontal: false, vertical: true)
          .modifier(MarkdownInlineLinkInteraction(source: source))
      }

    case .table(let header, let rows):
      ScrollView(.horizontal, showsIndicators: true) {
        Grid(alignment: .leading, horizontalSpacing: 24 * scale, verticalSpacing: 10 * scale) {
          GridRow {
            ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
              Text(inline(cell))
                .font(.ottoDisplay(max(11, baseSize)).weight(.semibold))
                .tracking(0.5 * scale)
                .foregroundStyle(palette.muted)
                .modifier(MarkdownInlineLinkInteraction(source: cell))
            }
          }
          Divider().overlay(palette.paper.opacity(0.14)).gridCellUnsizedAxes(.horizontal)
          ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            GridRow {
              ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                Text(inline(cell))
                  .font(.ottoDisplay(max(12, baseSize)))
                  .foregroundStyle(palette.paper)
                  .modifier(MarkdownInlineLinkInteraction(source: cell))
              }
            }
          }
        }
        .padding(16 * scale)
      }
      .background(palette.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 9 * scale))
      .overlay(
        RoundedRectangle(cornerRadius: 9 * scale)
          .stroke(palette.paper.opacity(0.07), lineWidth: 1)
      )

    case .email(let draft):
      ChatEmailCard(draft: draft, scale: scale, palette: palette, storageScope: resultScope)

    case .inbox(let inbox):
      ChatInboxCard(storageScope: resultScope, inbox: inbox, scale: scale, palette: palette)

    case .rule:
      Rectangle()
        .fill(palette.paper.opacity(0.12))
        .frame(height: 1)
        .padding(.vertical, 3 * scale)

    case .image(let alt, let target):
      MarkdownImageView(
        alt: alt,
        target: target,
        assetDirectory: assetDirectory,
        scale: scale
      )
    }
  }

  private func headingMultiplier(_ level: Int) -> Double {
    switch level {
    case 1: 1.45
    case 2: 1.25
    case 3: 1.12
    default: 1.0
    }
  }

  private func inline(_ source: String) -> AttributedString {
    var attributed = InlineMarkdownCache.parse(source)
    var linkInsertions: [(Range<AttributedString.Index>, URL)] = []
    for run in attributed.runs {
      if let intent = run.inlinePresentationIntent, intent.contains(.code) {
        attributed[run.range].font = .ottoMono(baseSize * 0.88)
        attributed[run.range].foregroundColor = palette.cyan
        attributed[run.range].backgroundColor = palette.paper.opacity(0.07)
      }
      if let url = run.link {
        attributed[run.range].foregroundColor = palette.cyan
        attributed[run.range].underlineStyle = .single
        linkInsertions.append((run.range, url))
      }
    }
    // Prefix each link with a small open affordance that shares the link target, inserted back
    // to front so earlier ranges stay valid while mutating.
    for (range, url) in linkInsertions.reversed() {
      var marker = AttributedString("↗\u{00A0}")
      marker.link = url
      marker.foregroundColor = palette.cyan
      attributed.insert(marker, at: range.lowerBound)
    }
    return attributed
  }
}

/// Caches the inline markdown parse, the costly part of styling a line. Palette and size are
/// applied afterwards, so one entry serves every theme and scale.
enum InlineMarkdownCache {
  private final class Parsed {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
  }

  nonisolated(unsafe) private static let cache: NSCache<NSString, Parsed> = {
    let cache = NSCache<NSString, Parsed>()
    cache.countLimit = 8_000
    return cache
  }()

  static func parse(_ source: String) -> AttributedString {
    let key = source as NSString
    if let cached = cache.object(forKey: key) { return cached.value }
    let parsed =
      (try? AttributedString(
        markdown: source,
        options: AttributedString.MarkdownParsingOptions(
          interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
      )) ?? AttributedString(source)
    cache.setObject(Parsed(parsed), forKey: key)
    return parsed
  }
}

/// SwiftUI's selectable-text overlay consumes clicks before attributed-string links receive
/// them. Completed transcript rows deliberately enable selection at an ancestor, so link-bearing
/// inline blocks opt out locally. Plain prose still inherits selection, while links keep the
/// native `openURL` route installed by the conversation surface.
struct MarkdownInlineLinkInteraction: ViewModifier {
  let source: String

  @ViewBuilder
  func body(content: Content) -> some View {
    if MarkdownInlineLinkPolicy.containsLink(source) {
      content.textSelection(.disabled)
    } else {
      content
    }
  }
}

enum MarkdownInlineLinkPolicy {
  static func containsLink(_ source: String) -> Bool {
    guard
      let attributed = try? AttributedString(
        markdown: source,
        options: AttributedString.MarkdownParsingOptions(
          interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
      )
    else { return false }
    return attributed.runs.contains { $0.link != nil }
  }
}

private struct MarkdownImageView: View {
  @Environment(\.ottoPalette) private var palette
  let alt: String
  let target: String
  let assetDirectory: URL?
  let scale: Double

  private var remoteURL: URL? {
    guard let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased())
    else { return nil }
    return url
  }

  private var localImage: NSImage? {
    guard let url = ChatImageReference.localURL(target, directory: assetDirectory) else {
      return nil
    }
    return NSImage(contentsOf: url)
  }

  @State private var enlarged = false

  var body: some View {
    Group {
      if let remoteURL {
        AsyncImage(url: remoteURL) { phase in
          if let image = phase.image {
            image.resizable().scaledToFit()
          } else if phase.error != nil {
            placeholder
          } else {
            ProgressView()
          }
        }
      } else if let localImage {
        Image(nsImage: localImage).resizable().scaledToFit()
      } else {
        placeholder
      }
    }
    .frame(maxWidth: .infinity, maxHeight: 420 * scale, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .contentShape(Rectangle())
    .onTapGesture { enlarged = true }
    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { enlarged = true }
    .help("Click to enlarge")
    .sheet(isPresented: $enlarged) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(alt.isEmpty ? "Image" : alt).font(.headline)
          Spacer()
          Button("Done") { enlarged = false }.keyboardShortcut(.cancelAction)
        }
        if let localImage {
          Image(nsImage: localImage).resizable().scaledToFit()
        } else if let remoteURL {
          AsyncImage(url: remoteURL) { image in
            image.resizable().scaledToFit()
          } placeholder: {
            ProgressView()
          }
        } else {
          placeholder
        }
      }
      .padding(20)
      .frame(minWidth: 600, idealWidth: 900, minHeight: 450, idealHeight: 700)
    }
    .clipShape(RoundedRectangle(cornerRadius: 10 * scale))
    .overlay(
      RoundedRectangle(cornerRadius: 10 * scale)
        .stroke(palette.paper.opacity(0.08), lineWidth: 1)
    )
  }

  private var placeholder: some View {
    Label(alt.isEmpty ? "Image unavailable" : alt, systemImage: "photo")
      .font(.ottoDisplay(max(9, 11 * scale)))
      .foregroundStyle(palette.muted)
      .frame(maxWidth: .infinity, minHeight: 80 * scale)
      .background(palette.raised.opacity(0.5))
  }
}

// MARK: - Link chips

/// A paragraph that is nothing but one markdown link renders as a chip with the site's icon —
/// the "logo + name" reference treatment for sources and documentation links.
struct MarkdownLinkChip: Equatable {
  let title: String
  let url: URL

  var host: String { url.host ?? url.absoluteString }

  var faviconURL: URL? {
    guard let host = url.host, var components = URLComponents(string: "https://\(host)") else {
      return nil
    }
    components.path = "/favicon.ico"
    return components.url
  }

  static func standalone(from source: String) -> MarkdownLinkChip? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix(")"),
      let titleEnd = trimmed.range(of: "]("),
      !trimmed[trimmed.index(after: trimmed.startIndex)..<titleEnd.lowerBound].contains("]")
    else { return nil }
    let title = String(trimmed[trimmed.index(after: trimmed.startIndex)..<titleEnd.lowerBound])
    let target = String(trimmed[titleEnd.upperBound..<trimmed.index(before: trimmed.endIndex)])
    guard !target.contains(")"), !target.contains(" "),
      let url = URL(string: target), url.scheme?.hasPrefix("http") == true, !title.isEmpty
    else { return nil }
    return MarkdownLinkChip(title: title, url: url)
  }
}

private struct LinkChipView: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.openURL) private var openURL
  let chip: MarkdownLinkChip
  let scale: Double

  var body: some View {
    Button {
      openURL(chip.url)
    } label: {
      HStack(spacing: 7 * scale) {
        AsyncImage(url: chip.faviconURL) { phase in
          if let image = phase.image {
            image.resizable().scaledToFit()
          } else {
            Image(systemName: "link")
              .font(.system(size: max(7, 8 * scale), weight: .semibold))
              .foregroundStyle(palette.cyan)
          }
        }
        .frame(width: 13 * scale, height: 13 * scale)
        .clipShape(RoundedRectangle(cornerRadius: 3 * scale))
        Text(chip.title)
          .font(.ottoDisplay(max(9, 11 * scale)))
          .foregroundStyle(palette.paper)
          .lineLimit(1)
        Text(chip.host)
          .font(.ottoMono(max(6, 7 * scale)))
          .foregroundStyle(palette.muted)
          .lineLimit(1)
        Image(systemName: "arrow.up.right")
          .font(.system(size: max(6, 7 * scale), weight: .bold))
          .foregroundStyle(palette.muted)
      }
      .padding(.horizontal, 10 * scale)
      .padding(.vertical, 6 * scale)
      .background(palette.raised.opacity(0.7), in: Capsule())
      .overlay(Capsule().stroke(palette.paper.opacity(0.1), lineWidth: 1))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    // A link chip remains a single click target even when its surrounding message is selectable.
    .textSelection(.disabled)
    .help(chip.url.absoluteString)
    .accessibilityLabel("Open \(chip.title)")
  }
}

private struct CodeBlockView: View {
  @Environment(\.ottoPalette) private var palette
  let language: String?
  let code: String
  let scale: Double
  @State private var copied = false

  private static let diagramLanguages: Set<String> = [
    "mermaid", "plantuml", "dot", "graphviz", "d2", "ascii", "diagram",
  ]

  private var label: String {
    guard let language, !language.isEmpty else { return "CODE" }
    if Self.diagramLanguages.contains(language.lowercased()) {
      return "DIAGRAM · \(language.uppercased())"
    }
    return language.uppercased()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8 * scale) {
        Text(label)
          .font(.ottoMono(max(5.5, 6.5 * scale), weight: .black))
          .tracking(0.8 * scale)
          .foregroundStyle(palette.muted)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code, forType: .string)
          copied = true
          Task {
            try? await Task.sleep(for: .seconds(1.4))
            copied = false
          }
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: max(7, 8 * scale), weight: .medium))
            .foregroundStyle(copied ? palette.signal : palette.muted)
        }
        .buttonStyle(.plain)
        .help("Copy code")
      }
      // Keep the language label and Copy action interactive; only the code body participates in
      // the transcript's native text selection.
      .textSelection(.disabled)
      .padding(.horizontal, 11 * scale)
      .padding(.vertical, 6 * scale)
      .background(palette.paper.opacity(0.045))
      Divider().overlay(palette.paper.opacity(0.08))
      ScrollView(.horizontal, showsIndicators: false) {
        Text(code)
          .font(.ottoMono(max(8, 9.5 * scale)))
          .foregroundStyle(palette.paper.opacity(0.92))
          .lineSpacing(2.5 * scale)
          .padding(16 * scale)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(palette.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: 9 * scale))
    .overlay(
      RoundedRectangle(cornerRadius: 9 * scale)
        .stroke(palette.paper.opacity(0.08), lineWidth: 1)
    )
  }
}

// MARK: - Block model and parser

enum MarkdownBlockContent: Equatable {
  case email(ChatEmailDraft)
  case inbox(ChatInbox)
  case paragraph(String)
  case heading(level: Int, text: String)
  case code(language: String?, code: String)
  case list(items: [MarkdownListItem])
  case quote(String)
  case table(header: [String], rows: [[String]])
  case rule
  case image(alt: String, target: String)
}

struct MarkdownListItem: Equatable {
  let marker: String
  let indent: Int
  let text: String
}

struct MarkdownBlock: Identifiable, Equatable {
  let id: Int
  let content: MarkdownBlockContent
}

enum MarkdownBlockParser {
  private final class Parsed {
    let blocks: [MarkdownBlock]
    init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
  }

  /// Switching chats rebuilds every visible row, so parsing the same completed messages again
  /// made each switch stall. NSCache is thread-safe and evicts under memory pressure.
  nonisolated(unsafe) private static let cache: NSCache<NSString, Parsed> = {
    let cache = NSCache<NSString, Parsed>()
    cache.countLimit = 2_000
    return cache
  }()

  static func parse(_ source: String) -> [MarkdownBlock] {
    let key = source as NSString
    if let cached = cache.object(forKey: key) { return cached.blocks }
    let blocks = uncachedParse(source)
    cache.setObject(Parsed(blocks), forKey: key)
    return blocks
  }

  private static func uncachedParse(_ source: String) -> [MarkdownBlock] {
    if let email = ChatEmailDraft.legacy(source) {
      return [MarkdownBlock(id: 0, content: .email(email))]
    }
    var blocks: [MarkdownBlockContent] = []
    var paragraph: [String] = []
    var lines = ArraySlice(source.components(separatedBy: "\n"))

    func flushParagraph() {
      let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      paragraph = []
      if !joined.isEmpty { blocks.append(.paragraph(joined)) }
    }

    while let line = lines.first {
      lines = lines.dropFirst()
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        flushParagraph()
        let fence = String(trimmed.prefix(3))
        let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        var code: [String] = []
        var closed = false
        while let next = lines.first {
          lines = lines.dropFirst()
          if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
            closed = true
            break
          }
          code.append(next)
        }
        let content = code.joined(separator: "\n")
        blocks.append(
          (closed ? ChatResult.block(language: language, source: content) : nil)
            ?? .code(language: language.isEmpty ? nil : language, code: content))
        continue
      }

      if trimmed.isEmpty {
        flushParagraph()
        continue
      }

      if let heading = headingBlock(trimmed) {
        flushParagraph()
        blocks.append(heading)
        continue
      }

      if isRule(trimmed) {
        flushParagraph()
        blocks.append(.rule)
        continue
      }

      if let image = imageBlock(trimmed) {
        flushParagraph()
        blocks.append(image)
        continue
      }

      if trimmed.hasPrefix(">") {
        flushParagraph()
        var quoteLines = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
        while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix(">") {
          lines = lines.dropFirst()
          quoteLines.append(String(next.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        blocks.append(.quote(quoteLines.joined(separator: "\n")))
        continue
      }

      if trimmed.hasPrefix("|"),
        let separator = lines.first?.trimmingCharacters(in: .whitespaces),
        isTableSeparator(separator)
      {
        flushParagraph()
        lines = lines.dropFirst()
        let header = tableCells(trimmed)
        var rows: [[String]] = []
        while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix("|") {
          lines = lines.dropFirst()
          rows.append(tableCells(next, columnCount: header.count))
        }
        blocks.append(.table(header: header, rows: rows))
        continue
      }

      if let item = listItem(line) {
        flushParagraph()
        var items = [item]
        while let next = lines.first, let nextItem = listItem(next) {
          lines = lines.dropFirst()
          items.append(nextItem)
        }
        blocks.append(.list(items: items))
        continue
      }

      paragraph.append(line)
    }
    flushParagraph()

    return blocks.enumerated().map { MarkdownBlock(id: $0.offset, content: $0.element) }
  }

  private static func headingBlock(_ trimmed: String) -> MarkdownBlockContent? {
    guard trimmed.hasPrefix("#") else { return nil }
    let hashes = trimmed.prefix(while: { $0 == "#" })
    guard hashes.count <= 6 else { return nil }
    let remainder = trimmed.dropFirst(hashes.count)
    guard remainder.first == " " else { return nil }
    let text = remainder.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return .heading(level: hashes.count, text: text)
  }

  private static func imageBlock(_ trimmed: String) -> MarkdownBlockContent? {
    guard let reference = ChatImageReference.parse(trimmed) else { return nil }
    return .image(alt: reference.alt, target: reference.target)
  }

  private static func isRule(_ trimmed: String) -> Bool {
    guard trimmed.count >= 3 else { return false }
    for character in ["-", "*", "_"] where trimmed.allSatisfy({ String($0) == character }) {
      return true
    }
    return false
  }

  private static func isTableSeparator(_ trimmed: String) -> Bool {
    guard trimmed.hasPrefix("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else {
      return false
    }
    let allowed = Set("|-: ")
    return trimmed.contains("-") && trimmed.allSatisfy { allowed.contains($0) }
  }

  private static func tableCells(_ row: String, columnCount: Int? = nil) -> [String] {
    var cells = row.split(separator: "|", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    if cells.first?.isEmpty == true { cells.removeFirst() }
    if cells.last?.isEmpty == true { cells.removeLast() }
    if let columnCount {
      while cells.count < columnCount { cells.append("") }
      cells = Array(cells.prefix(columnCount))
    }
    return cells
  }

  private static func listItem(_ line: String) -> MarkdownListItem? {
    let leadingWhitespace = line.prefix(while: { $0 == " " || $0 == "\t" })
    let indent = min(
      3,
      leadingWhitespace.reduce(0) { $0 + ($1 == "\t" ? 1 : 0) } + leadingWhitespace.filter {
        $0 == " "
      }.count / 2)
    let content = line.drop(while: { $0 == " " || $0 == "\t" })

    for bullet in ["- ", "* ", "+ "] where content.hasPrefix(bullet) {
      let text = content.dropFirst(bullet.count).trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { return nil }
      // Render task-list checkboxes as their own markers.
      if text.hasPrefix("[ ] ") {
        return MarkdownListItem(marker: "◻", indent: indent, text: String(text.dropFirst(4)))
      }
      if text.lowercased().hasPrefix("[x] ") {
        return MarkdownListItem(marker: "✓", indent: indent, text: String(text.dropFirst(4)))
      }
      return MarkdownListItem(marker: "•", indent: indent, text: text)
    }

    let digits = content.prefix(while: \.isNumber)
    if !digits.isEmpty, digits.count <= 3 {
      let afterDigits = content.dropFirst(digits.count)
      if afterDigits.hasPrefix(". ") || afterDigits.hasPrefix(") ") {
        let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return MarkdownListItem(marker: "\(digits).", indent: indent, text: text)
      }
    }
    return nil
  }
}
