import Foundation

/// Deterministic, bounded spring layout. Runs once per filtered graph, away from the UI thread;
/// the view owns pan, zoom and dragged positions, so exploration never writes to memory.
public enum MemoryGraphLayout {
  public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
      self.x = x
      self.y = y
    }
  }

  public static func positions(for graph: MemoryGraph) -> [String: Point] {
    let nodes = graph.nodes
    guard !nodes.isEmpty else { return [:] }
    let indices = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
    let springs = graph.edges.compactMap { edge -> (Int, Int, Double)? in
      guard let from = indices[edge.from], let to = indices[edge.to] else { return nil }
      return (from, to, edge.relationship == .belongsTo ? 125 : 78)
    }
    let n = nodes.count
    var x = [Double](repeating: 0, count: n)
    var y = x
    for i in nodes.indices {
      let angle = Double(i) * 2.399963229728653
      let radius = 28 * sqrt(Double(i) + 1)
      x[i] = cos(angle) * radius
      y[i] = sin(angle) * radius
    }
    for iteration in 0..<150 {
      var dx = [Double](repeating: 0, count: n)
      var dy = dx
      for i in nodes.indices {
        for j in (i + 1)..<n {
          let vx = x[i] - x[j]
          let vy = y[i] - y[j]
          let distanceSquared = max(36, vx * vx + vy * vy)
          let force = 2_100 / distanceSquared
          dx[i] += vx * force
          dy[i] += vy * force
          dx[j] -= vx * force
          dy[j] -= vy * force
        }
      }
      for (a, b, rest) in springs {
        let vx = x[b] - x[a]
        let vy = y[b] - y[a]
        let distance = max(1, hypot(vx, vy))
        let force = (distance - rest) * 0.025 / distance
        dx[a] += vx * force
        dy[a] += vy * force
        dx[b] -= vx * force
        dy[b] -= vy * force
      }
      let step = 10 * (1 - Double(iteration) / 160)
      for i in nodes.indices {
        dx[i] -= x[i] * 0.002
        dy[i] -= y[i] * 0.002
        let length = max(1, hypot(dx[i], dy[i]))
        x[i] += dx[i] / length * min(length, step)
        y[i] += dy[i] / length * min(length, step)
      }
    }
    return Dictionary(
      uniqueKeysWithValues: nodes.indices.map {
        (nodes[$0].id, Point(x: x[$0], y: y[$0]))
      })
  }
}
