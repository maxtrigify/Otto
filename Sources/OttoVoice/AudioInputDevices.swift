import CoreAudio
import Foundation

/// A microphone the Mac can record from.
public struct AudioInputDevice: Identifiable, Sendable, Equatable {
  /// Stable across restarts and re-plugging, unlike the numeric device number.
  public var id: String
  public var name: String
  public var isSystemDefault: Bool

  public init(id: String, name: String, isSystemDefault: Bool = false) {
    self.id = id
    self.name = name
    self.isSystemDefault = isSystemDefault
  }
}

/// Which microphone Otto's voice listens through.
///
/// Otto used whatever macOS had as its default input. That fails quietly: a MacBook with its lid
/// closed keeps its built-in microphone as the default and delivers perfect silence from it. So
/// the person can choose a microphone for Otto alone, without changing it for the rest of the Mac.
public enum AudioInputDevices {
  /// Where the chosen microphone is remembered. Empty or missing means the system default.
  public static let preferenceKey = "otto.voice.inputDeviceUID"

  public static func preferredUID(defaults: UserDefaults = .standard) -> String? {
    let uid = defaults.string(forKey: preferenceKey) ?? ""
    return uid.isEmpty ? nil : uid
  }

  /// Every connected microphone, in the order macOS lists them.
  public static func all() -> [AudioInputDevice] {
    let systemDefault = defaultInputID()
    return deviceIDs().compactMap { id in
      guard inputChannelCount(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
        let name = string(id, kAudioObjectPropertyName)
      else { return nil }
      return AudioInputDevice(id: uid, name: name, isSystemDefault: id == systemDefault)
    }
  }

  /// The device number for a remembered microphone, or nil if it is no longer connected.
  public static func deviceID(forUID uid: String) -> AudioDeviceID? {
    deviceIDs().first {
      inputChannelCount($0) > 0 && string($0, kAudioDevicePropertyDeviceUID) == uid
    }
  }

  /// The device number Otto should record from, or nil to leave the system default in place.
  public static func preferredDeviceID(defaults: UserDefaults = .standard) -> AudioDeviceID? {
    preferredUID(defaults: defaults).flatMap(deviceID(forUID:))
  }

  private static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  private static func deviceIDs() -> [AudioDeviceID] {
    var property = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else {
      return []
    }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids) == noErr else {
      return []
    }
    return ids
  }

  /// The name of the device the Mac plays sound through, which is where Otto's voice goes.
  public static func systemOutputName() -> String? {
    var property = address(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id)
    return status == noErr ? string(id, kAudioObjectPropertyName) : nil
  }

  /// The microphone macOS itself uses by default.
  public static func systemDefaultDeviceID() -> AudioDeviceID? { defaultInputID() }

  /// Makes a microphone the default for the whole Mac, which is what lets Otto keep echo
  /// cancellation with it. Only ever done when the person asks for it.
  @discardableResult
  public static func makeSystemDefault(uid: String) -> Bool {
    guard var id = deviceID(forUID: uid) else { return false }
    var property = address(kAudioHardwarePropertyDefaultInputDevice)
    return AudioObjectSetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &property, 0, nil,
      UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
  }

  private static func defaultInputID() -> AudioDeviceID? {
    var property = address(kAudioHardwarePropertyDefaultInputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id)
    return status == noErr ? id : nil
  }

  private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
    var property = address(
      kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else {
      return 0
    }
    let buffer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, buffer) == noErr else {
      return 0
    }
    let list = UnsafeMutableAudioBufferListPointer(
      buffer.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector)
    -> String?
  {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
      AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0)
    }
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }
}
