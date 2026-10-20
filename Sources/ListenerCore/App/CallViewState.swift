import Foundation

/// One line of the transcript as the window shows it.
public struct TranscriptRow: Sendable, Equatable, Identifiable {
    public enum ID: Sendable, Hashable {
        case turn(Int)
        case interim(Speaker)
    }

    public let id: ID
    public let speaker: Speaker
    public let text: String
    /// Still being recognised; shown dimmer and replaced as words settle.
    public let isInterim: Bool
    /// False when the row above is the same speaker, so a run of rows shows the
    /// speaker chip once.
    public let showsSpeaker: Bool
    /// Session seconds the turn started at. Nil for interim text.
    public let start: Double?
}

/// The suggested answer currently on screen.
public struct AnswerCard: Sendable, Equatable, Identifiable {
    public enum Status: Sendable, Equatable {
        /// Asked, no text yet.
        case waiting
        case streaming
        case finished
        case failed(String)
    }

    public let id: Int
    public let tier: AnswerTier
    public let model: String
    public let askedAt: Date
    public var text = ""
    public var status = Status.waiting
    /// Hotkey to first token. Measured locally while streaming, then replaced by the
    /// session's own figure when the answer finishes.
    public var firstTokenMs: Double?
    public var cost: Double?

    public var isActive: Bool { status == .waiting || status == .streaming }
}

public enum NoticeAction: Sendable, Equatable {
    case revealInFinder(path: String)
    case openFile(path: String)
    case openURL(String, title: String)

    public var title: String {
        switch self {
        case .revealInFinder: "Show in Finder"
        case .openFile: "Open"
        case .openURL(_, let title): title
        }
    }
}

/// A banner above the transcript.
public struct Notice: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case info
        case warning
        case error
    }

    public let id: Int
    public let kind: Kind
    public let message: String
    public let action: NoticeAction?
}

/// Banners, newest last. Adding one that is already showing does nothing, and
/// beyond `maximum` the oldest is pushed out.
public struct NoticeList: Sendable, Equatable {
    public static let maximum = 3

    public private(set) var items: [Notice] = []
    private var nextID = 1

    public init() {}

    public mutating func add(_ kind: Notice.Kind, _ message: String, action: NoticeAction? = nil) {
        if items.contains(where: { $0.kind == kind && $0.message == message }) {
            return
        }
        items.append(Notice(id: nextID, kind: kind, message: message, action: action))
        nextID += 1
        if items.count > Self.maximum {
            items.removeFirst(items.count - Self.maximum)
        }
    }

    public mutating func dismiss(id: Int) {
        items.removeAll { $0.id == id }
    }
}

/// Everything the window shows, rebuilt from the session's events. The window's
/// model owns one of these and forwards every SessionEvent to `apply(_:now:)`.
public struct CallViewState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Nothing running. Either no call yet, or the last start failed.
        case idle
        case starting
        case listening
        /// Capture has stopped; the last finals arrive and the session is saved.
        case stopping
        case summarizing
        /// A call ended. Its transcript stays on screen until the next Start.
        case finished
    }

    public private(set) var phase = Phase.idle
    public private(set) var listeningSince: Date?
    public private(set) var channels: [ChannelInfo] = []
    public private(set) var rows: [TranscriptRow] = []
    public private(set) var answer: AnswerCard?
    public private(set) var cost = CostSummary()
    /// Hotkey to first token of the last finished answer, in milliseconds.
    public private(set) var lastLatencyMs: Double?
    private var noticeList = NoticeList()
    public private(set) var sessionDirectory: String?
    public private(set) var summaryFile: String?

    private var interimOrder: [Speaker] = []

    public init() {}

    public var notices: [Notice] { noticeList.items }
    public var isListening: Bool { phase == .listening }
    public var isBusy: Bool { phase == .starting || phase == .stopping || phase == .summarizing }
    public var canStart: Bool { phase == .idle || phase == .finished }
    public var canStop: Bool { phase == .listening }
    public var canAsk: Bool { phase == .listening }

    /// The user pressed Start. Clears the previous call from the screen.
    public mutating func beginStarting() {
        self = CallViewState()
        phase = .starting
    }

    public mutating func startFailed(_ message: String) {
        phase = .idle
        listeningSince = nil
        addNotice(.error, message)
    }

    /// The user pressed Stop.
    public mutating func beginStopping() {
        if phase == .listening {
            phase = .stopping
        }
    }

    /// The event stream ended without `.stopped`, so the call was not saved.
    public mutating func eventsEnded() {
        if phase == .listening || phase == .stopping || phase == .summarizing {
            finish(directory: nil)
        }
    }

    /// Hides the answer card. Returns the answer's ID if it was still streaming, so
    /// the caller can cancel the request.
    @discardableResult
    public mutating func dismissAnswer() -> Int? {
        defer { answer = nil }
        return answer?.isActive == true ? answer?.id : nil
    }

    public mutating func dismissNotice(id: Int) {
        noticeList.dismiss(id: id)
    }

    public mutating func addNotice(_ kind: Notice.Kind, _ message: String, action: NoticeAction? = nil) {
        noticeList.add(kind, message, action: action)
    }

    /// A capture source recovered on its own. Restarts are worth knowing about;
    /// anything that leaves a channel silent is a warning.
    public mutating func apply(_ event: CaptureEvent) {
        switch event {
        case .restarted:
            addNotice(.info, event.description)
        case .restartFailed, .voiceProcessingUnavailable, .stoppedByUser:
            addNotice(.warning, event.description)
        }
    }

    public mutating func apply(_ event: SessionEvent, now: Date) {
        switch event {
        case .started(let channels):
            phase = .listening
            listeningSince = now
            self.channels = channels
        case .transcript(let snapshot):
            updateRows(snapshot)
        case .answerStarted(let id, let tier, let model):
            answer = AnswerCard(id: id, tier: tier, model: model, askedAt: now)
        case .answerText(let id, let delta):
            guard var card = answer, card.id == id else {
                return
            }
            card.text += delta
            card.status = .streaming
            if card.firstTokenMs == nil, !delta.isEmpty {
                card.firstTokenMs = now.timeIntervalSince(card.askedAt) * 1000
            }
            answer = card
        case .answerFinished(let record):
            finishAnswer(record)
        case .answerFailed(let id, let message):
            if answer?.id == id {
                answer?.status = .failed(message)
            }
        case .cost(let summary):
            cost = summary
        case .warning(let message):
            addNotice(.warning, message)
        case .summaryStarted:
            if phase != .finished {
                phase = .summarizing
            }
        case .summaryFinished(let file):
            summaryFile = file
            if phase == .finished, let file {
                addNotice(.info, "The summary is ready.", action: .openFile(path: file))
            }
        case .stopped(let directory):
            finish(directory: directory)
        }
    }

    private mutating func finishAnswer(_ record: AnswerRecord) {
        if let latency = record.latency.hotkeyToFirstToken {
            lastLatencyMs = latency
        }
        guard var card = answer, card.id == record.id else {
            return
        }
        if !record.text.isEmpty {
            card.text = record.text
        }
        card.firstTokenMs = record.latency.hotkeyToFirstToken ?? card.firstTokenMs
        card.cost = record.cost
        card.status = record.error.map(AnswerCard.Status.failed) ?? .finished
        answer = card
    }

    private mutating func finish(directory: String?) {
        phase = .finished
        listeningSince = nil
        rows.removeAll(where: \.isInterim)
        interimOrder = []
        sessionDirectory = directory
        if answer?.isActive == true {
            answer = nil
        }
        guard let directory else {
            addNotice(.error, "The call could not be saved.")
            return
        }
        let name = URL(fileURLWithPath: directory).lastPathComponent
        if let summaryFile {
            addNotice(.info, "Call saved as \(name), with a summary.", action: .openFile(path: summaryFile))
        } else {
            addNotice(.info, "Call saved as \(name).", action: .revealInFinder(path: directory))
        }
    }

    private mutating func updateRows(_ snapshot: TranscriptSnapshot) {
        let speaking = Set(snapshot.interim.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }.keys)
        interimOrder.removeAll { !speaking.contains($0) }
        for speaker in Speaker.allCases where speaking.contains(speaker) && !interimOrder.contains(speaker) {
            interimOrder.append(speaker)
        }

        var rows: [TranscriptRow] = []
        rows.reserveCapacity(snapshot.turns.count + interimOrder.count)
        var previous: Speaker?
        for turn in snapshot.turns {
            rows.append(
                TranscriptRow(
                    id: .turn(turn.id), speaker: turn.speaker, text: turn.text, isInterim: false,
                    showsSpeaker: turn.speaker != previous, start: turn.start))
            previous = turn.speaker
        }
        for speaker in interimOrder {
            let text = snapshot.interim[speaker, default: ""].trimmingCharacters(in: .whitespaces)
            rows.append(
                TranscriptRow(
                    id: .interim(speaker), speaker: speaker, text: text, isInterim: true,
                    showsSpeaker: speaker != previous, start: nil))
            previous = speaker
        }
        self.rows = rows
    }
}
