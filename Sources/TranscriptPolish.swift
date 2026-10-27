import Foundation

// The optional, experimental cleanup pass on Apple's on-device model, apart
// from the model itself (AppleIntelligenceTranscriptPolisher). "Polish" here
// is unrelated to DictationCleanupSteps, which tears a dictation session down.

/// Whether the on-device model can run, and if not, why.
enum TranscriptPolishAvailability: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// Any other reason the system gives.
    case unavailable

    /// Shown under the disabled setting; nil when the model is available.
    var unavailableReason: String? {
        switch self {
        case .available: return nil
        case .deviceNotEligible: return "This Mac does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings to use this."
        case .modelNotReady: return "The Apple Intelligence model is not ready yet (it may still be downloading)."
        case .unavailable: return "Apple Intelligence is not available right now."
        }
    }
}

/// The model behind the pass. Implementations must never log the text.
protocol TranscriptPolisher: Sendable {
    var availability: TranscriptPolishAvailability { get }
    /// Readies the model for the next dictation so its answer starts sooner. Cheap; may do nothing.
    func prewarm()
    /// The model's tidied version of `text`; `hints` are the user's dictionary
    /// words for this app. Reports its call start and first output to
    /// `timings`. Throws on failure and cancellation.
    func polish(_ text: String, hints: [String], timings: TranscriptPolishTimings) async throws -> String
}

/// Re-decodes the dictation's own audio with `phrases` boosted and returns it
/// formatted like the pass's input, or nil when the audio is gone or cannot
/// be re-decoded. Implementations must never log the text.
protocol TranscriptRewriteVerifier: Sendable {
    func redecode(boosting phrases: [String]) async throws -> String?
}

/// What the pass did with one dictation. The raw values appear in the latency log.
enum TranscriptPolishOutcome: String, CaseIterable, Sendable {
    /// The setting is off.
    case off
    /// Nothing to tidy: a macro, a press-enter command alone, or no speech.
    case skipped
    case unavailable
    /// The model's text passed the guard (and the audio check, if it changed words) and is pasted.
    case applied
    /// The model returned the text as it was.
    case unchanged
    /// Empty output, a protected word changed, or a change too long to check.
    case rejectedGuard = "rejected-guard"
    /// A changed word the re-decoded audio did not produce, or no audio to check it with.
    case rejectedAudio = "rejected-audio"
    case timeout
    case error
    case cancelled
}

struct TranscriptPolishResult: Equatable, Sendable {
    /// What to paste: the model's text when applied, otherwise the input exactly.
    let text: String
    let outcome: TranscriptPolishOutcome
    var timings = TranscriptPolishTimings.Summary()
}

/// One difference between the model's words and the input's, as normalized words.
enum TranscriptPolishDifference: Equatable, Sendable {
    case deletion(input: [String])
    case substitution(input: [String], output: [String])
    case insertion(output: [String])
}

/// What the guard decided before any audio check.
enum TranscriptPolishReview: Equatable, Sendable {
    case rejected
    /// Only deletions, punctuation and case: accepted as it is.
    case deletionsOnly
    /// Accepted only if the audio, re-decoded with these new spans boosted, produces them.
    case needsAudio(phrases: [String])
}

/// Word-level alignment of the model's output against its input.
enum TranscriptPolishAlignment {
    struct Word {
        /// Compared: lowercased, canonically composed, without sentence punctuation around it.
        let norm: String
        /// The same word with its case kept, for a boosted phrase.
        let surface: String
    }

    /// One maximal run of differences: input words `input` became output words `output`.
    struct Block {
        let input: Range<Int>
        let output: Range<Int>
    }

    /// Sentence punctuation the model may add, drop or move: quotes on either
    /// side of a word, and the rest only after it, so a sign, decimal point or
    /// flag in front (-5, .5, --force) stays part of the word. Symbols that
    /// carry meaning ($ % # @ & * / brackets, backticks) and any punctuation
    /// inside a word (1,000, don't, well-known, 3:30) are part of it too. A
    /// token of sentence punctuation alone (a dash, an ellipsis) is no word.
    private static let quotes: Set<Character> = ["\"", "'", "“", "”", "„", "«", "»", "‹", "›"]
    private static let trailingPunctuation = quotes.union([".", ",", ";", ":", "!", "?", "…",
                                                           "-", "‐", "‑", "‒", "–", "—", "―"])

    /// Curly apostrophes read as straight ones.
    static func words(in text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let normalized = String(token).precomposedStringWithCanonicalMapping
                .replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "‘", with: "'")
                .replacingOccurrences(of: "ʼ", with: "'")
            guard !normalized.allSatisfy(trailingPunctuation.contains) else { return nil }
            var word = normalized.drop { quotes.contains($0) }
            while let last = word.last, trailingPunctuation.contains(last) { word.removeLast() }
            return word.isEmpty ? nil : Word(norm: word.lowercased(), surface: String(word))
        }
    }

    /// The pinned word-level Levenshtein alignment (WordAlignment), grouped
    /// into maximal runs of differences.
    static func blocks(_ input: [Word], _ output: [Word]) -> [Block] {
        let operations = WordAlignment.align(input.map { Array($0.norm.unicodeScalars) },
                                             output.map { Array($0.norm.unicodeScalars) })
        var blocks: [Block] = []
        var i = 0, j = 0
        var open: (i: Int, j: Int)?
        for operation in operations {
            if case .match = operation {
                if let start = open { blocks.append(Block(input: start.i..<i, output: start.j..<j)) }
                open = nil
                i += 1
                j += 1
                continue
            }
            if open == nil { open = (i, j) }
            switch operation {
            case .substitute: i += 1; j += 1
            case .delete: i += 1
            case .insert: j += 1
            case .match: break
            }
        }
        if let start = open { blocks.append(Block(input: start.i..<i, output: start.j..<j)) }
        return blocks
    }

    static func differences(input: String, output: String) -> [TranscriptPolishDifference] {
        let a = words(in: input), b = words(in: output)
        return blocks(a, b).map { block in
            let old = a[block.input].map(\.norm), new = b[block.output].map(\.norm)
            if new.isEmpty { return .deletion(input: old) }
            return old.isEmpty ? .insertion(output: new) : .substitution(input: old, output: new)
        }
    }
}

/// The deterministic check on the model's output. Deletions, punctuation and
/// case are free. Any other word change (a substitution or an insertion) must
/// involve plain words only, so symbols, numbers, dashed words and apostrophes
/// (spoken-number and delimiter formatting, code, flags, contractions) are
/// never rewritten, and is then accepted only if the dictation's audio
/// supports it (`verified`).
enum TranscriptPolishGuard {
    /// A new span is boosted as one dictionary phrase, which holds at most this many words.
    static let maxPhraseWords = 8

    static func review(input: String, output: String) -> TranscriptPolishReview {
        let a = TranscriptPolishAlignment.words(in: input), b = TranscriptPolishAlignment.words(in: output)
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .rejected
        }
        if b.isEmpty, !a.isEmpty { return .rejected }
        var phrases: [String] = []
        for block in TranscriptPolishAlignment.blocks(a, b) where !block.output.isEmpty {
            let changed = a[block.input] + b[block.output]
            guard block.output.count <= maxPhraseWords, changed.allSatisfy({ isPlain($0.norm) }) else { return .rejected }
            let phrase = b[block.output].map(\.surface).joined(separator: " ")
            if !phrases.contains(phrase) { phrases.append(phrase) }
        }
        return phrases.isEmpty ? .deletionsOnly : .needsAudio(phrases: phrases)
    }

    /// Whether `decoded`, the audio re-decoded with the new spans boosted,
    /// supports every change: read against it, the output is again deletions
    /// only, with each new span whole. Retained words on both sides pin each new
    /// span to where the old words were. False when `review` does not ask for audio.
    static func verified(input: String, output: String, decoded: String) -> Bool {
        guard case .needsAudio = review(input: input, output: output) else { return false }
        let a = TranscriptPolishAlignment.words(in: input), b = TranscriptPolishAlignment.words(in: output)
        let d = TranscriptPolishAlignment.words(in: decoded).map(\.norm)
        // The output in order: each new span as one segment, every other word alone.
        var segments: [[String]] = []
        var next = 0
        for block in TranscriptPolishAlignment.blocks(a, b) where !block.output.isEmpty {
            segments += b[next..<block.output.lowerBound].map { [$0.norm] }
            segments.append(b[block.output].map(\.norm))
            next = block.output.upperBound
        }
        segments += b[next...].map { [$0.norm] }
        // Earliest placement of each segment leaves the most room for the rest.
        var position = 0
        for segment in segments {
            guard let start = (position..<max(position, d.count - segment.count + 1)).first(where: {
                Array(d[$0..<$0 + segment.count]) == segment
            }) else { return false }
            position = start + segment.count
        }
        return true
    }

    /// Letters only: no digit, symbol, dash or inner punctuation. An inner
    /// apostrophe counts as punctuation too: audio cannot tell "its" from "it's".
    private static func isPlain(_ word: String) -> Bool {
        word.allSatisfy(\.isLetter)
    }
}

/// When the model and the audio check ran, filled in while the pass runs and
/// read when it ends, whatever its outcome. Thread-safe.
final class TranscriptPolishTimings: @unchecked Sendable {
    struct Summary: Equatable, Sendable {
        /// From the model call to its first partial output; nil without one.
        var firstOutputMilliseconds: Int?
        /// How long before the model call its warm-up began; nil without a warmed session.
        var prewarmMilliseconds: Int?
        /// The audio check, to its end or to the end of the pass; 0 when not run.
        var verifyMilliseconds = 0
    }

    private let lock = NSLock()
    private var modelStart: ContinuousClock.Instant?
    private var firstOutputAt: ContinuousClock.Instant?
    private var prewarmedFor: Duration?
    private var verifyStart: ContinuousClock.Instant?
    private var verifyEnd: ContinuousClock.Instant?

    func modelStarted(prewarmedFor: Duration?) {
        lock.withLock {
            modelStart = .now
            self.prewarmedFor = prewarmedFor
        }
    }

    func firstOutput() {
        lock.withLock { if firstOutputAt == nil { firstOutputAt = .now } }
    }

    func verifyStarted() { lock.withLock { verifyStart = .now } }
    func verifyEnded() { lock.withLock { verifyEnd = .now } }

    func summary(at now: ContinuousClock.Instant = .now) -> Summary {
        lock.withLock {
            var summary = Summary()
            if let modelStart, let firstOutputAt {
                summary.firstOutputMilliseconds = DictationLatencyReport.milliseconds(firstOutputAt - modelStart)
            }
            summary.prewarmMilliseconds = prewarmedFor.map(DictationLatencyReport.milliseconds)
            if let verifyStart {
                summary.verifyMilliseconds = DictationLatencyReport.milliseconds((verifyEnd ?? now) - verifyStart)
            }
            return summary
        }
    }
}

/// Runs the pass with every fallback: anything but an accepted answer within
/// the budget leaves the text as it was, and the dictation is never held up
/// past the budget or lost.
enum TranscriptPolishRunner {
    /// The model and any audio check together; past this the original text is
    /// pasted and late work is dropped.
    static let latencyBudget: Duration = .seconds(3)

    /// Never throws. On `.cancelled` the caller checks its own cancellation:
    /// a cancelled dictation pastes nothing. Without `verifier` no word change
    /// can be checked, so only deletions can apply.
    static func run(_ text: String, hints: [String] = [], enabled: Bool, polisher: any TranscriptPolisher,
                    verifier: (any TranscriptRewriteVerifier)?, budget: Duration = latencyBudget) async -> TranscriptPolishResult {
        func unchanged(_ outcome: TranscriptPolishOutcome) -> TranscriptPolishResult {
            TranscriptPolishResult(text: text, outcome: outcome)
        }
        guard enabled else { return unchanged(.off) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return unchanged(.skipped) }
        guard polisher.availability == .available else { return unchanged(.unavailable) }
        guard !Task.isCancelled else { return unchanged(.cancelled) }
        let timings = TranscriptPolishTimings()
        let attempt = await attempt(text, hints: hints, polisher: polisher, verifier: verifier, timings: timings, budget: budget)
        var result: TranscriptPolishResult
        switch attempt {
        case .accepted(let output):
            let tidied = output.trimmingCharacters(in: .whitespacesAndNewlines)
            result = tidied == text.trimmingCharacters(in: .whitespacesAndNewlines)
                ? unchanged(.unchanged) : TranscriptPolishResult(text: tidied, outcome: .applied)
        case .rejectedGuard: result = unchanged(.rejectedGuard)
        case .rejectedAudio: result = unchanged(.rejectedAudio)
        case .failed: result = unchanged(.error)
        case .timedOut: result = unchanged(.timeout)
        case .cancelled: result = unchanged(.cancelled)
        }
        result.timings = timings.summary()
        return result
    }

    private enum Attempt: Sendable {
        case accepted(String)
        case rejectedGuard
        case rejectedAudio
        case failed
        case timedOut
        case cancelled
    }

    /// The first of: the checked answer, the budget elapsing, or the caller's
    /// cancellation. It returns at once and does not wait for the model or the
    /// audio check to stop; their task is cancelled and any late result ignored.
    private static func attempt(_ text: String, hints: [String], polisher: any TranscriptPolisher,
                                verifier: (any TranscriptRewriteVerifier)?, timings: TranscriptPolishTimings,
                                budget: Duration) async -> Attempt {
        let race = FirstAttempt()
        // One fixed deadline for the model and the audio check together, so a
        // late-scheduled timer cannot let a late answer in.
        let deadline = ContinuousClock.now + budget
        let work = Task {
            do {
                let output = try await polisher.polish(text, hints: hints, timings: timings)
                guard ContinuousClock.now < deadline else { return race.finish(.timedOut) }
                switch TranscriptPolishGuard.review(input: text, output: output) {
                case .rejected: race.finish(.rejectedGuard)
                case .deletionsOnly: race.finish(.accepted(output))
                case .needsAudio(let phrases):
                    guard let verifier else { return race.finish(.rejectedAudio) }
                    try Task.checkCancellation()
                    timings.verifyStarted()
                    let decoded = try await verifier.redecode(boosting: phrases)
                    timings.verifyEnded()
                    guard ContinuousClock.now < deadline else { return race.finish(.timedOut) }
                    let supported = decoded.map { TranscriptPolishGuard.verified(input: text, output: output, decoded: $0) } ?? false
                    race.finish(supported ? .accepted(output) : .rejectedAudio)
                }
            } catch is CancellationError {
                race.finish(.cancelled)
            } catch {
                race.finish(.failed)
            }
        }
        let timer = Task {
            // A cancelled sleep means the race is already over.
            guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
            race.finish(.timedOut)
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { race.wait(with: $0) }
        } onCancel: {
            race.finish(.cancelled)
        }
        work.cancel()
        timer.cancel()
        return result
    }

    /// Delivers the first result to the waiting continuation exactly once,
    /// whether it arrives before or after the continuation does.
    private final class FirstAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Attempt?
        private var continuation: CheckedContinuation<Attempt, Never>?

        func finish(_ attempt: Attempt) {
            let waiting = lock.withLock { () -> CheckedContinuation<Attempt, Never>? in
                guard result == nil else { return nil }
                result = attempt
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: attempt)
        }

        func wait(with continuation: CheckedContinuation<Attempt, Never>) {
            let ready = lock.withLock { () -> Attempt? in
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// One dictation's timings for the Latency log: numbers, "na" and an outcome
/// name only, never text. Measured on a monotonic clock from the moment
/// recording stopped.
struct DictationLatencyReport: Equatable, Sendable {
    /// Nil when the recording's length could not be read.
    var audioSeconds: Double?
    /// Stop of recording to the final transcript.
    var asrMilliseconds: Int
    /// The whole pass: model and audio check.
    var cleanupMilliseconds: Int
    /// Model call to its first partial output; nil without one.
    var firstOutputMilliseconds: Int?
    /// Warm-up start to the model call; nil when the call had no warmed session.
    var prewarmMilliseconds: Int?
    /// The audio check; 0 when not run.
    var verifyMilliseconds: Int
    var cleanupOutcome: TranscriptPolishOutcome
    /// Characters of the deterministic output, before cleanup.
    var inputCharacters: Int
    /// Characters of the final output (pasted when not empty).
    var outputCharacters: Int
    /// Stop of recording to the paste (or to the result when nothing is pasted).
    var totalMilliseconds: Int

    var logLine: String {
        func optional(_ value: Int?) -> String { value.map(String.init) ?? "na" }
        let audio = audioSeconds.map { String(format: "%.2f", $0) } ?? "na"
        return "audio_s=\(audio) asr_ms=\(asrMilliseconds) cleanup_ms=\(cleanupMilliseconds) "
            + "first_token_ms=\(optional(firstOutputMilliseconds)) prewarm_ms=\(optional(prewarmMilliseconds)) "
            + "verify_ms=\(verifyMilliseconds) cleanup=\(cleanupOutcome.rawValue) chars_in=\(inputCharacters) "
            + "chars_out=\(outputCharacters) total_ms=\(totalMilliseconds)"
    }

    /// Rounded to the nearest millisecond; never negative.
    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        let total = Double(seconds) * 1_000 + Double(attoseconds) / 1e15
        return max(0, Int(total.rounded()))
    }
}
