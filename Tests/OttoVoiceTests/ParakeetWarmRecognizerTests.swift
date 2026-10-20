import Foundation
import Testing

@testable import OttoVoice

@Suite("Warm Parakeet recognizer")
struct ParakeetWarmRecognizerTests {
  @Test("Wire payload carries little-endian header and float samples")
  func payload() throws {
    let payload = ParakeetWarmRecognizer.makePayload(
      samples: [0.5, -0.25],
      sampleRate: 16_000
    )

    #expect(payload.count == 16)
    let values = payload.withUnsafeBytes { raw in
      (
        Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: Int32.self)),
        Int32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: Int32.self)),
        Float(
          bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))),
        Float(
          bitPattern: UInt32(
            littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
      )
    }
    #expect(values.0 == 16_000)
    #expect(values.1 == 8)
    #expect(values.2 == 0.5)
    #expect(values.3 == -0.25)
  }
}
