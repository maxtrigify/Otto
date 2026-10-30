#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
import Foundation
import OttoHostRuntime
import OttoRPCContracts

struct CompletedMobileAttachmentUpload: Sendable {
  var uploadID: UUID
  var threadID: UUID
  var displayName: String
  var mimeType: String
  var byteCount: Int64
  var fileURL: URL
}

actor MobileAttachmentTransferStore {
  static let maximumBytes: Int64 = 20 * 1_048_576
  static let chunkSize = 256 * 1_024
  static let lifetime: TimeInterval = 15 * 60

  private struct Upload {
    var id: UUID
    var threadID: UUID
    var displayName: String
    var mimeType: String
    var byteCount: Int64
    var sha256: String
    var receivedBytes: Int64
    var expiresAt: Date
    var fileURL: URL
  }

  private let directory: URL
  private var uploads: [UUID: Upload] = [:]

  init(directory: URL) {
    self.directory = directory
  }

  func prepare(
    _ input: AttachmentPrepareUploadInput,
    now: Date = .now
  ) throws -> AttachmentPrepareUploadOutput {
    try cleanupExpired(now: now)
    let name = input.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      name.count <= 160,
      URL(fileURLWithPath: name).lastPathComponent == name,
      !name.contains("/"),
      !name.contains("\\")
    else { throw OttoHostError.invalidAttachment("The file name is unsafe.") }
    let mime = input.mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !mime.isEmpty, mime.count <= 127, !mime.contains("\n"), !mime.contains("\r") else {
      throw OttoHostError.invalidAttachment("The MIME type is invalid.")
    }
    guard (1...Self.maximumBytes).contains(input.byteCount) else {
      throw OttoHostError.invalidAttachment("Files must be between 1 byte and 20 MB.")
    }
    let digest = input.sha256.lowercased()
    guard digest.count == 64,
      digest.unicodeScalars.allSatisfy({
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      })
    else { throw OttoHostError.invalidAttachment("The SHA-256 digest is invalid.") }

    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let id = UUID()
    let uploadDirectory = directory.appending(
      path: id.uuidString.lowercased(),
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: uploadDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let fileURL = uploadDirectory.appending(path: name)
    guard
      FileManager.default.createFile(
        atPath: fileURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    else { throw OttoHostError.invalidAttachment("The staging file could not be created.") }
    let expiresAt = now.addingTimeInterval(Self.lifetime)
    uploads[id] = Upload(
      id: id,
      threadID: input.threadID,
      displayName: name,
      mimeType: mime,
      byteCount: input.byteCount,
      sha256: digest,
      receivedBytes: 0,
      expiresAt: expiresAt,
      fileURL: fileURL
    )
    return AttachmentPrepareUploadOutput(
      uploadID: id,
      chunkSize: Self.chunkSize,
      expiresAt: expiresAt
    )
  }

  func append(
    _ input: AttachmentUploadChunkInput,
    now: Date = .now
  ) throws -> (receivedBytes: Int64, completed: CompletedMobileAttachmentUpload?) {
    try cleanupExpired(now: now)
    guard var upload = uploads[input.uploadID],
      upload.threadID == input.threadID,
      upload.expiresAt > now
    else { throw OttoHostError.attachmentTransferUnavailable }
    guard !input.data.isEmpty, input.data.count <= Self.chunkSize, input.offset >= 0 else {
      throw OttoHostError.invalidAttachment("The upload chunk is outside its bounds.")
    }
    let proposedEnd = input.offset + Int64(input.data.count)
    guard proposedEnd <= upload.byteCount else {
      throw OttoHostError.invalidAttachment("The upload exceeds its declared size.")
    }

    if input.offset < upload.receivedBytes {
      guard proposedEnd <= upload.receivedBytes else {
        throw OttoHostError.invalidAttachment("A retry overlaps new upload data.")
      }
      let handle = try FileHandle(forReadingFrom: upload.fileURL)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(input.offset))
      let existing = try handle.read(upToCount: input.data.count) ?? Data()
      guard existing == input.data else {
        throw OttoHostError.invalidAttachment("A retried chunk does not match stored bytes.")
      }
      return (upload.receivedBytes, nil)
    }
    guard input.offset == upload.receivedBytes else {
      throw OttoHostError.invalidAttachment("Upload chunks must be contiguous.")
    }

    let handle = try FileHandle(forWritingTo: upload.fileURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: input.data)
    try handle.synchronize()
    upload.receivedBytes = proposedEnd
    uploads[input.uploadID] = upload
    guard upload.receivedBytes == upload.byteCount else { return (upload.receivedBytes, nil) }

    let bytes = try Data(contentsOf: upload.fileURL, options: [.mappedIfSafe])
    let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard actual == upload.sha256 else {
      uploads[input.uploadID] = nil
      try? FileManager.default.removeItem(at: upload.fileURL.deletingLastPathComponent())
      throw OttoHostError.invalidAttachment("The uploaded bytes do not match their SHA-256 digest.")
    }
    uploads[input.uploadID] = nil
    return (
      upload.receivedBytes,
      CompletedMobileAttachmentUpload(
        uploadID: upload.id,
        threadID: upload.threadID,
        displayName: upload.displayName,
        mimeType: upload.mimeType,
        byteCount: upload.byteCount,
        fileURL: upload.fileURL
      )
    )
  }

  func discard(_ completed: CompletedMobileAttachmentUpload) {
    try? FileManager.default.removeItem(at: completed.fileURL.deletingLastPathComponent())
  }

  private func cleanupExpired(now: Date) throws {
    let expired = uploads.values.filter { $0.expiresAt <= now }
    for upload in expired {
      uploads[upload.id] = nil
      try? FileManager.default.removeItem(at: upload.fileURL.deletingLastPathComponent())
    }
  }
}
