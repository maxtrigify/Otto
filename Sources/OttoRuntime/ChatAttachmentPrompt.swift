import Foundation

/// The note that hands attached images to an agent. Chat and Home write it under a prompt, and
/// the Telegram connector writes the same note, so any agent opens the files with its own image
/// or file tools and the chat transcript shows them as images rather than as this text.
public enum ChatAttachmentPrompt {
  public static func text(_ text: String, referencing imagePaths: [String]) -> String {
    guard !imagePaths.isEmpty else { return text }
    let listing = imagePaths.map { "- \($0)" }.joined(separator: "\n")
    return """
      \(text)

      [The user attached \(imagePaths.count) image\(imagePaths.count == 1 ? "" : "s"). View each \
      one with your image or file reading tool before answering:
      \(listing)]
      """
  }
}
