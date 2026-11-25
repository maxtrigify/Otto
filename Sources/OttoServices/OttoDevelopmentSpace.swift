import Foundation
import OttoModels

/// Otto Dev keeps its own spaces, sessions and workspace folder, so trying an unreleased build
/// never writes into the spaces the released Otto uses. Sign-ins and keys stay shared, so bots
/// still run in Otto Dev without signing in again.
public enum OttoDevelopmentSpace {
  /// Set this default to true (or `OTTO_DEV_REAL_SPACES=1`) to open the released app's spaces
  /// from Otto Dev, as it did before.
  public static let realSpacesDefaultsKey = "OttoDevUsesRealSpaces"
  public static let realSpacesEnvironmentKey = "OTTO_DEV_REAL_SPACES"
  public static let supportFolder = "Otto Dev"
  public static let workspaceFolder = "Otto Dev Workspace"

  public static func isSeparate(
    bundleIdentifier: String?, environment: [String: String], realSpacesDefault: Bool
  ) -> Bool {
    guard bundleIdentifier == OttoNames.developmentBundleIdentifier else { return false }
    if realSpacesDefault { return false }
    if let value = environment[realSpacesEnvironmentKey], ["1", "true", "yes"].contains(value) {
      return false
    }
    return true
  }

  /// Where Otto Dev keeps its list of spaces and their sessions databases.
  public static func applicationSupport(in base: URL) -> URL {
    base.appending(path: supportFolder, directoryHint: .isDirectory)
  }

  /// The folder of Otto Dev's first space.
  public static func workspace(in documents: URL) -> URL {
    documents.appending(path: workspaceFolder, directoryHint: .isDirectory)
  }
}
