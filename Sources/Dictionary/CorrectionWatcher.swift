import Foundation

// Correction watcher core (DESIGN §3.5). Accessibility is reached only through
// `TextFieldReader`; the app supplies the AX implementation and tests a fake.
// Text read here stays in the session record and local variables, is cleared
// on finalize or discard, and is never logged, persisted or transmitted.

/// An opaque destination: the process and its focused text element.
struct TextFieldTarget {
    let pid: Int32
    let element: AnyObject
}

/// UTF-16 offsets, as Accessibility reports them.
struct TextFieldRange: Equatable {
    let location: Int
    let length: Int
}

enum TextFieldCheck: Equatable {
    case ok, focusChanged, secure, failed
}

/// Bounded reads of one text field. Implementations never read the whole value.
protocol TextFieldReader: AnyObject {
    func isTrusted() -> Bool
    /// The frontmost app's focused element if it is another app's editable text
    /// area, text field or combo box, and not a secure field.
    func captureFocusedTextField() -> TextFieldTarget?
    /// Same process and an equal focused element, still not secure.
    func check(_ target: TextFieldTarget) -> TextFieldCheck
    func characterCount(_ target: TextFieldTarget) -> Int?
    func selectedRange(_ target: TextFieldTarget) -> TextFieldRange?
    /// The text in `range`, or nil when unsupported or on any error.
    func string(_ target: TextFieldTarget, range: TextFieldRange) -> String?
}

enum CorrectionDiscardReason: Error, Equatable {
    case notTrusted, focusChanged, secureField, readFailed, pasteNotAtCaret, tooLong
    case startMoved, endNotFound, endAmbiguous, spanChangedTooMuch, spanRemoved, timeout, cancelled

    /// Stops that forbid using text already read: the watch was cancelled,
    /// permission was withdrawn, or the field turned secure. Every other stop
    /// only means the field can no longer be followed.
    var forbidsCapturedText: Bool {
        self == .cancelled || self == .notTrusted || self == .secureField
    }
}

enum CorrectionAnchor: Equatable {
    /// The span touches the start (before) or end (after) of the document.
    case documentEdge
    case text([UInt16])

    var units: [UInt16] {
        if case .text(let units) = self { return units }
        return []
    }
}

struct CorrectionSpanRecord {
    var spanStart = 0
    var spanLength = 0
    var before = CorrectionAnchor.documentEdge
    var after = CorrectionAnchor.documentEdge
    var pasted: [UInt16] = []
}

struct CorrectionEdit: Equatable {
    let typed: String
    let edited: String
    let dictationID: UInt64

    static func == (lhs: CorrectionEdit, rhs: CorrectionEdit) -> Bool {
        DictionaryText.same(lhs.typed, rhs.typed) && DictionaryText.same(lhs.edited, rhs.edited)
            && lhs.dictationID == rhs.dictationID
    }
}

enum CorrectionPollOutcome: Equatable {
    case watching
    /// An edit unchanged for the quiet period: check it and keep watching.
    case settled(CorrectionEdit)
    /// The watch ended with an edit that was not checked yet.
    case finalize(CorrectionEdit)
    case discard(CorrectionDiscardReason)
}

/// One watched paste. Deterministic: time is passed in, and every read goes
/// through the reader. Used on one queue only.
final class CorrectionWatchSession {
    static let contextUnits = 40
    static let maxGrowth = 200
    static let maxPastedUnits = 4097  // 4096 bytes of output plus the trailing space
    static let beginWindowLimit = 4200
    static let pollWindowLimit = 4600
    static let quietPeriod: TimeInterval = 1.5
    static let maxDuration: TimeInterval = 60
    /// Edits reported per paste; the last one ends the watch.
    static let maxChecks = 3

    private let reader: TextFieldReader
    private let target: TextFieldTarget
    private let dictationID: UInt64
    private let startTime: TimeInterval
    private var typed: String
    private var lastSpan: [UInt16]
    private var lastChange: TimeInterval
    private var cancelled = false
    /// Thread-safe: true once the watch was cancelled from another thread.
    private let isCancelled: () -> Bool
    /// Live time for the deadline check before each read; nil uses the poll's time.
    private let clock: (() -> TimeInterval)?
    private var pollTime: TimeInterval
    /// The edited text from the last read inside the window.
    private var lastEdited: String
    /// The span last reported for checking, initially the paste itself.
    private var reported: [UInt16]
    private var reports = 0
    private var outcome: CorrectionPollOutcome?
    private(set) var record: CorrectionSpanRecord

    var isFinished: Bool { outcome != nil }

    private init(reader: TextFieldReader, target: TextFieldTarget, typed: String, record: CorrectionSpanRecord,
                 dictationID: UInt64, now: TimeInterval, isCancelled: @escaping () -> Bool, clock: (() -> TimeInterval)?) {
        self.isCancelled = isCancelled
        self.clock = clock
        pollTime = now
        lastEdited = typed
        self.reader = reader
        self.target = target
        self.typed = typed
        self.record = record
        self.dictationID = dictationID
        startTime = now
        lastChange = now
        lastSpan = record.pasted
        reported = record.pasted
    }

    /// Reads just after the paste: the pasted text must end exactly at an empty
    /// selection. Records the span and up to 40 units of context on each side.
    static func begin(reader: TextFieldReader, target: TextFieldTarget, pasted: String, dictationID: UInt64,
                      now: TimeInterval, isCancelled: @escaping () -> Bool = { false },
                      clock: (() -> TimeInterval)? = nil) -> Result<CorrectionWatchSession, CorrectionDiscardReason> {
        let units = Array(pasted.utf16)
        guard !units.isEmpty else { return .failure(.pasteNotAtCaret) }
        guard units.count <= maxPastedUnits else { return .failure(.tooLong) }
        let count: Int, selection: TextFieldRange, window: (text: String, units: [UInt16])
        let caret: Int, spanStart: Int
        do {
            count = try guardedRead(reader, target, isCancelled, { false }) { reader.characterCount(target) }
            selection = try guardedRead(reader, target, isCancelled, { false }) { reader.selectedRange(target) }
            guard count >= 0, selection.length == 0, selection.location >= units.count, selection.location <= count else {
                return .failure(.pasteNotAtCaret)
            }
            caret = selection.location
            spanStart = caret - units.count
            let windowStart = max(0, spanStart - contextUnits)
            let windowEnd = min(count, caret + contextUnits)
            guard windowEnd - windowStart <= beginWindowLimit else { return .failure(.tooLong) }
            window = try guardedRead(reader, target, isCancelled, { false }) { read(reader: reader, target: target, from: windowStart, to: windowEnd) }
        } catch {
            return .failure(error as? CorrectionDiscardReason ?? .readFailed)
        }
        let local = spanStart - max(0, spanStart - contextUnits)
        guard window.units[local..<local + units.count].elementsEqual(units) else { return .failure(.pasteNotAtCaret) }
        var record = CorrectionSpanRecord()
        record.spanStart = spanStart
        record.spanLength = units.count
        record.before = spanStart == 0 ? .documentEdge : .text(Array(window.units[..<local]))
        record.after = caret == count ? .documentEdge : .text(Array(window.units[(local + units.count)...]))
        record.pasted = units
        return .success(CorrectionWatchSession(reader: reader, target: target, typed: pasted, record: record,
                                               dictationID: dictationID, now: now, isCancelled: isCancelled, clock: clock))
    }

    /// Setting off, permission withdrawn by the app, a new dictation, a
    /// dictionary change or quitting: discard without finalizing.
    func cancel() { cancelled = true }

    func poll(now: TimeInterval) -> CorrectionPollOutcome {
        if let outcome { return outcome }
        if cancelled || isCancelled() { return finish(.discard(.cancelled)) }
        pollTime = now
        // Past the 60 s window nothing is read again, however late the poll runs.
        if isExpired() { return finish(expire()) }
        let span: [UInt16]
        let edited: String
        do {
            (span, edited) = try locate()
        } catch CorrectionDiscardReason.timeout {
            return finish(expire())
        } catch {
            return finish(end(error as? CorrectionDiscardReason ?? .readFailed))
        }
        // The whole paste is gone, as when a chat field clears on send.
        if span.isEmpty { return finish(end(.spanRemoved)) }
        if span != lastSpan {
            lastSpan = span
            lastEdited = edited
            lastChange = now
        }
        if hasUncheckedEdit && now - lastChange >= Self.quietPeriod { return report() }
        if isExpired() { return finish(expire()) }
        return .watching
    }

    private func isExpired() -> Bool {
        (clock?() ?? pollTime) - startTime >= Self.maxDuration
    }

    /// The last edit read differs from the paste and from the last report.
    private var hasUncheckedEdit: Bool { lastSpan != record.pasted && lastSpan != reported }

    private var lastEdit: CorrectionEdit { CorrectionEdit(typed: typed, edited: lastEdited, dictationID: dictationID) }

    /// Reports the current edit for checking. The last allowed report ends the watch.
    private func report() -> CorrectionPollOutcome {
        reported = lastSpan
        reports += 1
        return reports >= Self.maxChecks ? finish(.finalize(lastEdit)) : .settled(lastEdit)
    }

    /// The watch can go no further. Unless the stop forbids it, an edit read
    /// earlier and not checked yet is finalized from memory; nothing new is read.
    private func end(_ reason: CorrectionDiscardReason) -> CorrectionPollOutcome {
        !reason.forbidsCapturedText && hasUncheckedEdit ? .finalize(lastEdit) : .discard(reason)
    }

    /// At the deadline: the same safety checks as before any read (metadata
    /// only; text is never requested past the deadline). A field that turned
    /// secure or lost permission is discarded; one that lost focus still
    /// finalizes text captured inside the window.
    private func expire() -> CorrectionPollOutcome {
        if cancelled || isCancelled() { return .discard(.cancelled) }
        return end(Self.safetyCheck(reader: reader, target: target) ?? .timeout)
    }

    /// Deterministic span tracking: the before context still sits right before
    /// the span (or the span starts the document), and the after context occurs
    /// exactly once from the span start on, within 200 units of growth or
    /// shrinkage (or the span runs to the end of the document).
    private func locate() throws -> ([UInt16], String) {
        let (reader, target) = (self.reader, self.target)
        let count = try Self.guardedRead(reader, target, isCancelled, isExpired) { reader.characterCount(target) }
        let before = record.before.units, after = record.after.units
        guard count >= 0 else { throw CorrectionDiscardReason.readFailed }
        guard count >= record.spanStart else { throw CorrectionDiscardReason.startMoved }
        let windowStart = record.spanStart - before.count
        let windowEnd = min(count, record.spanStart + record.spanLength + Self.maxGrowth + after.count)
        guard windowEnd - windowStart <= Self.pollWindowLimit else { throw CorrectionDiscardReason.tooLong }
        let window = try Self.guardedRead(reader, target, isCancelled, isExpired) {
            Self.read(reader: reader, target: target, from: windowStart, to: windowEnd)
        }
        let units = window.units
        guard units.count >= before.count, units[..<before.count].elementsEqual(before) else {
            throw CorrectionDiscardReason.startMoved
        }

        let newLength: Int
        if record.after == .documentEdge {
            newLength = count - record.spanStart
        } else {
            var found: [Int] = []
            if units.count - after.count >= before.count {
                for start in before.count...(units.count - after.count)
                where units[start..<start + after.count].elementsEqual(after) {
                    found.append(start)
                    if found.count > 1 { throw CorrectionDiscardReason.endAmbiguous }
                }
            }
            guard let end = found.first else { throw CorrectionDiscardReason.endNotFound }
            newLength = end - before.count
        }
        guard abs(newLength - record.spanLength) <= Self.maxGrowth else { throw CorrectionDiscardReason.spanChangedTooMuch }
        let range = NSRange(location: before.count, length: newLength)
        guard let stringRange = Range(range, in: window.text) else { throw CorrectionDiscardReason.readFailed }
        let edited = String(window.text[stringRange])
        let span = Array(units[before.count..<before.count + newLength])
        guard Self.isValidUTF16(span), Array(edited.utf16) == span else { throw CorrectionDiscardReason.readFailed }
        return (span, edited)
    }

    /// Every read is preceded by the safety check, so a field that turns
    /// secure or loses focus is never read again. Cancellation is checked
    /// immediately before the check and again before the read itself, so a
    /// cancel that lands during an in-flight AX call stops the next one.
    private static func guardedRead<T>(_ reader: TextFieldReader, _ target: TextFieldTarget,
                                       _ isCancelled: () -> Bool, _ isExpired: () -> Bool,
                                       _ read: () -> T?) throws -> T {
        func stopIfNeeded() throws {
            if isCancelled() { throw CorrectionDiscardReason.cancelled }
            if isExpired() { throw CorrectionDiscardReason.timeout }
        }
        try stopIfNeeded()
        if let reason = safetyCheck(reader: reader, target: target) { throw reason }
        try stopIfNeeded()
        guard let value = read() else { throw CorrectionDiscardReason.readFailed }
        return value
    }

    private func finish(_ outcome: CorrectionPollOutcome) -> CorrectionPollOutcome {
        self.outcome = outcome
        record = CorrectionSpanRecord()
        lastSpan = []
        reported = []
        typed = ""
        lastEdited = ""
        return outcome
    }

    /// Before every read: permission, the same destination, and no secure subrole.
    private static func safetyCheck(reader: TextFieldReader, target: TextFieldTarget) -> CorrectionDiscardReason? {
        guard reader.isTrusted() else { return .notTrusted }
        switch reader.check(target) {
        case .ok: return nil
        case .focusChanged: return .focusChanged
        case .secure: return .secureField
        case .failed: return .readFailed
        }
    }

    private static func read(reader: TextFieldReader, target: TextFieldTarget, from start: Int,
                             to end: Int) -> (text: String, units: [UInt16])? {
        guard start >= 0, end >= start,
              let text = reader.string(target, range: TextFieldRange(location: start, length: end - start)) else { return nil }
        let units = Array(text.utf16)
        return units.count == end - start ? (text, units) : nil
    }

    static func isValidUTF16(_ units: [UInt16]) -> Bool {
        var iterator = units.makeIterator()
        var decoder = UTF16()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }
}

/// Monotonic generation shared between the main thread and the AX queue, so
/// work from a cancelled watch is ignored even while a read is in flight.
final class CorrectionWatchGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    @discardableResult
    func advance() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    var current: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value == generation
    }

    /// Advances only if `generation` is still current; returns the new value.
    func advance(from generation: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard value == generation else { return nil }
        value += 1
        return value
    }
}

struct CorrectionCapture {
    let target: TextFieldTarget
    let generation: UInt64
}

/// Runs one session at a time on a dedicated serial queue: one read in
/// flight, a 0.5 s poll for at most 60 s, no observers. `onEdit` runs on the
/// main thread, only for the current generation; `isLast` is true when the
/// watch has ended.
final class CorrectionWatcher: @unchecked Sendable {
    static let captureDeadline: TimeInterval = 0.3
    static let settleDelay: TimeInterval = 0.15
    static let pollInterval: TimeInterval = 0.5

    private let reader: TextFieldReader
    private let queue = DispatchQueue(label: "localflow.correction-watcher", qos: .utility)
    private let generation = CorrectionWatchGeneration()
    // Queue-only state.
    private var session: CorrectionWatchSession?
    private var timer: DispatchSourceTimer?

    /// Main thread only. `watch` is the generation of the watch that read the
    /// edit: `claim(watch)` before using a result for it.
    var onEdit: ((_ edit: CorrectionEdit, _ isLast: Bool, _ watch: UInt64) -> Void)?
    /// Main thread only: the field turned secure or permission was lost, so
    /// edits already reported must not be used. The watch's generation was
    /// already made stale on the watcher's queue; the app stops their checks.
    var onAbandon: (() -> Void)?

    init(reader: TextFieldReader) {
        self.reader = reader
    }

    /// The generation a finished dictation's paste is bound to. Any cancel
    /// (new recording, setting off, dictionary change, quit) makes it stale.
    var currentGeneration: UInt64 { generation.current }

    func isCurrent(_ token: UInt64) -> Bool { generation.isCurrent(token) }

    /// Captures the destination just before the paste is posted, only if
    /// `expected` (the generation when the dictation finished) is still current;
    /// a stale context gets nil at once and touches nothing. `completion` runs
    /// once on the main thread, within the deadline, so the paste is never held
    /// up by a slow application.
    func capture(expecting expected: UInt64, completion: @escaping (CorrectionCapture?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard generation.isCurrent(expected) else {
            completion(nil)
            return
        }
        let token = generation.advance()
        stopOnQueue()
        var delivered = false
        let deliver: (CorrectionCapture?) -> Void = { capture in
            guard !delivered else { return }
            delivered = true
            completion(capture)
        }
        queue.async { [reader, generation] in
            let target = generation.isCurrent(token) && reader.isTrusted() ? reader.captureFocusedTextField() : nil
            DispatchQueue.main.async {
                deliver(target.map { CorrectionCapture(target: $0, generation: token) })
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDeadline) {
            deliver(nil)
        }
    }

    /// Begins watching about 150 ms after the paste was posted.
    func start(_ capture: CorrectionCapture, pasted: String, dictationID: UInt64) {
        queue.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, self.generation.isCurrent(capture.generation) else { return }
            let begun = CorrectionWatchSession.begin(reader: self.reader, target: capture.target, pasted: pasted,
                                                     dictationID: dictationID, now: ProcessInfo.processInfo.systemUptime,
                                                     isCancelled: { [generation = self.generation] in !generation.isCurrent(capture.generation) },
                                                     clock: { ProcessInfo.processInfo.systemUptime })
            guard case .success(let session) = begun else { return }
            self.session = session
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll(generation: capture.generation) }
            self.timer = timer
            timer.resume()
        }
    }

    /// Discards without finalizing. Safe from any thread.
    func cancel() {
        generation.advance()
        stopOnQueue()
    }

    /// Ends watch `watch` to use a result for it, in one atomic step: false,
    /// changing nothing, if that watch is no longer current (abandoned on its
    /// queue, or cancelled). Safe from any thread.
    func claim(_ watch: UInt64) -> Bool {
        guard generation.advance(from: watch) != nil else { return false }
        stopOnQueue()
        return true
    }

    private func stopOnQueue() {
        queue.async { [weak self] in
            self?.session?.cancel()
            self?.session = nil
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func poll(generation token: UInt64) {
        guard generation.isCurrent(token), let session else {
            session?.cancel()
            session = nil
            timer?.cancel()
            timer = nil
            return
        }
        let delivery: (edit: CorrectionEdit, isLast: Bool)?
        var abandon = false
        switch session.poll(now: ProcessInfo.processInfo.systemUptime) {
        case .watching: return
        case .settled(let edit): delivery = (edit, false)
        case .finalize(let edit): delivery = (edit, true)
        case .discard(let reason):
            delivery = nil
            // A cancel comes from the app, which has already stopped everything.
            abandon = reason.forbidsCapturedText && reason != .cancelled
        }
        if delivery?.isLast != false {
            self.session = nil
            timer?.cancel()
            timer = nil
        }
        if abandon {
            // Stale at once, here, so no result for this watch is used even if
            // it reaches the main thread before the callback below.
            guard let abandoned = generation.advance(from: token) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation.isCurrent(abandoned) else { return }
                self.onAbandon?()
            }
        } else if let delivery {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation.isCurrent(token) else { return }
                self.onEdit?(delivery.edit, delivery.isLast, token)
            }
        }
    }
}
