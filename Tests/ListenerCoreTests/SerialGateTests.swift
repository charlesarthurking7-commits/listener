import Synchronization
import Testing

@testable import ListenerCore

private final class Log: Sendable {
    private let entries = Mutex<[String]>([])

    func add(_ entry: String) {
        entries.withLock { $0.append(entry) }
    }

    var all: [String] { entries.withLock { $0 } }
}

struct SerialGateTests {
    @Test func workRunsOneAtATimeInTheOrderItArrives() async throws {
        let gate = SerialGate()
        let log = Log()
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
