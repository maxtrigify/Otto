import SwiftUI

enum VoiceOperatingMode: String, CaseIterable, Identifiable {
  case off
  case pushToTalk
  case alwaysListening
  case outputOnly

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .off: "Off"
    case .pushToTalk: "Push to Talk"
    case .alwaysListening: "Always Listening"
    case .outputOnly: "Output Only"
    }
  }

  var summary: String {
    switch self {
    case .off: "No voice connection, microphone, or spoken notifications."
    case .pushToTalk: "Hold the Talk shortcut to send microphone audio; release to stop."
    case .alwaysListening: "Keep conversational voice listening until it is put to sleep."
    case .outputOnly:
      "Announce selected agent updates with the microphone off; hold the Talk shortcut to reply."
    }
  }
}

enum LocalSpeechEngine: String, CaseIterable, Identifiable {
  case apple
  case parakeet

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .apple: "Apple On-Device"
    case .parakeet: "Parakeet v3 · Experimental"
    }
  }

  var summary: String {
    switch self {
    case .apple: "Built into macOS; streaming partial transcripts."
    case .parakeet: "Higher-accuracy 25-language model; about 643 MB plus runtime."
    }
  }
}

enum VoiceInteractionMode: String, CaseIterable, Identifiable {
  case talk
  case command
  case dictate

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .talk: "Talk to Otto"
    case .command: "Give a command"
    case .dictate: "Dictate verbatim"
    }
  }

  var summary: String {
    switch self {
    case .talk: "Conversational realtime voice with tools and spoken replies."
    case .command: "On-device transcription with deterministic local routing."
    case .dictate: "On-device transcription delivered verbatim to the focused node."
    }
  }

  var defaultShortcut: VoiceShortcut {
    switch self {
    case .talk: .optionSpace
    case .command: .controlOptionSpace
    case .dictate: .shiftOptionSpace
    }
  }
}

enum VoiceShortcut: String, CaseIterable, Identifiable {
  case optionSpace
  case controlOptionSpace
  case shiftOptionSpace
  case commandOptionSpace
  case optionV
  case optionC
  case optionD

  var id: String { rawValue }

  var key: KeyEquivalent {
    switch self {
    case .optionSpace, .controlOptionSpace, .shiftOptionSpace, .commandOptionSpace: .space
    case .optionV: "v"
    case .optionC: "c"
    case .optionD: "d"
    }
  }

  var modifiers: EventModifiers {
    switch self {
    case .optionSpace, .optionV, .optionC, .optionD: .option
    case .controlOptionSpace: [.control, .option]
    case .shiftOptionSpace: [.shift, .option]
    case .commandOptionSpace: [.command, .option]
    }
  }

  var label: String {
    switch self {
    case .optionSpace: "⌥Space"
    case .controlOptionSpace: "⌃⌥Space"
    case .shiftOptionSpace: "⇧⌥Space"
    case .commandOptionSpace: "⌘⌥Space"
    case .optionV: "⌥V"
    case .optionC: "⌥C"
    case .optionD: "⌥D"
    }
  }
}
