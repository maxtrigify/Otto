import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("Voice tool contract")
struct VoiceToolContractTests {
  @Test("Command palette is the complete registered catalog and every action validates input")
  func commandPaletteCatalog() async throws {
    let canvas = OttoCanvas(name: "Palette contract")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor(),
      workspacePath: FileManager.default.currentDirectoryPath
    )

    let definitions = await registry.definitions().filter { !$0.isProviderInternal }
    let actions = CommandPaletteCatalog.actions(from: definitions)
    #expect(actions.map(\.name) == definitions.map(\.name))

    let context = ToolContext(
      actorID: "palette-contract",
      scopes: Set(ToolScope.allCases),
      confirmed: true,
      source: .userInterface
    )
    for action in actions {
      let template = CommandPaletteCatalog.inputTemplate(for: action)
      _ = try JSONDecoder().decode(JSONValue.self, from: Data(template.utf8))

      do {
        _ = try await registry.call(name: action.name, input: .string("invalid"), context: context)
        Issue.record("\(action.name) accepted a non-object palette input")
      } catch let error as ToolRegistryError {
        guard case .invalidInput = error else {
          Issue.record("\(action.name) failed before input validation: \(error)")
          continue
        }
      } catch {
        Issue.record("\(action.name) did not report a registry input error: \(error)")
      }
    }
  }

  @Test("Every projected action exposes a closed object schema with valid required fields")
  func schemasAreActionable() async throws {
    let canvas = OttoCanvas(name: "Tool contract")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor(),
      workspacePath: FileManager.default.currentDirectoryPath
    )

    let definitions = await registry.definitions()
    for definition in definitions {
      guard case .object(let schema) = definition.inputSchema else {
        Issue.record("\(definition.name) input schema is not an object")
        continue
      }
      #expect(schema["type"] == .string("object"), "\(definition.name) must declare object input")
      guard case .object(let properties) = schema["properties"] else {
        Issue.record("\(definition.name) must expose input properties")
        continue
      }
      #expect(
        schema["additionalProperties"] == .bool(false),
        "\(definition.name) must reject invented arguments"
      )
      if case .array(let required) = schema["required"] {
        for value in required {
          let name = try #require(value.stringValue)
          #expect(properties[name] != nil, "\(definition.name) requires missing property \(name)")
        }
      }
    }
  }

  @Test("Voice projection covers direct spatial and content control actions")
  func capabilitiesAreRegistered() async throws {
    let canvas = OttoCanvas(name: "Capabilities")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor())
    let names = Set(await registry.definitions().map(\.name))
    let expected: Set<String> = [
      "node.create", "node.list", "node.get", "node.focus", "node.expand",
      "node.close", "node.close_all",
      "canvas.get", "canvas.list", "canvas.create", "canvas.switch", "canvas.rename",
      "agent.spawn", "agent.send_prompt", "agent.send_input", "agent.get_status",
      "agent.get_output", "agent.get_result", "agent.interrupt", "agent.stop", "agent.resume",
      "terminal.open", "terminal.run", "terminal.send_input", "terminal.send_bytes",
      "terminal.read_output", "terminal.wait", "terminal.resize", "terminal.stop_process",
      "browser.open", "browser.open_tab", "browser.get_selection", "browser.navigate",
      "browser.get_state", "browser.refresh", "browser.back",
      "browser.forward", "browser.inspect", "browser.click", "browser.type", "browser.scroll",
      "browser.screenshot", "browser.open_external",
      "surface.set", "layout.stage",
      "media.open", "media.play", "media.pause", "media.stop", "media.set_volume", "media.seek",
      "theme.list", "theme.set", "recipe.list", "recipe.save", "recipe.boot",
      "event.wait", "diagnostics.run",
    ]

    #expect(expected.isSubset(of: names))
    let retired: Set<String> = [
      "node.move", "node.resize", "canvas.set_viewport", "canvas.fit_all",
      "layout.organize", "layout.set", "layout.set_snap",
    ]
    #expect(retired.isDisjoint(with: names))
  }
}
