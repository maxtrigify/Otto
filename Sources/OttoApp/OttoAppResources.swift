import Foundation

private final class OttoAppResourceBundleMarker: NSObject {}

/// SwiftPM's generated `Bundle.module` looks for `Otto_OttoApp.bundle` next to the `.app`
/// (and at a machine-local build path). Packaged Otto keeps the bundle in
/// `Contents/Resources`, so touching `Bundle.module` after an install fatalErrors on
/// launch. Resolve the real bundle and fall back to `Bundle.main` instead of crashing.
enum OttoAppResources {
  static var bundle: Bundle { locatedBundle ?? .main }

  static func url(
    forResource name: String,
    withExtension ext: String?,
    subdirectory: String? = nil
  ) -> URL? {
    if let url = bundle.url(
      forResource: name, withExtension: ext, subdirectory: subdirectory)
    {
      return url
    }
    return Bundle.main.url(
      forResource: name, withExtension: ext, subdirectory: subdirectory)
  }

  /// Exposed for tests: the first candidate that exists on disk.
  static func locateBundle(
    main: Bundle = .main,
    executableURL: URL? = Bundle.main.executableURL,
    additionalBundles: [Bundle] = [],
    fileManager: FileManager = .default
  ) -> Bundle? {
    let name = "Otto_OttoApp.bundle"
    var candidates = [
      main.resourceURL?.appendingPathComponent(name),
      main.bundleURL.appendingPathComponent("Contents/Resources/\(name)"),
      main.bundleURL.appendingPathComponent(name),
      main.bundleURL.deletingLastPathComponent().appendingPathComponent(name),
    ].compactMap { $0 }
    // SwiftPM test runners can report Xcode's test host as `Bundle.main`. Walk the
    // test executable's nearby directories to find the target resource bundle.
    var executableDirectory = executableURL?.deletingLastPathComponent()
    for _ in 0..<4 {
      guard let currentDirectory = executableDirectory else { break }
      candidates.append(currentDirectory.appendingPathComponent(name))
      executableDirectory = currentDirectory.deletingLastPathComponent()
    }
    for loadedBundle in additionalBundles {
      candidates.append(loadedBundle.bundleURL.appendingPathComponent(name))
      candidates.append(
        loadedBundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name))
    }
    return candidates.first { fileManager.fileExists(atPath: $0.path) }.flatMap(Bundle.init(url:))
  }

  private static let locatedBundle = locateBundle(
    additionalBundles: [Bundle(for: OttoAppResourceBundleMarker.self)]
      + Bundle.allBundles + Bundle.allFrameworks)
}
