import Foundation

#if canImport(ScreenCaptureKit)
  import AVFoundation
  import ScreenCaptureKit
#endif

#if canImport(AppKit)
  import AppKit
#endif

public enum CanvasRecorderError: Error, LocalizedError {
  case alreadyRecording(path: String)
  case notRecording
  case windowUnavailable
  case permissionDenied
  case captureFailed(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyRecording(let path):
      "A recording is already running (\(path)). Stop it with recording.stop first."
    case .notRecording:
      "No recording is running."
    case .windowUnavailable:
      "The Otto window is not available to record."
    case .permissionDenied:
      "Otto needs Screen Recording permission. Grant it in System Settings → Privacy & Security → Screen Recording, then relaunch Otto and try again."
    case .captureFailed(let reason):
      "Recording failed: \(reason)"
    }
  }
}

public struct CanvasRecordingResult: Codable, Sendable, Equatable {
  public var path: String
  public var durationSeconds: Double

  public init(path: String, durationSeconds: Double) {
    self.path = path
    self.durationSeconds = durationSeconds
  }
}

public struct CanvasRecordingStatus: Codable, Sendable, Equatable {
  public var isRecording: Bool
  public var path: String?
  public var elapsedSeconds: Double?

  public init(isRecording: Bool, path: String? = nil, elapsedSeconds: Double? = nil) {
    self.isRecording = isRecording
    self.path = path
    self.elapsedSeconds = elapsedSeconds
  }
}

#if canImport(ScreenCaptureKit)
/// Records the Otto window into an .mp4 through ScreenCaptureKit. One recording at a time; the
/// capture follows the window (not the display), so other apps in front of Otto never appear in
/// the video. Frames stream through an AVAssetWriter so stopping produces a finished file
/// immediately.
public actor CanvasRecorder {
  private var stream: SCStream?
  private var sink: CaptureSink?
  private var writer: AVAssetWriter?
  private var startedAt: Date?
  private var outputURL: URL?
  private let stateContinuation: AsyncStream<Bool>.Continuation
  /// True while a recording runs; the UI observes this for its REC indicator.
  public nonisolated let stateChanges: AsyncStream<Bool>

  public init() {
    var continuation: AsyncStream<Bool>.Continuation!
    stateChanges = AsyncStream { continuation = $0 }
    stateContinuation = continuation
  }

  public func status() -> CanvasRecordingStatus {
    guard let startedAt, let outputURL else { return CanvasRecordingStatus(isRecording: false) }
    return CanvasRecordingStatus(
      isRecording: true,
      path: outputURL.path,
      elapsedSeconds: Date.now.timeIntervalSince(startedAt)
    )
  }

  /// Starts recording the Otto window into `directory`, returning the output path.
  public func start(directory: String) async throws -> String {
    if let outputURL, startedAt != nil {
      throw CanvasRecorderError.alreadyRecording(path: outputURL.path)
    }
    guard let target = await Self.appWindowTarget() else {
      throw CanvasRecorderError.windowUnavailable
    }

    // First use triggers the one-time system permission prompt; until it is granted (and Otto
    // relaunched) shareable-content lookup throws.
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: false)
    } catch {
      throw CanvasRecorderError.permissionDenied
    }
    guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
      throw CanvasRecorderError.windowUnavailable
    }

    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    try Foundation.FileManager.default.createDirectory(
      at: directoryURL, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let url = directoryURL.appending(path: "otto-recording-\(formatter.string(from: .now)).mp4")

    // Encoder dimensions must be even; the window size is in points, the capture in pixels.
    let pixelWidth = max(2, Int(window.frame.width * target.scale) & ~1)
    let pixelHeight = max(2, Int(window.frame.height * target.scale) & ~1)

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: pixelWidth,
        AVVideoHeightKey: pixelHeight,
      ])
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else {
      throw CanvasRecorderError.captureFailed("Video writer rejected its input")
    }
    writer.add(input)
    guard writer.startWriting() else {
      throw CanvasRecorderError.captureFailed(
        writer.error?.localizedDescription ?? "Video writer failed to start")
    }

    let configuration = SCStreamConfiguration()
    configuration.width = pixelWidth
    configuration.height = pixelHeight
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    configuration.showsCursor = true
    configuration.queueDepth = 6
    configuration.pixelFormat = kCVPixelFormatType_32BGRA

    let sink = CaptureSink(writer: writer, input: input)
    let stream = SCStream(
      filter: SCContentFilter(desktopIndependentWindow: window),
      configuration: configuration,
      delegate: sink
    )
    try stream.addStreamOutput(
      sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "otto.canvas-recorder"))
    do {
      try await stream.startCapture()
    } catch {
      throw CanvasRecorderError.permissionDenied
    }

    self.stream = stream
    self.sink = sink
    self.writer = writer
    self.outputURL = url
    self.startedAt = .now
    stateContinuation.yield(true)
    return url.path
  }

  /// Stops the active recording and returns the finished file.
  public func stop() async throws -> CanvasRecordingResult {
    guard let stream, let sink, let writer, let outputURL, let startedAt else {
      throw CanvasRecorderError.notRecording
    }
    self.stream = nil
    self.sink = nil
    self.writer = nil
    self.outputURL = nil
    self.startedAt = nil
    stateContinuation.yield(false)

    try? await stream.stopCapture()
    sink.finish()
    guard sink.appendedFrames > 0 else {
      // Without a started session finishWriting would error; cancel and clean up instead.
      if writer.status == .writing { writer.cancelWriting() }
      try? Foundation.FileManager.default.removeItem(at: outputURL)
      throw CanvasRecorderError.captureFailed(
        "No frames were captured — check the Screen Recording permission")
    }
    if writer.status == .writing {
      await writer.finishWriting()
    }
    if writer.status == .failed {
      throw CanvasRecorderError.captureFailed(
        writer.error?.localizedDescription ?? "Video writer failed")
    }
    return CanvasRecordingResult(
      path: outputURL.path,
      durationSeconds: Date.now.timeIntervalSince(startedAt)
    )
  }

  /// The Otto window to record: the key window when there is one, else the largest visible
  /// window. Resolved on the main actor because AppKit owns the window list.
  private static func appWindowTarget() async -> (windowID: CGWindowID, scale: CGFloat)? {
    #if canImport(AppKit)
      await MainActor.run {
        let candidates = NSApp.windows.filter {
          $0.isVisible && $0.frame.width > 200 && $0.sharingType != .none
            && $0.identifier?.rawValue.hasPrefix("otto-private-login") != true
        }
        let window =
          candidates.first { $0.isKeyWindow }
          ?? candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
          })
        guard let window else { return nil }
        return (CGWindowID(window.windowNumber), window.backingScaleFactor)
      }
    #else
      nil
    #endif
  }
}

/// Receives capture frames on a serial queue and appends them to the asset writer. The writer
/// session starts at the first complete frame's timestamp so the file begins at zero.
private final class CaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private var sessionStarted = false
  private var finished = false
  private let lock = NSLock()
  private(set) var appendedFrames = 0

  init(writer: AVAssetWriter, input: AVAssetWriterInput) {
    self.writer = writer
    self.input = input
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen, sampleBuffer.isValid else { return }
    // Idle windows deliver .idle/.blank status frames with no pixel data; only complete frames
    // may reach the encoder.
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let statusValue = attachments.first?[.status] as? Int,
      SCFrameStatus(rawValue: statusValue) == .complete
    else { return }

    lock.lock()
    defer { lock.unlock() }
    guard !finished, writer.status == .writing else { return }
    if !sessionStarted {
      sessionStarted = true
      writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
    guard input.isReadyForMoreMediaData else { return }
    if input.append(sampleBuffer) {
      appendedFrames += 1
    }
  }

  func finish() {
    let shouldMark: Bool = lock.withLock {
      let mark = !finished && sessionStarted && writer.status == .writing
      finished = true
      return mark
    }
    if shouldMark {
      input.markAsFinished()
    }
  }
}
#else
  /// Window recording uses ScreenCaptureKit; other platforms report it as unavailable.
  public actor CanvasRecorder {
    private let stateContinuation: AsyncStream<Bool>.Continuation
    public nonisolated let stateChanges: AsyncStream<Bool>

    public init() {
      var continuation: AsyncStream<Bool>.Continuation!
      stateChanges = AsyncStream { continuation = $0 }
      stateContinuation = continuation
    }

    public func status() -> CanvasRecordingStatus { CanvasRecordingStatus(isRecording: false) }

    public func start(directory: String) async throws -> String {
      throw CanvasRecorderError.captureFailed("Recording is not supported on this platform yet.")
    }

    public func stop() async throws -> CanvasRecordingResult {
      throw CanvasRecorderError.notRecording
    }
  }
#endif
