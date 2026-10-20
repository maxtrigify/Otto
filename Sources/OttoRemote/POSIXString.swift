import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

func decodeRemoteCString(_ pointer: UnsafePointer<CChar>) -> String {
  let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
  return String(
    decoding: UnsafeBufferPointer(start: bytes, count: strlen(pointer)),
    as: UTF8.self
  )
}
