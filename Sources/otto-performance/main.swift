import Combine
import Darwin
import Foundation
import OttoCore
import OttoModels

private struct Measurement: Codable {
  let nodeCount: Int
  let minimized: Bool
  let samples: Int
  let cameraUpdatesPerSample: Int
  let medianMilliseconds: Double
  let worstMilliseconds: Double
  let workspacePublicationsDuringLiveUpdates: Int
  let legacyMedianMilliseconds: Double
  let legacyWorstMilliseconds: Double
  let legacyWorkspacePublications: Int
  let medianSpeedup: Double
}

private struct Report: Codable {
  let generatedAt: Date
  let hardware: String
  let iterations: Int
  let residentBytes: UInt64
  let measurements: [Measurement]
}

@main
@MainActor
private enum OttoPerformanceHarness {
  static func main() throws {
    let iterations = max(
      1, Int(OttoEnvironment.value("BENCHMARK_ITERATIONS") ?? "20") ?? 20)
    var measurements: [Measurement] = []
    for nodeCount in [1, 10, 40] {
      measurements.append(measure(nodeCount: nodeCount, minimized: false, iterations: iterations))
      measurements.append(measure(nodeCount: nodeCount, minimized: true, iterations: iterations))
    }
    let report = Report(
      generatedAt: .now,
      hardware: hardwareDescription(),
      iterations: iterations,
      residentBytes: residentMemoryBytes(),
      measurements: measurements
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(report))
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  private static func measure(
    nodeCount: Int,
    minimized: Bool,
    iterations: Int
  ) -> Measurement {
    let nodes = (0..<nodeCount).map { index in
      OttoNode(
        kind: .agent,
        displayName: "Worker \(index + 1)",
        subtitle: "BENCHMARK · LOCAL",
        frame: WorldRect(
          x: Double((index % 5) * 410),
          y: Double((index / 5) * 270),
          width: 380,
          height: 240
        ),
        zIndex: index,
        status: .working,
        detail: "Running benchmark fixture",
        content: .agent(provider: index.isMultiple(of: 2) ? .codex : .claudeCode),
        isMinimized: minimized
      )
    }
    let canvas = OttoCanvas(name: "Performance", nodes: nodes)
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)
    )
    let camera = CanvasCameraModel(canvasID: canvas.id, viewport: canvas.viewport)
    var workspacePublications = 0
    let observation = store.objectWillChange.sink { workspacePublications += 1 }
    var durations: [Double] = []
    var legacyDurations: [Double] = []
    let updates = 360

    for iteration in 0..<iterations {
      let duration = ContinuousClock().measure {
        for update in 1...240 {
          camera.updatePan(x: Double(update + iteration), y: Double(-update))
        }
        camera.cancelInteraction()
        for update in 1...120 {
          camera.updateZoom(magnification: 1 + Double(update) / 10_000)
        }
        camera.cancelInteraction()
      }
      durations.append(milliseconds(duration))
    }
    let liveWorkspacePublications = workspacePublications
    for iteration in 0..<iterations {
      let duration = ContinuousClock().measure {
        for update in 1...updates {
          store.dispatch(
            .setViewport(
              Viewport(
                centerX: Double(update + iteration),
                centerY: Double(-update),
                scale: 1 + Double(update % 20) / 1_000
              )))
        }
      }
      legacyDurations.append(milliseconds(duration))
    }
    withExtendedLifetime(observation) {}
    durations.sort()
    legacyDurations.sort()
    let median = durations[durations.count / 2]
    let legacyMedian = legacyDurations[legacyDurations.count / 2]
    return Measurement(
      nodeCount: nodeCount,
      minimized: minimized,
      samples: iterations,
      cameraUpdatesPerSample: updates,
      medianMilliseconds: median,
      worstMilliseconds: durations.last ?? 0,
      workspacePublicationsDuringLiveUpdates: liveWorkspacePublications,
      legacyMedianMilliseconds: legacyMedian,
      legacyWorstMilliseconds: legacyDurations.last ?? 0,
      legacyWorkspacePublications: workspacePublications - liveWorkspacePublications,
      medianSpeedup: legacyMedian / max(0.000_001, median)
    )
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }

  private static func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
  }

  private static func hardwareDescription() -> String {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0 else {
      return "unknown"
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else {
      return "unknown"
    }
    return String(
      decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
  }
}
