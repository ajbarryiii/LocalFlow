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
    /// The model's tidied version of `text`. Throws on failure and cancellation.
    func polish(_ text: String) async throws -> String
}

/// What the pass did with one dictation. The raw values appear in the latency log.
enum TranscriptPolishOutcome: String, CaseIterable, Sendable {
    /// The setting is off.
    case off
    /// Nothing to tidy: a macro, a press-enter command alone, or no speech.
    case skipped
    case unavailable
    /// The model's text passed the guard and is pasted.
    case applied
    /// The model returned the text as it was.
    case unchanged
    case rejectedGuard = "rejected-guard"
    case timeout
    case error
    case cancelled
}

struct TranscriptPolishResult: Equatable, Sendable {
    /// What to paste: the model's text when applied, otherwise the input exactly.
    let text: String
    let outcome: TranscriptPolishOutcome
}

/// The deterministic check on the model's output. It is accepted only when
/// its words are the input's words in order with some deleted: punctuation
/// around words and letter case may change, but no word may be added,
/// reordered or respelled. That keeps dictionary spellings, spoken-number and
/// delimiter formatting, and voice-macro text intact, and turns any answer,
/// obeyed instruction or hallucination into a rejection.
enum TranscriptPolishGuard {
    /// Sentence punctuation the model may add, drop or move at a word's edges.
    /// Symbols that carry meaning ($ % # @ & * / brackets, backticks) and any
    /// punctuation inside a word (1,000, don't, well-known, 3:30) are part of it.
    private static let sentencePunctuation = CharacterSet(charactersIn: ".,;:!?…\"'“”„«»‹›-‐‑‒–—―")

    static func accepts(input: String, output: String) -> Bool {
        let inputWords = words(in: input), outputWords = words(in: output)
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if outputWords.isEmpty, !inputWords.isEmpty { return false }
        var remaining = inputWords[...]
        for word in outputWords {
            guard let match = remaining.firstIndex(of: word) else { return false }
            remaining = remaining[remaining.index(after: match)...]
        }
        return true
    }

    /// Lowercased, canonically composed words without the sentence punctuation
    /// at their edges; curly apostrophes read as straight ones.
    static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { token in
            let word = String(token).precomposedStringWithCanonicalMapping.lowercased()
                .replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "‘", with: "'")
                .replacingOccurrences(of: "ʼ", with: "'")
                .trimmingCharacters(in: sentencePunctuation)
            return word.isEmpty ? nil : word
        }
    }
}

/// Runs the pass with every fallback: anything but an accepted answer within
/// the budget leaves the text as it was, and the dictation is never held up
/// past the budget or lost.
enum TranscriptPolishRunner {
    /// Past this the original text is pasted and the model's late answer is dropped.
    static let latencyBudget: Duration = .seconds(3)

    /// Never throws. On `.cancelled` the caller checks its own cancellation:
    /// a cancelled dictation pastes nothing.
    static func run(_ text: String, enabled: Bool, polisher: any TranscriptPolisher,
                    budget: Duration = latencyBudget) async -> TranscriptPolishResult {
        func unchanged(_ outcome: TranscriptPolishOutcome) -> TranscriptPolishResult {
            TranscriptPolishResult(text: text, outcome: outcome)
        }
        guard enabled else { return unchanged(.off) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return unchanged(.skipped) }
        guard polisher.availability == .available else { return unchanged(.unavailable) }
        guard !Task.isCancelled else { return unchanged(.cancelled) }
        switch await attempt(text, polisher: polisher, budget: budget) {
        case .answered(let output):
            guard TranscriptPolishGuard.accepts(input: text, output: output) else { return unchanged(.rejectedGuard) }
            let tidied = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return tidied == text.trimmingCharacters(in: .whitespacesAndNewlines)
                ? unchanged(.unchanged) : TranscriptPolishResult(text: tidied, outcome: .applied)
        case .failed: return unchanged(.error)
        case .timedOut: return unchanged(.timeout)
        case .cancelled: return unchanged(.cancelled)
        }
    }

    private enum Attempt: Sendable {
        case answered(String)
        case failed
        case timedOut
        case cancelled
    }

    /// The first of: the model's answer, the budget elapsing, or the caller's
    /// cancellation. It returns at once and does not wait for the model to
    /// stop; the model's task is cancelled and its late answer ignored.
    private static func attempt(_ text: String, polisher: any TranscriptPolisher, budget: Duration) async -> Attempt {
        let race = FirstAttempt()
        let model = Task {
            do { race.finish(.answered(try await polisher.polish(text))) } catch is CancellationError {
                race.finish(.cancelled)
            } catch {
                race.finish(.failed)
            }
        }
        let timer = Task {
            // A cancelled sleep means the race is already over.
            guard (try? await Task.sleep(for: budget)) != nil else { return }
            race.finish(.timedOut)
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { race.wait(with: $0) }
        } onCancel: {
            race.finish(.cancelled)
        }
        model.cancel()
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

/// One dictation's timings for the Latency log: numbers and an outcome name
/// only, never text. Measured on a monotonic clock from the moment recording
/// stopped.
struct DictationLatencyReport: Equatable, Sendable {
    /// Nil when the recording's length could not be read.
    var audioSeconds: Double?
    /// Stop of recording to the final transcript.
    var asrMilliseconds: Int
    var cleanupMilliseconds: Int
    var cleanupOutcome: TranscriptPolishOutcome
    /// Characters of the deterministic output, before cleanup.
    var inputCharacters: Int
    /// Characters of the final output (pasted when not empty).
    var outputCharacters: Int
    /// Stop of recording to the paste (or to the result when nothing is pasted).
    var totalMilliseconds: Int

    var logLine: String {
        let audio = audioSeconds.map { String(format: "%.2f", $0) } ?? "na"
        return "audio_s=\(audio) asr_ms=\(asrMilliseconds) cleanup_ms=\(cleanupMilliseconds) "
            + "cleanup=\(cleanupOutcome.rawValue) chars_in=\(inputCharacters) chars_out=\(outputCharacters) "
            + "total_ms=\(totalMilliseconds)"
    }

    /// Rounded to the nearest millisecond; never negative.
    static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        let total = Double(seconds) * 1_000 + Double(attoseconds) / 1e15
        return max(0, Int(total.rounded()))
    }
}
