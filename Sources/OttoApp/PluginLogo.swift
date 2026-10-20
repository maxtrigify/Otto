import AppKit
import OttoRuntime
import SwiftUI

/// Bundled brand artwork for a harness plugin. Unknown tools fall back to a letter tile.
@MainActor
enum PluginLogoArtwork {
  case image(NSImage, PluginLogoKind)
  case mark(String)

  static func artwork(for plugin: HarnessPlugin) -> PluginLogoArtwork {
    if let spec = PluginBrand.logo(for: plugin.name),
      let image = PluginLogoAssets.image(named: spec.asset, kind: spec.kind)
    {
      return .image(image, spec.kind)
    }
    return .mark(plugin.mark)
  }
}

@MainActor
enum PluginLogoAssets {
  static func image(named name: String, kind: PluginLogoKind) -> NSImage? {
    cache[name] ?? load(name, isTemplate: kind == .template)
  }

  private static var cache: [String: NSImage] = [:]

  private static func load(_ name: String, isTemplate: Bool) -> NSImage? {
    guard
      let url = OttoAppResources.url(
        forResource: name, withExtension: "svg", subdirectory: "PluginLogos"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    image.isTemplate = isTemplate
    cache[name] = image
    return image
  }
}
