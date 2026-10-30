#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
import Foundation
import OttoModels

/// Authenticated encryption only. Callers must separately authorize the peer and consume
/// operation IDs before dispatch. HPKE by itself does not prevent replay or grant access.
public enum PrivatePhoneEnvelope {
  public enum Failure: Error { case invalidEnvelope }
  public enum Direction: String, Codable, Sendable { case phoneToHost, hostToPhone }

  public struct Context: Codable, Equatable, Sendable {
    public let installationID: UUID
    public let sessionID: UUID
    public let operationID: UUID
    public let direction: Direction
    public let expiresAt: Int64

    public init(
      installationID: UUID, sessionID: UUID, operationID: UUID,
      direction: Direction, expiresAt: Int64
    ) {
      self.installationID = installationID
      self.sessionID = sessionID
      self.operationID = operationID
      self.direction = direction
      self.expiresAt = expiresAt
    }

    /// Fixed field order and ASCII values keep Swift and WebCrypto byte-identical.
    var authenticatedData: Data {
      Data(
        [
          OttoLegacyWire.privateInputLabel, installationID.uuidString.lowercased(),
          sessionID.uuidString.lowercased(), operationID.uuidString.lowercased(),
          direction.rawValue, String(expiresAt),
        ].joined(separator: "\n").utf8)
    }
  }

  public struct Wire: Codable, Sendable {
    public let version: Int
    public let context: Context
    public let encapsulatedKey: Data
    public let ciphertext: Data
  }

  private static let info = Data(OttoLegacyWire.privateInputHPKEInfo.utf8)
  public static let maximumPlaintextBytes = 65_536

  public static func seal(
    _ plaintext: Data, context: Context,
    recipient: P256.KeyAgreement.PublicKey, sender: P256.KeyAgreement.PrivateKey
  ) throws -> Wire {
    guard plaintext.count <= maximumPlaintextBytes, context.expiresAt > 0,
      context.expiresAt <= 9_007_199_254_740_991
    else {
      throw Failure.invalidEnvelope
    }
    // One context per envelope; never share an asynchronous sender's nonce sequence.
    var hpke = try HPKE.Sender(
      recipientKey: recipient,
      ciphersuite: .P256_SHA256_AES_GCM_256, info: info, authenticatedBy: sender)
    return Wire(
      version: 1, context: context, encapsulatedKey: hpke.encapsulatedKey,
      ciphertext: try hpke.seal(plaintext, authenticating: context.authenticatedData))
  }

  public static func open(
    _ envelope: Wire, expected: Context,
    recipient: P256.KeyAgreement.PrivateKey, sender: P256.KeyAgreement.PublicKey,
    now: Date = .now
  ) throws -> Data {
    guard envelope.version == 1, envelope.context == expected,
      expected.expiresAt > 0, expected.expiresAt <= 9_007_199_254_740_991,
      Double(expected.expiresAt) > now.timeIntervalSince1970,
      envelope.encapsulatedKey.count == 65,
      (16...(maximumPlaintextBytes + 16)).contains(envelope.ciphertext.count)
    else { throw Failure.invalidEnvelope }
    do {
      var hpke = try HPKE.Recipient(
        privateKey: recipient,
        ciphersuite: .P256_SHA256_AES_GCM_256, info: info,
        encapsulatedKey: envelope.encapsulatedKey, authenticatedBy: sender)
      return try hpke.open(envelope.ciphertext, authenticating: expected.authenticatedData)
    } catch { throw Failure.invalidEnvelope }
  }
}
