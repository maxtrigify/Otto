import Foundation

/// A deck built like a website: each slide is a small piece of HTML that Otto's deck engine
/// lays out, animates and scales, with charts, counters, motion and 3D available as simple
/// classes. Plain title-and-bullet slides still work and are drawn from a template.
public struct Presentation: Codable, Equatable, Sendable {
  public enum Theme: String, Codable, Sendable, CaseIterable {
    case midnight, aurora, paper, ember, forest, mono

    public var displayName: String { rawValue.capitalized }

    public var tokens: DeckTokens {
      switch self {
      case .midnight:
        DeckTokens(
          background: "#0b0d17", background2: "#1a1433", surface: "rgba(255,255,255,0.06)",
          text: "#f5f3ff", muted: "#a5a3c2", accent: "#ff7a45", accent2: "#ffb86b")
      case .aurora:
        DeckTokens(
          background: "#060914", background2: "#0d2a3a", surface: "rgba(255,255,255,0.07)",
          text: "#eefcff", muted: "#9cc3cc", accent: "#3ee6c4", accent2: "#8b7bff")
      case .paper:
        DeckTokens(
          background: "#fbfaf7", background2: "#eef1f8", surface: "rgba(15,23,42,0.05)",
          text: "#0f172a", muted: "#5b6478", accent: "#2f5bff", accent2: "#7c4dff")
      case .ember:
        DeckTokens(
          background: "#1a0906", background2: "#4a1408", surface: "rgba(255,255,255,0.08)",
          text: "#fff4ec", muted: "#f2b8a0", accent: "#ff5a1f", accent2: "#ffd166")
      case .forest:
        DeckTokens(
          background: "#07140f", background2: "#103327", surface: "rgba(255,255,255,0.07)",
          text: "#ecfbf1", muted: "#a6cdb5", accent: "#5fe39a", accent2: "#d4f56b")
      case .mono:
        DeckTokens(
          background: "#0a0a0a", background2: "#1c1c1c", surface: "rgba(255,255,255,0.06)",
          text: "#fafafa", muted: "#a3a3a3", accent: "#fafafa", accent2: "#737373")
      }
    }
  }

  public var slides: [Slide]
  public var theme: Theme
  /// Brand colours and fonts that override the theme's, e.g. read from a company website.
  public var brand: DeckTokens?
  /// Earlier versions, newest last, so an agent's change can always be taken back.
  public var history: [PresentationVersion]?

  public init(
    slides: [Slide] = [Slide(title: "", layout: .title)], theme: Theme = .midnight,
    brand: DeckTokens? = nil
  ) {
    self.slides = slides
    self.theme = theme
    self.brand = brand
  }

  /// The colours and fonts in force: the brand where set, otherwise the theme.
  public var tokens: DeckTokens { theme.tokens.merged(with: brand) }

  public static let historyLimit = 20

  /// Saves the current slides and look as a version before a change.
  public mutating func snapshot(by author: String, at date: Date = .now) {
    var versions = history ?? []
    versions.append(
      PresentationVersion(
        slides: slides, theme: theme, brand: brand, author: author, createdAt: date))
    history = Array(versions.suffix(Self.historyLimit))
  }

  /// Goes back to an earlier version, keeping the current one in history so this is undoable.
  public mutating func revert(to versionID: UUID, by author: String) -> Bool {
    guard let version = history?.first(where: { $0.id == versionID }) else { return false }
    snapshot(by: author)
    slides = version.slides
    theme = version.theme
    brand = version.brand
    return true
  }

  /// Plain outline for agents: one block per slide, numbered from 1, with its HTML.
  public var outline: String {
    var parts = ["Theme: \(theme.rawValue)" + (brand?.brandName.map { " · brand \($0)" } ?? "")]
    parts += slides.enumerated().map { index, slide in
      var lines = ["Slide \(index + 1)" + (slide.html == nil ? " [\(slide.layout.rawValue)]" : "")]
      if let html = slide.html {
        lines.append(html)
      } else {
        lines[0] += ": \(slide.title)"
        lines += slide.visibleBullets.map { "- \($0)" }
      }
      if !slide.notes.isEmpty { lines.append("Notes: \(slide.notes)") }
      return lines.joined(separator: "\n")
    }
    return parts.joined(separator: "\n\n")
  }
}

/// Colours, fonts and brand marks for a deck. Any field left nil falls back to the theme.
public struct DeckTokens: Codable, Equatable, Sendable {
  public var background: String?
  public var background2: String?
  public var surface: String?
  public var text: String?
  public var muted: String?
  public var accent: String?
  public var accent2: String?
  public var fontDisplay: String?
  public var fontBody: String?
  /// A stylesheet that loads the brand's web fonts, e.g. a Google Fonts URL.
  public var fontURL: String?
  public var logoURL: String?
  public var brandName: String?

  public init(
    background: String? = nil, background2: String? = nil, surface: String? = nil,
    text: String? = nil, muted: String? = nil, accent: String? = nil, accent2: String? = nil,
    fontDisplay: String? = nil, fontBody: String? = nil, fontURL: String? = nil,
    logoURL: String? = nil, brandName: String? = nil
  ) {
    self.background = background
    self.background2 = background2
    self.surface = surface
    self.text = text
    self.muted = muted
    self.accent = accent
    self.accent2 = accent2
    self.fontDisplay = fontDisplay
    self.fontBody = fontBody
    self.fontURL = fontURL
    self.logoURL = logoURL
    self.brandName = brandName
  }

  public func merged(with override: DeckTokens?) -> DeckTokens {
    guard let override else { return self }
    return DeckTokens(
      background: override.background ?? background,
      background2: override.background2 ?? background2,
      surface: override.surface ?? surface, text: override.text ?? text,
      muted: override.muted ?? muted, accent: override.accent ?? accent,
      accent2: override.accent2 ?? accent2,
      fontDisplay: override.fontDisplay ?? fontDisplay,
      fontBody: override.fontBody ?? fontBody, fontURL: override.fontURL ?? fontURL,
      logoURL: override.logoURL ?? logoURL, brandName: override.brandName ?? brandName)
  }
}

public struct PresentationVersion: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var slides: [Slide]
  public var theme: Presentation.Theme
  public var brand: DeckTokens?
  public var author: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(), slides: [Slide], theme: Presentation.Theme, brand: DeckTokens?,
    author: String, createdAt: Date
  ) {
    self.id = id
    self.slides = slides
    self.theme = theme
    self.brand = brand
    self.author = author
    self.createdAt = createdAt
  }
}

public struct Slide: Codable, Equatable, Sendable, Identifiable {
  public enum Layout: String, Codable, Sendable, CaseIterable {
    /// A big centred title with an optional subtitle (the first bullet).
    case title
    /// A heading over bullet points.
    case bullets
    /// A section divider: one large line.
    case section
  }

  public var id: UUID
  public var title: String
  public var bullets: [String]
  public var notes: String
  public var layout: Layout
  /// The slide's own HTML, written with the deck components. When set it wins over
  /// title/bullets/layout, which remain for simple slides.
  public var html: String?

  public init(
    id: UUID = UUID(), title: String, bullets: [String] = [], notes: String = "",
    layout: Layout = .bullets, html: String? = nil
  ) {
    self.id = id
    self.title = title
    self.bullets = bullets
    self.notes = notes
    self.layout = layout
    self.html = html.map(DeckHTML.sanitize)
  }

  public var visibleBullets: [String] {
    bullets.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  /// The bullets as editable text, one per line.
  public var body: String {
    get { bullets.joined(separator: "\n") }
    set {
      // Blank lines are kept while typing; `visibleBullets` drops them when drawing.
      bullets = newValue.split(separator: "\n", omittingEmptySubsequences: false).map {
        String($0)
      }
    }
  }

  /// What the deck engine draws: the slide's HTML, or a template built from its words.
  public var renderedHTML: String {
    if let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return html }
    let title = DeckHTML.escape(self.title)
    switch layout {
    case .title:
      let subtitle =
        visibleBullets.first.map { "<p class=\"lead\" data-anim=\"up\">\(DeckHTML.escape($0))</p>" }
        ?? ""
      return """
        <div class="backdrop aurora"></div>
        <div class="center stack">
          <h1 class="huge gradient-text" data-anim="up">\(title.isEmpty ? "Title" : title)</h1>
          \(subtitle)
        </div>
        """
    case .section:
      return """
        <div class="backdrop spotlight"></div>
        <div class="stack" style="justify-content:center;height:100%">
          <div class="kicker" data-anim="fade">Section</div>
          <h1 class="huge" data-anim="up">\(title.isEmpty ? "Section" : title)</h1>
        </div>
        """
    case .bullets:
      let items = visibleBullets.map { "<li>\(DeckHTML.escape($0))</li>" }.joined()
      return """
        <div class="stack">
          <h2 data-anim="up">\(title.isEmpty ? "Heading" : title)</h2>
          <ul class="list stagger">\(items)</ul>
        </div>
        """
    }
  }
}

/// Keeps agent-written slide HTML to markup and styles: the deck engine supplies all
/// behaviour, so scripts, inline event handlers and javascript: links are removed.
public enum DeckHTML {
  public static func sanitize(_ html: String) -> String {
    var output = html
    output = output.replacing(/(?is)<script\b.*?<\/script\s*>/, with: "")
    output = output.replacing(/(?is)<script\b[^>]*>/, with: "")
    output = output.replacing(/(?is)<(iframe|object|embed|link|meta|base)\b[^>]*>/, with: "")
    output = output.replacing(/(?i)\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/, with: "")
    output = output.replacing(/(?i)javascript:/, with: "")
    return output
  }

  public static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
}
