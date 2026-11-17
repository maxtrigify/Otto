import Foundation
import OttoTools

/// Where the screen should go after voice has done something, so the person sees it happen.
///
/// When someone asks aloud for a session to be started or a document to be written and the
/// screen stays where it was, it looks as though nothing happened. Voice is meant to feel like
/// it has taken hold of the app: whatever it acts on comes to the front.
public enum VoiceFollow: Equatable, Sendable {
  /// A session or a bot's conversation, by the agent that runs it.
  case conversation(UUID)
  case document(path: String)
  case place(String)

  public static func destination(afterTool name: String, output: JSONValue) -> VoiceFollow? {
    guard case .object(let fields) = output else { return nil }
    switch name {
    case "agent.spawn", "agent.send_prompt", "agent.send_input", "agent.resume", "agent.restart":
      guard let id = fields["agentID"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
        return nil
      }
      return .conversation(id)
    case "docs.create", "docs.write", "docs.suggest_edit", "sheet.set_cells", "sheet.tabs",
      "slides.add_slide", "slides.update_slide", "slides.delete_slide", "slides.set_deck",
      "slides.set_theme":
      guard case .object(let file)? = fields["file"], let path = file["path"]?.stringValue,
        !path.isEmpty
      else { return nil }
      return .document(path: path)
    case "browser.open", "browser.open_tab", "browser.navigate":
      return .place("browser")
    case "dashboard.create", "dashboard.update":
      return .place("dashboards")
    case "home.add_card", "home.update_card", "home.request_approval":
      return .place("home")
    case "routine.create", "routine.update", "routine.test_run":
      return .place("automations")
    default:
      // Reading something, or opening it with one of the tools that already shows it.
      return nil
    }
  }
}
