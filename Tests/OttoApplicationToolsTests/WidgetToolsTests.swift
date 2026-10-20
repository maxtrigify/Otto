import Foundation
import OttoApplicationTools
import OttoCore
import OttoDocuments
import OttoModels
import OttoRuntime
import OttoTools
import Testing

#if canImport(Darwin)
  import Darwin
#endif

@Suite("Typed widget tools")
@MainActor
struct WidgetToolsTests {
  private func makeWorkspace() throws -> (
    store: CanvasStore, documents: WorkspaceDocumentStore, runner: WidgetJobRunner, root: String
  ) {
    let root = NSTemporaryDirectory() + "otto-widget-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let store = CanvasStore()
    let documents = WorkspaceDocumentStore(rootPath: root)
    let runner = WidgetJobRunner(store: store, documents: documents)
    return (store, documents, runner, root)
  }

  private var context: ToolContext {
    ToolContext(actorID: "widget-agent", scopes: [.canvasRead, .canvasWrite])
  }

  @Test("Creating a number widget with a script runs it and stores the payload")
  func createNumberWidgetWithScript() async throws {
    let workspace = try makeWorkspace()
    let tool = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: workspace.runner)

    let output = try await tool.call(
      WidgetCreateInput(
        name: "Substack Followers",
        x: 100, y: 100,
        view: "number",
        unit: "followers",
        script: "echo '{\"value\": 1284, \"label\": \"Substack\"}'",
        cron: "0 */6 * * *"
      ),
      context: context
    )

    #expect(output.manifest.view?.kind == .number)
    #expect(output.manifest.job?.script == WidgetCreateTool.scriptRelativePath)
    #expect(output.manifest.schedule?.cron == "0 */6 * * *")
    #expect(output.html == nil)
    guard case .widget(_, let stateJSON) = output.node.content else {
      Issue.record("Expected widget content")
      return
    }
    let state = WidgetRuntimeState.decode(from: stateJSON)
    #expect(state.payload == "{\"value\": 1284, \"label\": \"Substack\"}")
    #expect(state.history.map(\.value) == [1_284])
    #expect(state.lastError == nil)
  }

  @Test("Failing scripts record the error into widget state instead of failing creation")
  func createWidgetWithFailingScript() async throws {
    let workspace = try makeWorkspace()
    let tool = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: workspace.runner)

    let output = try await tool.call(
      WidgetCreateInput(
        name: "Broken", x: 0, y: 0, view: "number",
        script: "echo 'boom' >&2; exit 3", cron: "0 * * * *"
      ),
      context: context
    )

    guard case .widget(_, let stateJSON) = output.node.content else {
      Issue.record("Expected widget content")
      return
    }
    let state = WidgetRuntimeState.decode(from: stateJSON)
    #expect(state.payload == nil)
    #expect(state.lastError?.contains("exited 3") == true)
    #expect(state.lastError?.contains("boom") == true)
  }

  @Test("Custom HTML widgets can run scheduled JSON data jobs")
  func createHTMLWidgetWithDataJob() async throws {
    let workspace = try makeWorkspace()
    let tool = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: workspace.runner)

    let output = try await tool.call(
      WidgetCreateInput(
        name: "Custom Goal",
        html: "<html><head></head><body><output></output></body></html>",
        intervalSeconds: 3_600, x: 0, y: 0,
        script: "echo '{\"current\": 808, \"goal\": 1000}'"
      ),
      context: context
    )

    #expect(output.manifest.view == nil)
    #expect(output.manifest.job?.script == WidgetCreateTool.scriptRelativePath)
    #expect(output.manifest.schedule?.enabled == true)
    guard case .widget(_, let stateJSON) = output.node.content else {
      Issue.record("Expected widget content")
      return
    }
    let state = WidgetRuntimeState.decode(from: stateJSON)
    #expect(state.payload == "{\"current\": 808, \"goal\": 1000}")
    #expect(state.lastError == nil)
  }

  @Test("Custom HTML widget data must be valid bounded JSON")
  func htmlWidgetDataValidation() async throws {
    let workspace = try makeWorkspace()
    let create = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: workspace.runner)
    let created = try await create.call(
      WidgetCreateInput(name: "Custom", html: "<html><head></head></html>", x: 0, y: 0),
      context: context
    )
    let setData = WidgetSetDataTool(store: workspace.store, runner: workspace.runner)
    _ = try await setData.call(
      WidgetSetDataInput(nodeID: created.node.id, data: "{\"message\":\"hello\"}"),
      context: context
    )
    await #expect(throws: WidgetPayloadError.self) {
      _ = try await setData.call(
        WidgetSetDataInput(nodeID: created.node.id, data: "not-json"),
        context: self.context
      )
    }
  }

  @Test("widget.refresh reruns the job and appends to the run log")
  func refreshAndLogs() async throws {
    let workspace = try makeWorkspace()
    let create = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: workspace.runner)
    let created = try await create.call(
      WidgetCreateInput(
        name: "Counter", intervalSeconds: 3_600, x: 0, y: 0, view: "number",
        script: "echo '{\"value\": 7}'"
      ),
      context: context
    )

    let refresh = WidgetRefreshTool(store: workspace.store, runner: workspace.runner)
    let refreshed = try await refresh.call(
      WidgetNodeInput(nodeID: created.node.id), context: context)
    #expect(refreshed.state.history.count == 2)

    let logs = WidgetLogsTool(store: workspace.store, runner: workspace.runner)
    let history = try await logs.call(WidgetLogsInput(nodeID: created.node.id), context: context)
    #expect(history.runs.count == 2)
    #expect(history.runs.allSatisfy { $0.contains("\"success\":true") })
  }

  @Test("widget.set_data validates against the declared view")
  func setDataValidation() async throws {
    let workspace = try makeWorkspace()
    let create = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: workspace.runner)
    let created = try await create.call(
      WidgetCreateInput(name: "Pie", x: 0, y: 0, view: "pie"),
      context: context
    )

    let setData = WidgetSetDataTool(store: workspace.store, runner: workspace.runner)
    let output = try await setData.call(
      WidgetSetDataInput(
        nodeID: created.node.id,
        data: "{\"points\": [{\"label\": \"A\", \"value\": 3}, {\"label\": \"B\", \"value\": 5}]}"
      ),
      context: context
    )
    #expect(output.state.payload?.contains("\"points\"") == true)

    await #expect(throws: WidgetPayloadError.self) {
      _ = try await setData.call(
        WidgetSetDataInput(nodeID: created.node.id, data: "{\"value\": 3}"),
        context: self.context
      )
    }
  }

  @Test("Invalid view kinds, cron expressions, and mixed modes are rejected")
  func createValidation() async throws {
    let workspace = try makeWorkspace()
    let tool = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: workspace.runner)

    await #expect(throws: ToolRegistryError.self) {
      _ = try await tool.call(
        WidgetCreateInput(name: "Bad", x: 0, y: 0, view: "gauge"), context: self.context)
    }
    await #expect(throws: ToolRegistryError.self) {
      _ = try await tool.call(
        WidgetCreateInput(
          name: "Bad", x: 0, y: 0, view: "number", script: "echo hi", cron: "not cron"),
        context: self.context)
    }
    await #expect(throws: ToolRegistryError.self) {
      _ = try await tool.call(
        WidgetCreateInput(name: "Bad", html: "<html></html>", x: 0, y: 0, view: "number"),
        context: self.context)
    }
  }

  @Test("widget.update swaps the data script in place")
  func updateScript() async throws {
    let workspace = try makeWorkspace()
    let create = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: workspace.runner)
    let created = try await create.call(
      WidgetCreateInput(
        name: "Counter", x: 0, y: 0, view: "number", script: "echo '{\"value\": 1}'"),
      context: context
    )

    let update = WidgetUpdateTool(store: workspace.store, documents: workspace.documents)
    _ = try await update.call(
      WidgetUpdateInput(nodeID: created.node.id, script: "echo '{\"value\": 2}'"),
      context: context
    )
    let refresh = WidgetRefreshTool(store: workspace.store, runner: workspace.runner)
    let refreshed = try await refresh.call(
      WidgetNodeInput(nodeID: created.node.id), context: context)
    guard let payload = refreshed.state.payload,
      case .number(let number) = try WidgetPayload.parse(json: payload, kind: .number)
    else {
      Issue.record("Expected a number payload")
      return
    }
    #expect(number.value == 2)
  }

  @Test("Closed widgets remain listed and can be reopened from their package")
  func closeListAndReopen() async throws {
    let workspace = try makeWorkspace()
    let create = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: workspace.runner)
    let created = try await create.call(
      WidgetCreateInput(
        name: "Otto Swift Line Count", x: 20, y: 30, view: "number",
        data: "{\"value\": 42}"
      ),
      context: context
    )

    let close = WidgetCloseTool(store: workspace.store, documents: workspace.documents)
    let closed = try await close.call(
      WidgetOpenInput(name: "swift line count"), context: context)
    #expect(closed.closed.isOpen == false)
    #expect(closed.closed.nodeID == nil)
    #expect(!workspace.store.activeCanvas.nodes.contains { $0.id == created.node.id })
    #expect(
      FileManager.default.fileExists(
        atPath: (workspace.root as NSString).appendingPathComponent(
          "\(created.packagePath)/widget.json")))

    let list = WidgetListTool(store: workspace.store, documents: workspace.documents)
    let listed = try await list.call(WidgetListInput(), context: context)
    let summary = try #require(listed.widgets.first { $0.name == "Otto Swift Line Count" })
    #expect(summary.isOpen == false)
    #expect(summary.packagePath == created.packagePath)

    let open = WidgetOpenTool(store: workspace.store, documents: workspace.documents)
    let reopened = try await open.call(
      WidgetOpenInput(name: "open my Otto Swift Line Count widget"), context: context)
    #expect(reopened.node.displayName == "Otto Swift Line Count")
    #expect(reopened.state.payload == "{\"value\": 42}")
    guard case .widget(let path, _) = reopened.node.content else {
      Issue.record("Expected reopened widget content")
      return
    }
    #expect(path == created.packagePath)
  }

  @Test("Critical resource pressure prevents widget scripts from starting")
  func criticalPressureStopsRuns() async throws {
    let workspace = try makeWorkspace()
    let scheduler = AgentResourceScheduler(
      configuration: AgentResourceSchedulerConfiguration(
        nominalLimit: 1, elevatedLimit: 1, criticalLimit: 1))
    let runner = WidgetJobRunner(
      store: workspace.store, documents: workspace.documents, resourceScheduler: scheduler)
    let create = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: runner)
    let created = try await create.call(
      WidgetCreateInput(
        name: "Pressure", x: 0, y: 0, view: "number",
        script: "echo '{\"value\": 1}'"),
      context: context
    )
    await scheduler.updatePressure(.critical)

    do {
      _ = try await runner.run(nodeID: created.node.id)
      Issue.record("Expected critical pressure to reject the widget run")
    } catch let error as WidgetJobError {
      #expect(error == .resourcePressure)
    }
  }

  @Test("The widget resource scheduler serializes different widgets globally")
  func globalSerialization() async throws {
    let workspace = try makeWorkspace()
    let scheduler = AgentResourceScheduler(
      configuration: AgentResourceSchedulerConfiguration(
        nominalLimit: 1, elevatedLimit: 1, criticalLimit: 1))
    let runner = WidgetJobRunner(
      store: workspace.store, documents: workspace.documents, resourceScheduler: scheduler)
    let create = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: runner)
    let first = try await create.call(
      WidgetCreateInput(name: "First", x: 0, y: 0, view: "number", data: "{\"value\": 0}"),
      context: context)
    let second = try await create.call(
      WidgetCreateInput(name: "Second", x: 20, y: 20, view: "number", data: "{\"value\": 0}"),
      context: context)
    let sharedLog = (workspace.root as NSString).appendingPathComponent("serial.log")
    let update = WidgetUpdateTool(store: workspace.store, documents: workspace.documents)
    for (created, marker) in [(first, "A"), (second, "B")] {
      let manifest = WidgetManifest(
        name: created.manifest.name,
        view: WidgetViewDescriptor(kind: .number),
        job: WidgetJob(script: WidgetCreateTool.scriptRelativePath, timeoutSeconds: 5))
      _ = try await update.call(
        WidgetUpdateInput(
          nodeID: created.node.id,
          manifest: manifest,
          script: "echo '\(marker)-start' >> '\(sharedLog)'; sleep 0.2; "
            + "echo '\(marker)-end' >> '\(sharedLog)'; echo '{\"value\": 1}'"
        ),
        context: context
      )
    }

    async let firstRun = runner.run(nodeID: first.node.id)
    async let secondRun = runner.run(nodeID: second.node.id)
    _ = try await (firstRun, secondRun)

    let lines = try String(contentsOfFile: sharedLog, encoding: .utf8)
      .split(separator: "\n").map(String.init)
    #expect(
      lines == ["A-start", "A-end", "B-start", "B-end"]
        || lines == ["B-start", "B-end", "A-start", "A-end"])
  }

  @Test("Widget scripts inherit the resource limits supported by the host")
  func scriptsRunWithResourceLimits() async throws {
    #if canImport(Darwin)
      let memoryProbe = ""
      let resourceCondition = "cpu <= 10"
    #else
      let memoryProbe = "memory=$(ulimit -v)"
      let resourceCondition = "cpu <= 10 && memory <= 262144 && priority >= 15"
    #endif
    let workspace = try makeWorkspace()
    let create = WidgetCreateTool(
      store: workspace.store, documents: workspace.documents, runner: workspace.runner)
    let created = try await create.call(
      WidgetCreateInput(
        name: "Limited", x: 0, y: 0, view: "number",
        script: """
          cpu=$(ulimit -t)
          \(memoryProbe)
          priority=$(/bin/ps -o ni= -p $$ | /usr/bin/tr -d ' ')
          (( \(resourceCondition) )) || exit 42
          echo '{"value": 1}'
          """
      ),
      context: context
    )

    guard case .widget(_, let stateJSON) = created.node.content else {
      Issue.record("Expected widget content")
      return
    }
    let state = WidgetRuntimeState.decode(from: stateJSON)
    #expect(state.lastError == nil)
    #expect(state.payload == "{\"value\": 1}")
  }

  #if canImport(Darwin)
    @Test("Timing out a widget kills its busy child process group")
    func timeoutKillsChildProcessGroup() async throws {
      let workspace = try makeWorkspace()
      let runner = WidgetJobRunner(store: workspace.store, documents: workspace.documents)
      let create = WidgetCreateTool(
        store: workspace.store, documents: workspace.documents, runner: runner)
      let created = try await create.call(
        WidgetCreateInput(name: "Runaway", x: 0, y: 0, view: "number"), context: context)
      let manifest = WidgetManifest(
        name: "Runaway",
        view: WidgetViewDescriptor(kind: .number),
        job: WidgetJob(script: WidgetCreateTool.scriptRelativePath, timeoutSeconds: 1))
      let update = WidgetUpdateTool(store: workspace.store, documents: workspace.documents)
      _ = try await update.call(
        WidgetUpdateInput(
          nodeID: created.node.id,
          manifest: manifest,
          script: "(while :; do :; done) & echo $! > child.pid; wait"
        ),
        context: context
      )

      do {
        _ = try await runner.run(nodeID: created.node.id)
        Issue.record("Expected the runaway widget to time out")
      } catch let error as WidgetJobError {
        #expect(error == .timedOut(seconds: 1))
      }
      let pidText = try await workspace.documents.read(
        relativePath: "\(created.packagePath)/child.pid")
      let childPID = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
      try await Task.sleep(for: .milliseconds(100))
      let state = processState(childPID)
      #expect(state == nil || state?.hasPrefix("Z") == true)
    }

    @Test("Cancelling a widget run terminates its process tree and releases its permit")
    func cancellationCleansUpProcessTree() async throws {
      let workspace = try makeWorkspace()
      let scheduler = AgentResourceScheduler(
        configuration: AgentResourceSchedulerConfiguration(
          nominalLimit: 1, elevatedLimit: 1, criticalLimit: 1))
      let runner = WidgetJobRunner(
        store: workspace.store, documents: workspace.documents, resourceScheduler: scheduler)
      let create = WidgetCreateTool(
        store: workspace.store, documents: workspace.documents, runner: runner)
      let created = try await create.call(
        WidgetCreateInput(name: "Cancelled", x: 0, y: 0, view: "number"), context: context)
      let manifest = WidgetManifest(
        name: "Cancelled",
        view: WidgetViewDescriptor(kind: .number),
        job: WidgetJob(script: WidgetCreateTool.scriptRelativePath, timeoutSeconds: 60))
      let update = WidgetUpdateTool(store: workspace.store, documents: workspace.documents)
      _ = try await update.call(
        WidgetUpdateInput(
          nodeID: created.node.id,
          manifest: manifest,
          script: "(while :; do :; done) & echo $! > cancel-child.pid; wait"
        ),
        context: context
      )

      let run = Task { try await runner.run(nodeID: created.node.id) }
      let pidPath = "\(created.packagePath)/cancel-child.pid"
      var pidText: String?
      for _ in 0..<40 {
        pidText = try? await workspace.documents.read(relativePath: pidPath)
        if pidText != nil { break }
        try await Task.sleep(for: .milliseconds(25))
      }
      let recordedPID = try #require(pidText)
      let childPID = try #require(
        pid_t(recordedPID.trimmingCharacters(in: .whitespacesAndNewlines)))
      run.cancel()
      do {
        _ = try await run.value
        Issue.record("Expected the widget run to be cancelled")
      } catch let error as WidgetJobError {
        #expect(error == .cancelled)
      }

      try await Task.sleep(for: .milliseconds(100))
      let state = processState(childPID)
      #expect(state == nil || state?.hasPrefix("Z") == true)
      let snapshot = await scheduler.snapshot()
      #expect(snapshot.running.isEmpty)
      #expect(snapshot.queued.isEmpty)
    }
  #endif

}

#if canImport(Darwin)
  private func processState(_ processID: pid_t) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "state=", "-p", "\(processID)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    let state = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return state.isEmpty ? nil : state
  }
#endif
