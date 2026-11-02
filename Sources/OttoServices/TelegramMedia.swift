import Foundation
import OttoRuntime

#if canImport(AVFoundation)
  import AVFoundation
  import ImageIO
  import UniformTypeIdentifiers
#endif

/// A photo or video sent to Otto's Telegram bot. Only the Bot API handle is kept until the sender
/// is known to be paired; then the file is downloaded into the workspace's chat attachments.
public struct TelegramMedia: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case image, video
  }

  /// Telegram's Bot API serves files up to 20 MB.
  public static let maxBytes = 20_000_000
  /// An album holds at most ten photos and videos.
  static let maxAlbumItems = 10
  /// Videos up to this long also have their sound transcribed on the Mac.
  static let maxTranscribedVideoSeconds = 300

  public let kind: Kind
  public let fileID: String
  public let fileSize: Int?
  public let duration: Int?
  /// Used when Telegram's stored path has no extension.
  public let fileExtension: String

  public init(
    kind: Kind, fileID: String, fileSize: Int? = nil, duration: Int? = nil,
    fileExtension: String? = nil
  ) {
    self.kind = kind
    self.fileID = fileID
    self.fileSize = fileSize
    self.duration = duration
    self.fileExtension = fileExtension ?? (kind == .image ? "jpg" : "mp4")
  }

  public var isServable: Bool { (fileSize ?? 0) <= Self.maxBytes }

  /// Where a caption sends its media: `/bot @handle …` names one bot (the rest, possibly
  /// nothing, is the message); any other caption is the message to this chat's bot.
  public static func route(caption: String, botUsername: String?) -> (
    botHandle: String?, text: String
  ) {
    switch TelegramCommand.parse(caption, addressedTo: botUsername) {
    case .send(let handle, let text): return (handle, text)
    case .message(let text): return (nil, text)
    default:
      // `/bot @handle` alone: the media is the message.
      let words = caption.split(whereSeparator: \.isWhitespace)
      if words.count == 2,
        case .send(let handle, _)? = TelegramCommand.parse(
          "\(words[0]) \(words[1]) media", addressedTo: botUsername)
      {
        return (handle, "")
      }
      return (nil, caption)
    }
  }

  /// Image formats agents can open. Anything else sent as a file is not treated as a photo.
  static func imageExtension(forMIMEType type: String) -> String? {
    switch type {
    case "image/jpeg", "image/jpg": "jpg"
    case "image/png": "png"
    case "image/gif": "gif"
    case "image/webp": "webp"
    case "image/heic", "image/heif": "heic"
    case "image/tiff": "tiff"
    default: nil
    }
  }
}

/// What became of one video: where it is kept, the stills taken from it, and what was said.
struct TelegramVideoNote: Equatable {
  let path: String
  let duration: Int?
  let frames: [String]
  let transcript: String?
}

enum TelegramMediaStore {
  static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "gif", "webp", "heic", "tiff",
  ]

  /// Telegram media is kept beside Chat's own attachments in Otto's workspace, never in a
  /// project folder, so a bot opens it the same way as an image pasted into Chat.
  static func directory(workspacePath: String) -> URL {
    URL(fileURLWithPath: workspacePath, isDirectory: true)
      .appending(path: ".otto/chat-attachments/telegram", directoryHint: .isDirectory)
  }

  /// Moves a downloaded file into `directory` under a new random name and returns its new place.
  /// Images must carry an image extension; a video keeps its own extension.
  static func keep(_ file: URL, kind: TelegramMedia.Kind, in directory: URL) throws -> URL {
    var ext = file.pathExtension.lowercased()
    if kind == .image, !imageExtensions.contains(ext) { ext = "jpg" }
    if kind == .video, ext.isEmpty || ext.count > 5 { ext = "mp4" }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appending(path: "\(UUID().uuidString).\(ext)")
    try FileManager.default.moveItem(at: file, to: destination)
    return destination
  }

  /// The bot's prompt: the person's caption (or a plain note that media arrived), a line for each
  /// video, then Otto's usual attached-images note listing photos and video stills.
  static func prompt(caption: String, images: [String], videos: [TelegramVideoNote]) -> String {
    var lines: [String] = []
    let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    if caption.isEmpty {
      lines.append(
        "(Sent from Telegram with no message: \(summary(images: images.count, videos: videos.count)).)"
      )
    } else {
      lines.append(caption)
    }
    for (index, video) in videos.enumerated() {
      let name = videos.count == 1 ? "The video" : "Video \(index + 1)"
      let length = video.duration.map { " (\($0) s)" } ?? ""
      var line = "[\(name)\(length) is saved at \(video.path)."
      if !video.frames.isEmpty {
        line +=
          " \(video.frames.count) still frame\(video.frames.count == 1 ? "" : "s") from it \(video.frames.count == 1 ? "is" : "are") attached below."
      }
      if let transcript = video.transcript, !transcript.isEmpty {
        line += " What is said in it: “\(transcript)”"
      }
      lines.append(line + "]")
    }
    return ChatAttachmentPrompt.text(
      lines.joined(separator: "\n\n"), referencing: images + videos.flatMap(\.frames))
  }

  static func summary(images: Int, videos: Int) -> String {
    var parts: [String] = []
    if images > 0 { parts.append("\(images) photo\(images == 1 ? "" : "s")") }
    if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
    return parts.isEmpty ? "nothing" : parts.joined(separator: " and ")
  }
}

/// Stills from a video, so agents that read images but not video can see what it shows.
enum TelegramVideoFrames {
  enum FrameError: LocalizedError {
    case unreadable
    var errorDescription: String? { "The video could not be read." }
  }

  /// Positions, as fractions of the length, of the stills taken from a video.
  static func positions(forSeconds seconds: Double) -> [Double] {
    seconds < 3 ? [0.5] : [0.1, 0.37, 0.63, 0.9]
  }

  /// Writes JPEG stills from `video` next to it and returns their paths.
  static func extract(from video: URL, maxDimension: CGFloat = 1_280) async throws -> [URL] {
    #if canImport(AVFoundation)
      let asset = AVURLAsset(url: video)
      let duration = try await asset.load(.duration).seconds
      guard duration.isFinite, duration > 0 else { throw FrameError.unreadable }
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
      let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
      generator.requestedTimeToleranceBefore = tolerance
      generator.requestedTimeToleranceAfter = tolerance
      let base = video.deletingPathExtension()
      var frames: [URL] = []
      for (index, fraction) in positions(forSeconds: duration).enumerated() {
        try Task.checkCancellation()
        let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { continue }
        let url = URL(fileURLWithPath: "\(base.path)-frame\(index + 1).jpg")
        guard
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { continue }
        CGImageDestinationAddImage(
          destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        if CGImageDestinationFinalize(destination) { frames.append(url) }
      }
      guard !frames.isEmpty else { throw FrameError.unreadable }
      return frames
    #else
      throw FrameError.unreadable
    #endif
  }
}
