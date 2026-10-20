import Foundation

#if canImport(CoreGraphics)
  import CoreGraphics
#endif

public struct WorldPoint: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct WorldRect: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var center: WorldPoint {
    WorldPoint(x: x + width / 2, y: y + height / 2)
  }
}

public struct Viewport: Codable, Equatable, Sendable {
  public var centerX: Double
  public var centerY: Double
  public var scale: Double

  public init(centerX: Double = 0, centerY: Double = 0, scale: Double = 1) {
    self.centerX = centerX
    self.centerY = centerY
    self.scale = min(max(scale, 0.25), 2.5)
  }
}

/// Quantizes the expensive world-grid geometry while leaving translation continuous. Panning
/// therefore reuses one path, and small scale jitter remains in the same cache bucket.
public struct CanvasGridCacheKey: Hashable, Sendable {
  public let width: Int
  public let height: Int
  public let scaleBucket: Int

  public init(width: Double, height: Double, scale: Double) {
    self.width = max(1, Int(ceil(width)))
    self.height = max(1, Int(ceil(height)))
    self.scaleBucket = max(1, Int((scale * 64).rounded()))
  }

  public var quantizedScale: Double {
    Double(scaleBucket) / 64
  }

  public var spacing: Double {
    max(24, 44 * quantizedScale)
  }
}

public enum SceneTransform {
  public static func screenPoint(
    for world: WorldPoint,
    viewport: Viewport,
    canvasSize: CGSize
  ) -> CGPoint {
    CGPoint(
      x: canvasSize.width / 2 + (world.x - viewport.centerX) * viewport.scale,
      y: canvasSize.height / 2 + (world.y - viewport.centerY) * viewport.scale
    )
  }

  public static func worldPoint(
    for screen: CGPoint,
    viewport: Viewport,
    canvasSize: CGSize
  ) -> WorldPoint {
    WorldPoint(
      x: viewport.centerX + (screen.x - canvasSize.width / 2) / viewport.scale,
      y: viewport.centerY + (screen.y - canvasSize.height / 2) / viewport.scale
    )
  }
}
