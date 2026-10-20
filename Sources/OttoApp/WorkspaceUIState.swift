import SwiftUI

/// Session-only presentation state shared between the menu commands and the workspace views.
/// Nothing here persists — it is how the keyboard layer reaches transient overlays and sheets.
@MainActor
final class WorkspaceUIState: ObservableObject {
  @Published var showsCommandPalette = false
  @Published var showsMemoryInspector = false
  @Published var showsWidgetManager = false
  @Published var showsRoutineManager = false
}
