import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

public struct CommercialDocumentSigner: Sendable {
  public let keyID: String
  public let publicKey: Data
  private let privateKey: Curve25519.Signing.PrivateKey

  public init(keyID: String, privateKey: Data) throws {
    self.keyID = keyID
    self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
    self.publicKey = self.privateKey.publicKey.rawRepresentation
  }

  public init(keyID: String) {
    self.keyID = keyID
    self.privateKey = Curve25519.Signing.PrivateKey()
    self.publicKey = self.privateKey.publicKey.rawRepresentation
  }

  public func sign<Value: Encodable & Sendable>(_ value: Value) throws -> SignedDocument {
    let payload = try JSONEncoder.commercial.encode(value)
    return try SignedDocument(
      payload: payload,
      signature: privateKey.signature(for: payload),
      keyID: keyID
    )
  }
}
