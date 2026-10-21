/// Runs async work one piece at a time, in the order it arrives. An actor alone does
/// not do that: it lets the next call in whenever the current one suspends.
public actor SerialGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer { leave() }
        return try await work()
    }

    /// Hands the gate straight to the next in line, so nobody can slip in between.
    private func leave() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
