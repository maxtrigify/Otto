@preconcurrency import AVFoundation
import Darwin
import Foundation

/// Keeps the official sherpa recognizer loaded between utterances. The worker is a separate local
/// process because the downloaded dynamic libraries cannot be loaded into a hardened Otto process.
/// Otto connects through loopback on a randomly selected high port; microphone audio never leaves
/// the Mac.
public actor ParakeetWarmRecognizer {
  private let configuration: ParakeetRuntimeConfiguration
  private var process: Process?
  private var socket: URLSessionWebSocketTask?
  private var session: URLSession?
  private var port: Int?
  private var logURL: URL?
  private var preparationTask: Task<Void, Error>?

  public init(configuration: ParakeetRuntimeConfiguration) {
    self.configuration = configuration
  }

  deinit {
    socket?.cancel(with: .goingAway, reason: nil)
    process?.terminate()
    session?.invalidateAndCancel()
    if let logURL { try? FileManager.default.removeItem(at: logURL) }
  }

  public func prepare() async throws {
    if process?.isRunning == true, socket != nil { return }
    if let preparationTask {
      try await preparationTask.value
      return
    }
    let task = Task { [weak self] in
      guard let self else { return }
      try await self.prepareFresh()
    }
    preparationTask = task
    do {
      try await task.value
      preparationTask = nil
    } catch {
      preparationTask = nil
      throw error
    }
  }

  private func prepareFresh() async throws {
    await shutdownWorker()
    if let error = configuration.warmValidationError() {
      throw ParakeetRuntimeError.invalidInstallation(error)
    }

    var lastError: Error?
    for _ in 0..<5 {
      try Task.checkCancellation()
      do {
        try await launch(port: Int.random(in: 49_152...59_999))
        return
      } catch {
        lastError = error
        await shutdownWorker()
      }
    }
    throw lastError ?? ParakeetRuntimeError.warmWorker("Could not start the local recognizer")
  }

  public func transcribe(_ audioURL: URL) async throws -> ParakeetTranscription {
    try await prepare()
    guard let socket else {
      throw ParakeetRuntimeError.warmWorker("The local recognizer did not open a connection")
    }
    let audio = try Self.readAudio(audioURL)
    let payload = Self.makePayload(samples: audio.samples, sampleRate: audio.sampleRate)
    do {
      for start in stride(from: 0, to: payload.count, by: 10_240) {
        let end = min(start + 10_240, payload.count)
        try await socket.send(.data(payload.subdata(in: start..<end)))
      }
      let response = try await socket.receive()
      let data: Data
      switch response {
      case .string(let text): data = Data(text.utf8)
      case .data(let value): data = value
      @unknown default:
        throw ParakeetRuntimeError.invalidResult("Unknown WebSocket response")
      }
      return try JSONDecoder().decode(ParakeetTranscription.self, from: data)
    } catch {
      await shutdown()
      if error is DecodingError {
        throw ParakeetRuntimeError.invalidResult(error.localizedDescription)
      }
      throw ParakeetRuntimeError.warmWorker(error.localizedDescription)
    }
  }

  public func shutdown() async {
    preparationTask?.cancel()
    preparationTask = nil
    await shutdownWorker()
  }

  private func shutdownWorker() async {
    if let socket {
      try? await socket.send(.string("Done"))
      socket.cancel(with: .goingAway, reason: nil)
    }
    self.socket = nil
    session?.invalidateAndCancel()
    session = nil
    if let process, process.isRunning {
      process.terminate()
      for _ in 0..<20 where process.isRunning {
        try? await Task.sleep(for: .milliseconds(25))
      }
      if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
    process = nil
    port = nil
    if let logURL { try? FileManager.default.removeItem(at: logURL) }
    logURL = nil
  }

  private func launch(port: Int) async throws {
    let workerURL = configuration.executableURL.deletingLastPathComponent()
      .appending(path: "sherpa-onnx-offline-websocket-server")
    guard FileManager.default.isExecutableFile(atPath: workerURL.path) else {
      throw ParakeetRuntimeError.invalidInstallation(
        "Missing Parakeet component: sherpa-onnx-offline-websocket-server"
      )
    }
    let model = configuration.modelDirectory
    let logURL = FileManager.default.temporaryDirectory
      .appending(path: "otto-parakeet-worker-\(UUID().uuidString).log")
    let process = Process()
    process.executableURL = workerURL
    process.arguments =
      [
        "--port=\(port)",
        "--tokens=\(model.appending(path: "tokens.txt").path)",
        "--encoder=\(model.appending(path: "encoder.int8.onnx").path)",
        "--decoder=\(model.appending(path: "decoder.int8.onnx").path)",
        "--joiner=\(model.appending(path: "joiner.int8.onnx").path)",
        "--model-type=nemo_transducer",
        "--num-threads=\(configuration.threadCount)",
        "--num-work-threads=1",
        "--num-io-threads=1",
        "--max-batch-size=1",
        "--log-file=\(logURL.path)",
        "--print-args=false",
      ] + configuration.recognitionArguments
    var environment = ProcessInfo.processInfo.environment
    environment["DYLD_LIBRARY_PATH"] = configuration.libraryDirectory.path
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    self.process = process
    self.port = port
    self.logURL = logURL

    try await waitUntilReady(process: process, port: port, logURL: logURL)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 300
    configuration.timeoutIntervalForResource = 300
    let session = URLSession(configuration: configuration)
    let socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
    socket.resume()
    self.session = session
    self.socket = socket
  }

  private func waitUntilReady(process: Process, port: Int, logURL: URL) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
      try Task.checkCancellation()
      guard process.isRunning else {
        let detail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "Worker exited"
        throw ParakeetRuntimeError.warmWorker(detail)
      }
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
      request.timeoutInterval = 0.25
      do {
        let (_, response) = try await URLSession.shared.data(for: request)
        if response is HTTPURLResponse { return }
      } catch {}
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ParakeetRuntimeError.warmWorker("Timed out while loading the local Parakeet model")
  }

  struct AudioSamples: Sendable, Equatable {
    var samples: [Float]
    var sampleRate: Int32
  }

  static func readAudio(_ url: URL) throws -> AudioSamples {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(file.length)
      )
    else {
      throw ParakeetRuntimeError.invalidResult("Could not allocate an audio buffer")
    }
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
      throw ParakeetRuntimeError.invalidResult("Parakeet received an empty audio file")
    }
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(format.channelCount)
    var samples = [Float](repeating: 0, count: frameCount)
    for frame in 0..<frameCount {
      var value: Float = 0
      for channel in 0..<channelCount { value += channels[channel][frame] }
      samples[frame] = value / Float(channelCount)
    }
    return AudioSamples(
      samples: samples,
      sampleRate: Int32(format.sampleRate.rounded())
    )
  }

  static func makePayload(samples: [Float], sampleRate: Int32) -> Data {
    var rate = sampleRate.littleEndian
    var byteCount = Int32(samples.count * MemoryLayout<Float>.size).littleEndian
    var payload = Data(bytes: &rate, count: MemoryLayout<Int32>.size)
    payload.append(Data(bytes: &byteCount, count: MemoryLayout<Int32>.size))
    for sample in samples {
      var bits = sample.bitPattern.littleEndian
      payload.append(Data(bytes: &bits, count: MemoryLayout<UInt32>.size))
    }
    return payload
  }
}
