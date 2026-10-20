import Foundation
import Testing

@testable import OttoVoice

@Suite("Parakeet speech transcriber")
struct ParakeetSpeechTranscriberTests {
  @Test("Runtime configuration reports missing components")
  func validation() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-parakeet-validation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = ParakeetRuntimeConfiguration(
      executableURL: root.appending(path: "bin/sherpa-onnx-offline"),
      libraryDirectory: root.appending(path: "lib"),
      modelDirectory: root.appending(path: "model")
    )
    #expect(configuration.validationError()?.contains("sherpa-onnx-offline") == true)
  }

  @Test("Contextual decoding is explicit and includes every sherpa argument")
  func contextualDecodingArguments() {
    let root = URL(filePath: "/tmp/parakeet-context-test")
    let configuration = ParakeetRuntimeConfiguration(
      executableURL: root.appending(path: "bin/sherpa-onnx-offline"),
      libraryDirectory: root.appending(path: "lib"),
      modelDirectory: root.appending(path: "model"),
      decodingMethod: .modifiedBeamSearch,
      maxActivePaths: 6,
      hotwordsFileURL: root.appending(path: "hotwords.txt"),
      hotwordsScore: 0.75,
      bpeVocabURL: root.appending(path: "bpe.vocab")
    )

    #expect(configuration.recognitionArguments.contains("--decoding-method=modified_beam_search"))
    #expect(configuration.recognitionArguments.contains("--max-active-paths=6"))
    #expect(configuration.recognitionArguments.contains("--hotwords-score=0.75"))
    #expect(configuration.recognitionArguments.contains("--modeling-unit=bpe"))
    #expect(
      configuration.recognitionArguments.contains(
        "--hotwords-file=/tmp/parakeet-context-test/hotwords.txt"))
    #expect(
      configuration.recognitionArguments.contains(
        "--bpe-vocab=/tmp/parakeet-context-test/bpe.vocab"))
  }

  @Test("Process runner parses the final sherpa JSON result")
  func runnerResult() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-parakeet-runner-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appending(path: "bin")
    let libraries = root.appending(path: "lib")
    let model = root.appending(path: "model")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: libraries, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    for name in ["libsherpa-onnx-c-api.dylib", "libonnxruntime.dylib"] {
      FileManager.default.createFile(
        atPath: libraries.appending(path: name).path,
        contents: Data()
      )
    }
    for name in ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"] {
      FileManager.default.createFile(
        atPath: model.appending(path: name).path,
        contents: Data()
      )
    }
    let executable = bin.appending(path: "sherpa-onnx-offline")
    let script = """
      #!/bin/sh
      echo 'Started'
      echo '{"text":"Otto go to sleep.","timestamps":[0.0],"durations":[0.2]}'
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )
    let audio = root.appending(path: "command.wav")
    FileManager.default.createFile(atPath: audio.path, contents: Data())

    let result = try await ParakeetOfflineRunner(
      configuration: ParakeetRuntimeConfiguration(
        executableURL: executable,
        libraryDirectory: libraries,
        modelDirectory: model
      )
    ).transcribe(audio)

    #expect(result.text == "Otto go to sleep.")
    #expect(result.timestamps == [0])
    #expect(result.durations == [0.2])
  }

  @Test("Batch runner keeps output order while paying model startup once")
  func batchRunner() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-parakeet-batch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appending(path: "bin")
    let libraries = root.appending(path: "lib")
    let model = root.appending(path: "model")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: libraries, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    for name in ["libsherpa-onnx-c-api.dylib", "libonnxruntime.dylib"] {
      FileManager.default.createFile(atPath: libraries.appending(path: name).path, contents: Data())
    }
    for name in ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"] {
      FileManager.default.createFile(atPath: model.appending(path: name).path, contents: Data())
    }
    let executable = bin.appending(path: "sherpa-onnx-offline")
    let script = """
      #!/bin/sh
      echo '{"text":"first","timestamps":[],"durations":[]}'
      echo '{"text":"second","timestamps":[],"durations":[]}'
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let configuration = ParakeetRuntimeConfiguration(
      executableURL: executable,
      libraryDirectory: libraries,
      modelDirectory: model
    )

    let results = try await ParakeetOfflineRunner(configuration: configuration).transcribe([
      root.appending(path: "first.wav"), root.appending(path: "second.wav"),
    ])

    #expect(results.map(\.text) == ["first", "second"])
  }
}
