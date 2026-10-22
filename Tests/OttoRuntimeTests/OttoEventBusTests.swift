import Foundation
import OttoRuntime
import Testing

@Suite("Event bus", .timeLimit(.minutes(1)))
struct OttoEventBusTests {
  @Test("Replay and concurrent live publishers retain sequence order without gaps")
  func orderedReplayAndLiveDelivery() async {
    let bus = OttoEventBus(historyLimit: 100)
    for _ in 0..<100 { bus.publish(OttoEvent(type: .agentOutputAppended)) }
    let stream = bus.stream(afterSequence: 50)
    let reader = Task {
      var sequences: [Int] = []
      for await event in stream {
        sequences.append(event.sequence)
        if sequences.count == 1_050 { break }
      }
      return sequences
    }
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<10 {
        group.addTask {
          for _ in 0..<100 { bus.publish(OttoEvent(type: .agentOutputAppended)) }
        }
      }
    }
    let sequences = await reader.value
    #expect(sequences == Array(51...1_100))
    #expect(bus.latestSequence == 1_100)
  }

  @Test("Publishing survives repeated cancellation of event wait task groups")
  func cancellationWhilePublishing() async {
    let bus = OttoEventBus(historyLimit: 4)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          for _ in 0..<100 {
            let stream = bus.stream(afterSequence: bus.latestSequence)
            await withTaskGroup(of: Void.self) { waiters in
              waiters.addTask {
                for await _ in stream { break }
              }
              waiters.addTask { await Task.yield() }
              await waiters.next()
              waiters.cancelAll()
            }
          }
        }
      }
      group.addTask {
        for _ in 0..<5_000 {
          bus.publish(OttoEvent(type: .agentOutputAppended))
          await Task.yield()
        }
      }
    }
    // The bus must still accept subscriptions and publish after cancellation churn.
    let stream = bus.stream(afterSequence: bus.latestSequence)
    let event = bus.publish(OttoEvent(type: .agentRunCompleted))
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == event)
  }
}
