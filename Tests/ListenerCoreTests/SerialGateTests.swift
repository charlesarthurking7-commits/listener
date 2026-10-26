import Testing

@testable import ListenerCore

struct SerialGateTests {
    @Test func workRunsOneAtATimeInTheOrderItArrives() async throws {
        let gate = SerialGate()
        let log = Collected<String>()
        let first = Task {
            try await gate.run {
                log.add("first starts")
                try await Task.sleep(for: .milliseconds(50))
                log.add("first ends")
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        let second = Task { try await gate.run { log.add("second") } }
        try await first.value
        try await second.value
        #expect(log.all == ["first starts", "first ends", "second"])
    }

    @Test func aFailureLetsTheNextOneIn() async throws {
        struct Failure: Error {}
        let gate = SerialGate()
        await #expect(throws: Failure.self) { try await gate.run { throw Failure() } }
        #expect(try await gate.run { 42 } == 42)
    }
}
