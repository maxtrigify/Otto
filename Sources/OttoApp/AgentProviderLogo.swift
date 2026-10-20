import AppKit
import OttoModels
import SwiftUI

/// A provider identity mark, kept separate from agent status so colour can remain an honest state
/// signal elsewhere in the card. Claude, Codex, Hermes, and Kimi use bundled artwork; other
/// providers fall back to a compact system glyph.
struct AgentProviderLogo: View {
  let provider: AgentProvider?
  let size: CGFloat
  let color: Color

  var body: some View {
    Group {
      if let image = ProviderLogoAssets.image(for: provider) {
        Image(nsImage: image)
          .resizable()
          .renderingMode(provider == .hermes ? .original : .template)
          .scaledToFit()
      } else {
        Image(systemName: fallbackSymbol)
          .resizable()
          .scaledToFit()
      }
    }
    .foregroundStyle(resolvedColor)
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private var resolvedColor: Color {
    guard provider == .claudeCode else { return color }
    return Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
  }

  private var fallbackSymbol: String {
    switch provider {
    case .hermes: "wing"
    case .cursor: "cursorarrow.rays"
    case .kimi: "moon.stars"
    case .openCode: "chevron.right.square"
    case .grok: "bolt.fill"
    case .shell, nil: "terminal"
    case .claudeCode: "sparkles"
    case .codex, .openAI: "chevron.left.forwardslash.chevron.right"
    }
  }
}

extension OttoNode {
  var declaredAgentProvider: AgentProvider? {
    if let provider = agentDefinition?.provider { return provider }
    guard case .agent(let provider) = content else { return nil }
    return provider
  }
}

@MainActor
private enum ProviderLogoAssets {
  static let claude = load("claude")
  static let codex = load("codex")
  static let hermes = load("hermes", extension: "png", isTemplate: false)
  static let cursor = load("cursor")
  static let kimi = load("kimi")
  static let openCode = load("opencode")
  static let grok = load("grok")

  static func image(for provider: AgentProvider?) -> NSImage? {
    switch provider {
    case .claudeCode: claude
    case .codex, .openAI: codex
    case .hermes: hermes
    case .cursor: cursor
    case .kimi: kimi
    case .openCode: openCode
    case .grok: grok
    case .shell, nil: nil
    }
  }

  private static func load(
    _ name: String,
    extension fileExtension: String = "svg",
    isTemplate: Bool = true
  ) -> NSImage? {
    guard
      let url = OttoAppResources.url(
        forResource: name,
        withExtension: fileExtension,
        subdirectory: "ProviderLogos"
      ),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.isTemplate = isTemplate
    return image
  }
}
