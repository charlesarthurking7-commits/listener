/// Keeps one speaker's speech-to-text going for the whole call.
///
/// Audio is queued without waiting, so a slow recogniser never holds up voice activity
/// detection. A stream that fails, or ends by itself, is reopened with backoff and gets
/// the audio since the last final again, so the utterance it cut off is still
/// recognised. Result times are converted from the stream's own audio clock to the
/// channel's, which also accounts for skipped silence and reconnects.
final class SpeechChannel: Sendable {
    enum Output: Sendable {
        /// A result whose audio times are channel seconds.
        case event(SpeechEvent)
        case warning(String)
    }

    struct RetryPolicy: Sendable {
        var initialDelay = Duration.milliseconds(500)
        var maximumDelay = Duration.seconds(8)
        /// How long a failed stream gets to hand over its last finals.
        var drainTimeout = Duration.seconds(1)
        /// Audio kept for resending after a failure, in seconds.
        var bufferSeconds = 30.0
    }

    private let input: AsyncStream<Message>.Continuation
    private let task: Task<Void, Never>

    init(
        speaker: Speaker,
        provider: any SpeechToTextProvider,
        retry: RetryPolicy = RetryPolicy(),
        output: @escaping @Sendable (Output) async -> Void
    ) {
        let (messages, input) = AsyncStream.makeStream(of: Message.self)
        self.input = input
        task = Task {
            var loop = Loop(speaker: speaker, provider: provider, retry: retry, input: input, output: output)
            await loop.run(messages)
        }
    }

    func send(_ frame: ChannelFrame) {
        input.yield(.audio(frame))
    }

    /// No more audio: the recogniser delivers its last finals, then the channel ends.
    func finish() {
        input.yield(.endOfAudio)
    }

    /// Gives up at once, e.g. when the last finals take too long.
    func cancel() {
        task.cancel()
    }

    func waitUntilDone() async {
        await task.value
    }
}

private enum Message: Sendable {
    case audio(ChannelFrame)
    case endOfAudio
    case result(SpeechEvent, stream: Int)
    case streamEnded((any Error)?, stream: Int)
    case drainExpired(stream: Int)
    case retry
}

private struct StreamEndedEarly: Error, CustomStringConvertible {
    var description: String { "the stream ended unexpectedly" }
}

/// The channel's state machine. It runs on the channel's one task, so it needs no
/// locks: stream readers and retry timers only post messages to it.
///
/// After a failure it reconnects once two things have happened: the backoff delay has
/// passed, and the old stream has delivered what it still had (or a short drain timeout
/// has passed), so its last finals are not lost and the audio they cover is not sent
/// twice.
private struct Loop {
    let speaker: Speaker
    let provider: any SpeechToTextProvider
    let retry: SpeechChannel.RetryPolicy
    let input: AsyncStream<Message>.Continuation
    let output: @Sendable (SpeechChannel.Output) async -> Void

    private var stream: (any SpeechStream)?
    private var streamID = 0
    private var reader: Task<Void, Never>?
    private var readerEnded = true
    /// A failed stream whose reader may still hand over finals.
    private var drainingID: Int?
    private var backoffPending = false
    private var backoff: Backoff
    /// The current stream's audio clock onto the channel's.
    private var clock = TimeMap(tolerance: 0.001)
    private var streamSeconds = 0.0
    /// Sent since the last final; resent to a new stream after a failure.
    private var unfinalised: [ChannelFrame] = []
    /// Arrived while there was no stream.
    private var waiting: [ChannelFrame] = []
    private var failing = false
    private var audioEnded = false
    private var lastAttemptMade = false

    init(
        speaker: Speaker, provider: any SpeechToTextProvider, retry: SpeechChannel.RetryPolicy,
        input: AsyncStream<Message>.Continuation, output: @escaping @Sendable (SpeechChannel.Output) async -> Void
    ) {
        self.speaker = speaker
        self.provider = provider
        self.retry = retry
        self.input = input
        self.output = output
        backoff = Backoff(initial: retry.initialDelay, maximum: retry.maximumDelay)
    }

    mutating func run(_ messages: AsyncStream<Message>) async {
        defer { shutDown() }
        await connect()
        for await message in messages {
            switch message {
            case .audio(let frame):
                await send(frame)
            case .endOfAudio:
                audioEnded = true
                backoffPending = false
                if let stream {
                    Task { await stream.finish() }
                } else if await !reconnectIfReady() {
                    return
                }
            case .result(let event, let id):
                if id == streamID && stream != nil || id == drainingID && event.kind == .final {
                    await deliver(event)
                }
            case .streamEnded(let error, let id):
                if id == drainingID {
                    drainingID = nil
                    if await !reconnectIfReady() {
                        return
                    }
                } else if id == streamID && stream != nil {
                    readerEnded = true
                    if audioEnded {
                        return
                    }
                    await lose(error ?? StreamEndedEarly())
                }
            case .drainExpired(let id) where id == drainingID:
                reader?.cancel()
                drainingID = nil
                if await !reconnectIfReady() {
                    return
                }
            case .retry:
                backoffPending = false
                if await !reconnectIfReady() {
                    return
                }
            case .drainExpired:
                break
            }
        }
    }

    /// Connects when nothing stands in the way. Returns false when the channel is done:
    /// the audio has ended and the last attempt to deliver it failed.
    private mutating func reconnectIfReady() async -> Bool {
        guard stream == nil, drainingID == nil, !backoffPending else {
            return true
        }
        if audioEnded {
            guard !lastAttemptMade else {
                return false
            }
            lastAttemptMade = true
        }
        await connect()
        if audioEnded {
            guard let stream else {
                return drainingID != nil
            }
            Task { await stream.finish() }
        }
        return true
    }

    private mutating func connect() async {
        let opened: any SpeechStream
        do {
            opened = try await provider.openStream(for: speaker)
        } catch {
            await lose(error)
            return
        }
        streamID += 1
        stream = opened
        clock = TimeMap(tolerance: 0.001)
        streamSeconds = 0
        startReader(for: opened)
        if failing {
            failing = false
            await output(.warning("Speech-to-text for \(speaker.rawValue) is back."))
        }
        let backlog = unfinalised + waiting
        unfinalised = []
        waiting = []
        for frame in backlog {
            await send(frame)
        }
    }

    private mutating func send(_ frame: ChannelFrame) async {
        guard let stream else {
            waiting.append(frame)
            trim(&waiting)
            return
        }
        clock.record(from: streamSeconds, to: frame.start)
        unfinalised.append(frame)
        trim(&unfinalised)
        do {
            try await stream.send(frame.chunk)
            streamSeconds += frame.duration
        } catch {
            await lose(error)
        }
    }

    private mutating func deliver(_ event: SpeechEvent) async {
        backoff.reset()
        var converted = event
        converted.audioStart = event.audioStart.map { clock.map($0) }
        converted.audioEnd = event.audioEnd.map { clock.mapEnd($0) }
        if event.kind == .final {
            if let end = converted.audioEnd {
                unfinalised.removeAll { $0.end <= end + 0.001 }
            } else {
                unfinalised.removeAll()
            }
        }
        await output(.event(converted))
    }

    /// The current stream (or the attempt to open one) failed.
    private mutating func lose(_ error: any Error) async {
        if let failed = stream {
            stream = nil
            // Finishing makes the stream hand over its last finals and end its events.
            Task { await failed.finish() }
            if !readerEnded {
                drainingID = streamID
                let id = streamID
                Task { [input, timeout = retry.drainTimeout] in
                    try? await Task.sleep(for: timeout)
                    input.yield(.drainExpired(stream: id))
                }
            }
        }
        await output(.event(SpeechEvent(kind: .interim, text: "")))
        if !failing {
            failing = true
            await output(.warning("Speech-to-text for \(speaker.rawValue) dropped (\(error)). Reconnecting."))
        }
        if !audioEnded {
            startBackoff()
        }
    }

    private mutating func startBackoff() {
        guard !backoffPending else {
            return
        }
        backoffPending = true
        let delay = backoff.next()
        Task { [input] in
            try? await Task.sleep(for: delay)
            input.yield(.retry)
        }
    }

    private mutating func startReader(for stream: any SpeechStream) {
        let id = streamID
        readerEnded = false
        // Reader messages queue up behind each other, so everything a stream said
        // before it ended is handled before its end.
        reader = Task { [input] in
            do {
                for try await event in stream.events {
                    input.yield(.result(event, stream: id))
                }
                input.yield(.streamEnded(nil, stream: id))
            } catch {
                input.yield(.streamEnded(error, stream: id))
            }
        }
    }

    private func trim(_ frames: inout [ChannelFrame]) {
        guard let last = frames.last else {
            return
        }
        let oldest = last.end - retry.bufferSeconds
        if let keepFrom = frames.firstIndex(where: { $0.start >= oldest }), keepFrom > 0 {
            frames.removeFirst(keepFrom)
        }
    }

    private func shutDown() {
        reader?.cancel()
        input.finish()
        if let stream, !audioEnded {
            Task { await stream.finish() }
        }
    }
}
