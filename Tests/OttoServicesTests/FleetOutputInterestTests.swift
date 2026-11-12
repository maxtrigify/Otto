import Foundation
import OttoModels
import OttoRuntime
import Testing

@testable import OttoServices

@Suite("Fleet output interest")
@MainActor
struct FleetOutputInterestTests {
  @Test("Output is wanted only while a view is drawing it, and the first viewer asks for it")
  func viewersAreCounted() {
    let store = AgentFleetStore()
    let agent = UUID()
    let other = UUID()
    #expect(!store.isShowingOutput(of: agent))
    store.beginShowingOutput(of: agent)
    store.beginShowingOutput(of: agent)
    #expect(store.isShowingOutput(of: agent))
    #expect(!store.isShowingOutput(of: other))
    store.endShowingOutput(of: agent)
    #expect(store.isShowingOutput(of: agent))
    store.endShowingOutput(of: agent)
    #expect(!store.isShowingOutput(of: agent))
    // An unbalanced end must not leave the count negative.
    store.endShowingOutput(of: agent)
    store.beginShowingOutput(of: agent)
    #expect(store.isShowingOutput(of: agent))
  }

  @Test("A snapshot fetched without output keeps the output already published for that process")
  func completesFromPublishedOutput() {
    let id = UUID()
    func snapshot(output: String, start: Int, end: Int, pid: Int32?) -> AgentRuntimeSnapshot {
      var value = AgentRuntimeSnapshot(
        id: id, provider: .claudeCode, state: .working, confidence: 1,
        output: output, outputStartOffset: start, outputEndOffset: end)
      value.processID = pid
      return value
    }
    let published = snapshot(output: "hello", start: 10, end: 15, pid: 42)
    var streaming = snapshot(output: "", start: 10, end: 90, pid: 42)
    streaming.liveText = "Responding"

    let carried = AgentFleetStore.completing(streaming, published: published)
    #expect(carried.output == "hello")
    #expect(carried.outputStartOffset == 10)
    #expect(carried.outputEndOffset == 15)
    #expect(carried.liveText == "Responding")

    // Nothing published yet, or output from an earlier process: report that none is retained
    // rather than pairing stale text with offsets it does not belong to.
    for previous in [nil, snapshot(output: "old", start: 0, end: 3, pid: 7)] {
      let empty = AgentFleetStore.completing(streaming, published: previous)
      #expect(empty.output.isEmpty)
      #expect(empty.outputStartOffset == 90)
      #expect(empty.outputEndOffset == 90)
    }
  }
}
