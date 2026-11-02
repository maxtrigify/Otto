import AVFoundation
import Foundation
import Testing

@testable import OttoServices

@Suite("Telegram photos and videos", .serialized)
struct TelegramMediaTests {
  private func message(_ json: String) throws -> TelegramIncomingMessage {
    try JSONDecoder().decode(TelegramIncomingMessage.self, from: Data(json.utf8))
  }

  @Test("A photo uses its largest size the Bot API will serve")
  func photos() throws {
    let photo = try message(
      """
      {"message_id":3,"chat":{"id":123,"type":"private"},"from":{"id":123,"is_bot":false},
       "caption":"what is this?","media_group_id":"album-1",
       "photo":[{"file_id":"small","file_unique_id":"a","width":90,"height":60,"file_size":2000},
                {"file_id":"large","file_unique_id":"b","width":1280,"height":853,"file_size":190000},
                {"file_id":"huge","file_unique_id":"c","width":9000,"height":6000,"file_size":30000000}]}
      """)
    #expect(photo.media == TelegramMedia(kind: .image, fileID: "large", fileSize: 190_000))
    #expect(photo.media?.fileExtension == "jpg")
    #expect(photo.mediaGroupID == "album-1")
    #expect(photo.recording == nil)
  }

  @Test("Videos, round video notes, animations and image or video files count as media")
  func videosAndFiles() throws {
    func media(_ field: String, _ body: String) throws -> TelegramMedia? {
      try message(
        """
        {"message_id":4,"chat":{"id":123,"type":"private"},"from":{"id":123,"is_bot":false},
         "\(field)":\(body)}
        """
      ).media
    }
    let video = #"{"file_id":"v","file_unique_id":"x","duration":12,"file_size":900000}"#
    #expect(try media("video", video)?.kind == .video)
    #expect(try media("video", video)?.duration == 12)
    #expect(try media("video_note", video)?.kind == .video)
    #expect(try media("animation", video)?.kind == .video)
    let png = try media(
      "document", #"{"file_id":"d","file_unique_id":"y","mime_type":"image/png","file_size":10}"#)
    #expect(png?.kind == .image)
    #expect(png?.fileExtension == "png")
    #expect(
      try media(
        "document", #"{"file_id":"m","file_unique_id":"z","mime_type":"video/quicktime"}"#)?.kind
        == .video)
    #expect(
      try media(
        "document", #"{"file_id":"p","file_unique_id":"w","mime_type":"application/pdf"}"#)
        == nil)
    #expect(
      try media("document", #"{"file_id":"s","file_unique_id":"t","mime_type":"image/svg+xml"}"#)
        == nil)
    #expect(TelegramMedia(kind: .video, fileID: "big", fileSize: 25_000_000).isServable == false)
  }

  @Test("A /bot caption sends the media to that bot; any other caption is the message")
  func captionRouting() {
    #expect(
      TelegramMedia.route(caption: "/bot @Designer check spacing", botUsername: "ottobot")
        == ("@Designer", "check spacing"))
    #expect(
      TelegramMedia.route(caption: "/bot @Designer", botUsername: "ottobot") == ("@Designer", ""))
    #expect(
      TelegramMedia.route(caption: "/bot@ottobot @Designer", botUsername: "ottobot")
        == ("@Designer", ""))
    #expect(TelegramMedia.route(caption: "look here", botUsername: "ottobot") == (nil, "look here"))
    #expect(TelegramMedia.route(caption: "", botUsername: "ottobot") == (nil, ""))
    #expect(
      TelegramMedia.route(caption: "/bot@otherbot @Designer", botUsername: "ottobot").botHandle
        == nil)
  }

  @Test("The prompt carries the caption, each video's place and words, and every image to view")
  func prompt() {
    let text = TelegramMediaStore.prompt(
      caption: "  fix this layout  ", images: ["/w/a.jpg"],
      videos: [
        TelegramVideoNote(
          path: "/w/v.mp4", duration: 9, frames: ["/w/v-frame1.jpg", "/w/v-frame2.jpg"],
          transcript: "the button is cut off")
      ])
    #expect(text.hasPrefix("fix this layout\n\n[The video (9 s) is saved at /w/v.mp4."))
    #expect(text.contains("2 still frames from it are attached below."))
    #expect(text.contains("What is said in it: “the button is cut off”"))
    #expect(text.hasSuffix("- /w/a.jpg\n- /w/v-frame1.jpg\n- /w/v-frame2.jpg]"))
    #expect(text.contains("[The user attached 3 images. View each one"))

    let bare = TelegramMediaStore.prompt(caption: "", images: ["/w/a.jpg", "/w/b.jpg"], videos: [])
    #expect(bare.hasPrefix("(Sent from Telegram with no message: 2 photos.)"))
  }

  @Test("Downloaded media moves into Otto's workspace under a fresh name")
  func keep() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "tg-keep-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let download = root.appending(path: "media.bin")
    try Data([1, 2, 3]).write(to: download)
    let directory = TelegramMediaStore.directory(workspacePath: root.path)
    #expect(directory.path.hasSuffix(".otto/chat-attachments/telegram"))
    let kept = try TelegramMediaStore.keep(download, kind: .image, in: directory)
    #expect(kept.pathExtension == "jpg")
    #expect(kept.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
    #expect(!FileManager.default.fileExists(atPath: download.path))
    #expect(try Data(contentsOf: kept) == Data([1, 2, 3]))
  }

  @Test("A video gives stills an image-reading agent can open; a broken one gives none")
  func videoFrames() async throws {
    #expect(TelegramVideoFrames.positions(forSeconds: 2).count == 1)
    #expect(TelegramVideoFrames.positions(forSeconds: 40).count == 4)

    let root = FileManager.default.temporaryDirectory.appending(path: "tg-frames-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let video = root.appending(path: "clip.mp4")
    try await Self.writeVideo(to: video, seconds: 4)
    let frames = try await TelegramVideoFrames.extract(from: video)
    #expect(frames.count == 4)
    for frame in frames {
      let data = try Data(contentsOf: frame)
      #expect(data.starts(with: [0xFF, 0xD8]))
    }

    let broken = root.appending(path: "broken.mp4")
    try Data("not a video".utf8).write(to: broken)
    await #expect(throws: (any Error).self) {
      _ = try await TelegramVideoFrames.extract(from: broken)
    }
  }

  @Test("A file is fetched by its Bot API path and saved under the media name")
  func download() async throws {
    TelegramStubProtocol.handler = { request in
      let url = try #require(request.url?.absoluteString)
      if url.hasSuffix("/getFile") {
        return Data(#"{"ok":true,"result":{"file_path":"photos/file_9","file_size":4}}"#.utf8)
      }
      #expect(url.hasSuffix("/photos/file_9"))
      return Data([0xFF, 0xD8, 0xFF, 0xD9])
    }
    defer { TelegramStubProtocol.handler = nil }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TelegramStubProtocol.self]
    let transport = try TelegramBotTransport(
      token: "123456:abcdefghijklmnopqrstuvwxyz", session: URLSession(configuration: configuration))
    let file = try await transport.download(
      fileID: "f", maxBytes: TelegramMedia.maxBytes, named: "media", defaultExtension: "jpg")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(file.lastPathComponent == "media.jpg")
    #expect(try Data(contentsOf: file) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
  }

  /// A short silent H.264 clip, so frame extraction runs against a real video file.
  static func writeVideo(to url: URL, seconds: Int) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
      ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
      ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let fps: Int32 = 10
    for index in 0..<(seconds * Int(fps)) {
      while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
      var buffer: CVPixelBuffer?
      CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
      let pixels = try #require(buffer)
      CVPixelBufferLockBaseAddress(pixels, [])
      memset(
        CVPixelBufferGetBaseAddress(pixels), Int32(index * 6 % 255),
        CVPixelBufferGetDataSize(pixels))
      CVPixelBufferUnlockBaseAddress(pixels, [])
      adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: fps))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
  }
}

private final class TelegramStubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Data)?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = try #require(Self.handler)
      let data = try handler(request)
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
