import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

public struct SignedDocumentVerifier: Sendable {
  private let publicKeys: [String: Data]

  public init(publicKeys: [String: Data]) {
    self.publicKeys = publicKeys
  }

  public func verify<Value: Decodable & Sendable>(
    _ document: SignedDocument,
    as type: Value.Type = Value.self
  ) throws -> Value {
    guard let keyData = publicKeys[document.keyID] else {
      throw CommercialError.unknownSigningKey(document.keyID)
    }

    let publicKey: Curve25519.Signing.PublicKey
    do {
      publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    } catch {
      throw CommercialError.invalidDocument
    }

    guard publicKey.isValidSignature(document.signature, for: document.payload) else {
      throw CommercialError.invalidSignature
    }

    do {
      return try JSONDecoder.commercial.decode(Value.self, from: document.payload)
    } catch {
      throw CommercialError.invalidDocument
    }
  }
}

extension JSONDecoder {
  public static var commercial: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

extension JSONEncoder {
  public static var commercial: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}
