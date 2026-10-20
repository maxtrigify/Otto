import AppKit
import SwiftUI

/// Otto's mark: the two-eyed character that names Otto's assistant in the browser.
struct OttoMark: View {
  var size: CGFloat = 16

  static let image: NSImage? = OttoAppResources.url(
    forResource: "otto", withExtension: "png", subdirectory: "Brand"
  ).flatMap(NSImage.init(contentsOf:))

  var body: some View {
    if let image = Self.image {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(width: size, height: size)
        // A faint light edge keeps the dark body readable on dark themes; it is invisible on
        // light ones.
        .shadow(color: .white.opacity(0.45), radius: 0.6)
        .shadow(color: .white.opacity(0.25), radius: 1.2)
        .accessibilityHidden(true)
    } else {
      Image(systemName: "sparkles").font(.system(size: size * 0.7, weight: .semibold))
    }
  }
}
