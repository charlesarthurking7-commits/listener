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
    /// speaker's name once.
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

/// How the last call ended, for the card that replaces the answer card after Stop.
public struct CallOutcome: Sendable, Equatable {
    /// Where the call was saved, or nil if saving failed.
    public var directory: String?
    public var summaryFile: String?
    /// Seconds from the first audio to Stop.
    public var duration: Double?
    public var turnCount: Int
    public var cost: Double

    public init(directory: String?, summaryFile: String?, duration: Double?, turnCount: Int, cost: Double) {
        self.directory = directory
        self.summaryFile = summaryFile
        self.duration = duration
        self.turnCount = turnCount
        self.cost = cost
    }

    /// "12:05 · 48 turns · $0.12".
    public var details: String {
        var parts: [String] = []
        if let duration {
            parts.append(DisplayFormat.clock(duration))
        }
        parts.append(turnCount == 1 ? "1 turn" : "\(turnCount) turns")
        parts.append(DisplayFormat.cost(cost))
        return parts.joined(separator: " · ")
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
    /// Turns that have settled. Only changes when a turn is added or its final text
    /// grows, so the window redraws the long part of the transcript rarely.
    public private(set) var settledRows: [TranscriptRow] = []
    /// What people are saying right now, after the settled rows. Changes many times a
    /// second while someone speaks.
    public private(set) var liveRows: [TranscriptRow] = []
    public private(set) var answer: AnswerCard?
    public private(set) var cost = CostSummary()
    /// Hotkey to first token of the last finished answer, in milliseconds.
    public private(set) var lastLatencyMs: Double?
    private var noticeList = NoticeList()
    public private(set) var sessionDirectory: String?
    public private(set) var summaryFile: String?
    /// Set when a call ends, until it is dismissed or the next call starts.
    public private(set) var outcome: CallOutcome?
    /// Which channels hear speech right now. Nil until the session reports channel
    /// activity, so the window can tell "silent" from "not known".
    public private(set) var hearing: Set<Speaker>?

    private var interimOrder: [Speaker] = []
    private var settledTurns: [Turn] = []

    public init() {}

    public var rows: [TranscriptRow] { settledRows + liveRows }
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
    public mutating func eventsEnded(now: Date = Date()) {
        if phase == .listening || phase == .stopping || phase == .summarizing {
            finish(directory: nil, now: now)
        }
    }

    public mutating func dismissOutcome() {
        outcome = nil
    }

    /// A channel started or stopped hearing speech.
    public mutating func channelActivity(_ speaker: Speaker, isSpeaking: Bool) {
        var hearing = self.hearing ?? []
        if isSpeaking {
            hearing.insert(speaker)
        } else {
            hearing.remove(speaker)
        }
        self.hearing = hearing
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
        case .channelActivity(let speaker, let isSpeaking):
            channelActivity(speaker, isSpeaking: isSpeaking)
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
            outcome?.summaryFile = file
        case .stopped(let directory):
            finish(directory: directory, now: now)
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

    private mutating func finish(directory: String?, now: Date) {
        let duration = listeningSince.map { now.timeIntervalSince($0) }
        phase = .finished
        listeningSince = nil
        liveRows = []
        interimOrder = []
        hearing = nil
        sessionDirectory = directory
        if answer?.isActive == true {
            answer = nil
        }
        guard let directory else {
            addNotice(.error, "The call could not be saved.")
            return
        }
        outcome = CallOutcome(
            directory: directory, summaryFile: summaryFile, duration: duration, turnCount: settledTurns.count,
            cost: cost.total)
    }

    private mutating func updateRows(_ snapshot: TranscriptSnapshot) {
        if snapshot.turns != settledTurns {
            settledTurns = snapshot.turns
            var rows: [TranscriptRow] = []
            rows.reserveCapacity(snapshot.turns.count)
            var previous: Speaker?
            for turn in snapshot.turns {
                rows.append(
                    TranscriptRow(
                        id: .turn(turn.id), speaker: turn.speaker, text: turn.text, isInterim: false,
                        showsSpeaker: turn.speaker != previous, start: turn.start))
                previous = turn.speaker
            }
            settledRows = rows
        }

        let speaking = Set(snapshot.interim.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }.keys)
        interimOrder.removeAll { !speaking.contains($0) }
        for speaker in Speaker.allCases where speaking.contains(speaker) && !interimOrder.contains(speaker) {
            interimOrder.append(speaker)
        }
        var live: [TranscriptRow] = []
        var previous = settledRows.last?.speaker
        for speaker in interimOrder {
            let text = snapshot.interim[speaker, default: ""].trimmingCharacters(in: .whitespaces)
            live.append(
                TranscriptRow(
                    id: .interim(speaker), speaker: speaker, text: text, isInterim: true,
                    showsSpeaker: speaker != previous, start: nil))
            previous = speaker
        }
        if live != liveRows {
            liveRows = live
        }
    }
}
