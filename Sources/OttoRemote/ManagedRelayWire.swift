import Foundation
import OttoCommercial
import OttoRPCContracts

/// Wire envelopes exchanged between a Mac host and the managed relay.
public struct ManagedRelayWireRequest: Codable, Equatable, Sendable {
  public var id: UUID
  public var ticket: SignedDocument
  public var request: OttoRPCRequest

  public init(id: UUID = UUID(), ticket: SignedDocument, request: OttoRPCRequest) {
    self.id = id
    self.ticket = ticket
    self.request = request
  }
}

public struct ManagedRelayWireResponse: Codable, Equatable, Sendable {
  public var id: UUID
  public var response: OttoRPCResponse

  public init(id: UUID, response: OttoRPCResponse) {
    self.id = id
    self.response = response
  }
}
