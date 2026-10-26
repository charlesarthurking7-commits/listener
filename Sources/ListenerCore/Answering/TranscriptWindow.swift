/// Token counts for budgeting, erring on the high side. The tokenizer of Haiku 5.5
/// and Sonnet 5.5 produces about 30% more tokens than earlier Claude models, which
/// puts English at roughly three bytes per token.
public enum TokenEstimate {
    public static let bytesPerToken = 3

    public static func tokens(in text: String) -> Int {
        tokens(bytes: text.utf8.count)
    }

    public static func tokens(bytes: Int) -> Int {
        (bytes + bytesPerToken - 1) / bytesPerToken
    }
}

/// The newest part of the transcript that fits the token budget, rendered as
/// `[mm:ss-mm:ss] Speaker: text` lines and split into prompt blocks.
///
/// The window is a pure function of the turn list, and it is built so that
/// consecutive requests share a byte-identical prefix for prompt caching:
///
/// - The start never slides turn by turn. Checkpoints sit every quarter budget of
///   cumulative transcript tokens, counted from the first turn of the call, and the
///   window starts at the earliest checkpoint from which the rest still fits. Between
///   jumps from one checkpoint to a later one, the window only grows at the end.
/// - Blocks break at finer checkpoints of about 512 tokens. Every block except the last
///   is complete: no later turn can join it, so it reappears unchanged in later windows
///   and a cache breakpoint on it is found again by the next request. Only the last
///   block grows.
///
/// Both kinds of checkpoint depend only on the turns before them, so they hold as long
/// as earlier turns don't change. The last turn may still grow; it is always in the last block.
public struct TranscriptWindow: Sendable, Equatable {
    /// Rendered turns, oldest first, one string per prompt block. Empty when there are no turns.
    public var blocks: [String]
    /// Index of the oldest turn included. Greater than zero when earlier turns were left out.
    public var firstTurnIndex: Int
    public var estimatedTokens: Int

    /// Block boundaries aim for about this many tokens, the smallest prefix the
    /// current models will cache.
    static let blockTokens = 512

    public init(turns: [Turn], budgetTokens: Int, hardCapTokens: Int) {
        let budget = max(1, min(budgetTokens, hardCapTokens))
        let step = max(1, budget / 4)
        let blocksPerStep = max(1, (step + Self.blockTokens - 1) / Self.blockTokens)

        // Every turn is counted on every request, so count without rendering.
        var offsets: [Int] = []
        offsets.reserveCapacity(turns.count)
        var total = 0
        for turn in turns {
            offsets.append(total)
            total += Self.estimatedTokens(for: turn)
        }

        let start = Self.start(offsets: offsets, total: total, budget: budget, step: step)
        var lines = turns[start...].map { Self.line(for: $0) }
        var tokens = total - (offsets.isEmpty ? 0 : offsets[start])
        if lines.count == 1, tokens > hardCapTokens, let last = turns.last {
            // A single turn longer than the hard cap, e.g. a long monologue: keep its end.
            lines[0] = Self.line(for: last, maxTokens: max(1, hardCapTokens))
            tokens = TokenEstimate.tokens(in: lines[0])
        }

        var blocks: [String] = []
        var currentBlock = -1
        for (index, line) in zip(start..., lines) {
            let block = offsets[index] * blocksPerStep / step
            if block != currentBlock {
                blocks.append("")
                currentBlock = block
            }
            blocks[blocks.count - 1] += line
        }

        self.blocks = blocks
        self.firstTurnIndex = start
        self.estimatedTokens = tokens
    }

    public var omitsEarlierTurns: Bool { firstTurnIndex > 0 }

    /// One transcript line, newline included.
    public static func line(for turn: Turn) -> String {
        "\(span(turn)) \(turn.speaker.rawValue): \(flatten(turn.text))\n"
    }

    /// Tokens of `line(for:)`. Counts the raw text, which is never shorter than the
    /// rendered text, so the estimate stays on the high side.
    public static func estimatedTokens(for turn: Turn) -> Int {
        let separators = 4  // " ", ": " and the newline
        let bytes =
            span(turn).utf8.count + turn.speaker.rawValue.utf8.count + turn.text.utf8.count + separators
        return TokenEstimate.tokens(bytes: bytes)
    }

    /// `[mm:ss]` in session time. Minutes keep counting past an hour.
    public static func timestamp(_ seconds: Double) -> String {
        "[\(clock(seconds))]"
    }

    /// When a turn was said, `[mm:ss-mm:ss]`, or `[mm:ss]` when it starts and ends in
    /// the same second. The end shows that a short reply fell inside a longer turn
    /// above it, since turns are in order of start.
    static func span(_ turn: Turn) -> String {
        let start = clock(turn.start)
        let end = clock(turn.end)
        return start == end ? "[\(start)]" : "[\(start)-\(end)]"
    }

    private static func clock(_ seconds: Double) -> String {
        let whole = seconds.isFinite ? max(0, Int(seconds)) : 0
        let minutes = whole / 60
        let remainder = whole % 60
        return "\(minutes < 10 ? "0" : "")\(minutes):\(remainder < 10 ? "0" : "")\(remainder)"
    }

    /// The first checkpoint turn from which the rest fits the budget.
    ///
    /// With turns shorter than a step there is always a checkpoint less than two steps
    /// after the oldest turn that fits. A longer turn can push it further, which could
    /// throw away most of the budget, possibly the question itself; the window then
    /// starts at the oldest turn that fits. When even the last turn alone is too long,
    /// it starts at the last turn.
    private static func start(offsets: [Int], total: Int, budget: Int, step: Int) -> Int {
        let required = total - budget
        guard required > 0 else {
            return 0
        }
        guard let oldestFit = offsets.firstIndex(where: { $0 >= required }) else {
            return max(0, offsets.count - 1)
        }
        for index in oldestFit..<offsets.count {
            if offsets[index] - offsets[oldestFit] >= 2 * step {
                break
            }
            if offsets[index - 1] / step != offsets[index] / step {
                return index
            }
        }
        return oldestFit
    }

    private static func line(for turn: Turn, maxTokens: Int) -> String {
        let prefix = "\(span(turn)) \(turn.speaker.rawValue): ... "
        let maxBytes = max(0, maxTokens * TokenEstimate.bytesPerToken - prefix.utf8.count - 1)
        let text = flatten(turn.text)
        var start = text.endIndex
        var bytes = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            bytes += text[previous].utf8.count
            if bytes > maxBytes {
                break
            }
            start = previous
        }
        return prefix + text[start...] + "\n"
    }

    private static func flatten(_ text: String) -> String {
        text.contains(where: \.isNewline) ? text.split(whereSeparator: \.isNewline).joined(separator: " ") : text
    }
}
