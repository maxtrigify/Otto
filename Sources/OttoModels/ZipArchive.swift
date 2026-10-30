import Foundation

/// Writes uncompressed ("stored") zip archives.
public enum ZipArchive {
  /// A valid .zip using the "stored" method (no compression), with CRC-32, local headers,
  /// central directory and end record. Paths use forward slashes.
  public static func make(entries: [(path: String, data: Data)]) -> Data {
    var archive = Data()
    var directory = Data()
    // 1980-01-01 00:00, the DOS epoch.
    let dosTime: UInt16 = 0
    let dosDate: UInt16 = (1 << 5) | 1
    // Bit 11: file names are UTF-8.
    let flags: UInt16 = 1 << 11
    for entry in entries {
      let name = Data(entry.path.replacingOccurrences(of: "\\", with: "/").utf8)
      let checksum = crc32(entry.data)
      let size = UInt32(entry.data.count)
      let offset = UInt32(archive.count)

      archive.append(le: UInt32(0x0403_4b50))
      archive.append(le: UInt16(20))
      archive.append(le: flags)
      archive.append(le: UInt16(0))
      archive.append(le: dosTime)
      archive.append(le: dosDate)
      archive.append(le: checksum)
      archive.append(le: size)
      archive.append(le: size)
      archive.append(le: UInt16(name.count))
      archive.append(le: UInt16(0))
      archive.append(name)
      archive.append(entry.data)

      directory.append(le: UInt32(0x0201_4b50))
      directory.append(le: UInt16(20))
      directory.append(le: UInt16(20))
      directory.append(le: flags)
      directory.append(le: UInt16(0))
      directory.append(le: dosTime)
      directory.append(le: dosDate)
      directory.append(le: checksum)
      directory.append(le: size)
      directory.append(le: size)
      directory.append(le: UInt16(name.count))
      directory.append(le: UInt16(0))
      directory.append(le: UInt16(0))
      directory.append(le: UInt16(0))
      directory.append(le: UInt16(0))
      directory.append(le: UInt32(0))
      directory.append(le: offset)
      directory.append(name)
    }
    let directoryOffset = UInt32(archive.count)
    archive.append(directory)
    archive.append(le: UInt32(0x0605_4b50))
    archive.append(le: UInt16(0))
    archive.append(le: UInt16(0))
    archive.append(le: UInt16(entries.count))
    archive.append(le: UInt16(entries.count))
    archive.append(le: UInt32(directory.count))
    archive.append(le: directoryOffset)
    archive.append(le: UInt16(0))
    return archive
  }

  /// The bytes of a "stored" (uncompressed) entry, as `make` writes them. Returns nil when the
  /// entry is missing or compressed; compressed archives need an inflater.
  public static func storedEntry(named path: String, in archive: Data) -> Data? {
    let bytes = [UInt8](archive)
    func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
    func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
    var offset = 0
    while offset + 30 <= bytes.count, u32(offset) == 0x0403_4b50 {
      let flags = u16(offset + 6)
      let method = u16(offset + 8)
      let size = u32(offset + 18)
      let nameLength = u16(offset + 26)
      let extraLength = u16(offset + 28)
      let start = offset + 30 + nameLength + extraLength
      // Bit 3: sizes live in a trailing descriptor, so this entry cannot be skipped safely.
      guard flags & 0x08 == 0, start + size <= bytes.count else { return nil }
      let name = String(decoding: bytes[(offset + 30)..<(offset + 30 + nameLength)], as: UTF8.self)
      if name == path { return method == 0 ? Data(bytes[start..<(start + size)]) : nil }
      offset = start + size
    }
    return nil
  }

  /// Standard CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320).
  static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }

  private static let crcTable: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 {
      value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
    }
    return value
  }
}

extension Data {
  fileprivate mutating func append<T: FixedWidthInteger>(le value: T) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}
