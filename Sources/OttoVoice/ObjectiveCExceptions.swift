import Foundation
import OttoObjCSupport

/// Bridges Objective-C exceptions into Swift errors.
///
/// AVFoundation's audio engine reports invalid graphs (no output device, an unsupported
/// hardware format, a player used while disconnected) by raising `NSException`, which Swift
/// cannot catch and which therefore terminates Otto. Audio setup runs through this guard so a
/// broken audio configuration degrades to a voice error instead of a crash at launch.
public enum ObjectiveCExceptions {
  public struct Raised: Error, LocalizedError, Sendable {
    public let name: String
    public let reason: String

    public var errorDescription: String? { reason }
  }

  public static func catching<T>(_ body: () throws -> T) throws -> T {
    var result: Result<T, any Error>?
    var raised: NSError?
    OttoRunCatchingObjCException({ result = Result { try body() } }, &raised)
    if let raised {
      throw Raised(
        name: (raised.userInfo[OttoObjCExceptionNameKey] as? String) ?? raised.domain,
        reason: raised.localizedDescription
      )
    }
    guard let result else {
      throw Raised(name: OttoObjCExceptionErrorDomain, reason: "The operation did not complete.")
    }
    return try result.get()
  }
}
