import Foundation

/// Team-created documents are relative to Otto's document workspace, rather than the
/// orchestrator agent's checkout. Leave web and application links to their normal handlers.
func chatDocumentLinkPath(_ url: URL, workspaceRoot: String) -> String? {
  guard url.isFileURL || url.scheme == nil else { return nil }
  let rawPath = url.isFileURL ? url.path : url.relativePath
  let reference = ArtifactReference.parse(rawPath)
  guard !reference.path.isEmpty else { return nil }
  return URL(
    fileURLWithPath: reference.path,
    relativeTo: URL(fileURLWithPath: workspaceRoot, isDirectory: true)
  ).standardizedFileURL.path
}
