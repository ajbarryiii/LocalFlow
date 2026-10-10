import Foundation

/// Typing timing, in one place so measured values drop in with a one-line change.
/// - `shiftDoubleTapInterval`: two shift taps this close turn on caps lock. 0.35 s is UIKit's usual
///   double-tap window; Apple does not publish the keyboard's.
/// - `doubleSpaceInterval`: the second space of ". " must follow the first within this. KeyboardKit
///   (an open-source reimplementation of Apple's keyboard) uses 3 s.
struct TypingParameters: Equatable, Sendable {
    var shiftDoubleTapInterval: TimeInterval = 0.35
    var doubleSpaceInterval: TimeInterval = 3

    static let standard = TypingParameters()
}

/// Mirrors `UITextAutocapitalizationType`, so the rules stay Foundation-only.
enum AutocapitalizationMode: Equatable, Sendable {
    case none, words, sentences, allCharacters
}

enum ShiftMode: Equatable, Sendable {
    case off
    /// The next letter is uppercase, then shift turns off.
    case once
    case capsLock
}

/// The layer and shift state of the key area, and the timing rules around them. Pure; times are
/// touch timestamps.
struct TypingState: Equatable, Sendable {
    var parameters = TypingParameters.standard
    private(set) var layer = KeyboardLayer.letters
    private(set) var shift = ShiftMode.off
    /// Shift came on by auto-capitalization, so auto-capitalization may also turn it off.
    private(set) var shiftIsAutomatic = false
    private var lastShiftTapAt: TimeInterval?
    private var lastSpaceAt: TimeInterval?
    /// What the text last called for (`updateAutomaticShift`); nil after an edit or a field change.
    private var lastAutomaticDecision: Bool?

    init(parameters: TypingParameters = .standard) {
        self.parameters = parameters
    }

    /// One tap toggles a one-shot shift; two quick taps lock caps; a tap in caps lock unlocks.
    mutating func tapShift(at time: TimeInterval) {
        if let last = lastShiftTapAt, time - last <= parameters.shiftDoubleTapInterval, time >= last {
            shift = .capsLock
            lastShiftTapAt = nil
        } else {
            shift = shift == .off ? .once : .off
            lastShiftTapAt = time
        }
        shiftIsAutomatic = false
        lastSpaceAt = nil
    }

    mutating func switchLayer(to layer: KeyboardLayer) {
        self.layer = layer
        lastSpaceAt = nil
        lastShiftTapAt = nil
    }

    /// The text a character key types now: uppercase while shifted.
    func text(for character: String) -> String {
        shift == .off ? character : character.uppercased()
    }

    /// Call after a character key typed. A one-shot shift turns off; an apostrophe in the number
    /// or symbol layer returns to letters, as on Apple's keyboard.
    mutating func didTypeCharacter(_ character: String) {
        if shift == .once {
            shift = .off
            shiftIsAutomatic = false
        }
        if layer != .letters, character == "'" { layer = .letters }
        lastSpaceAt = nil
        // Shift, a letter, shift is two single taps, not a double tap.
        lastShiftTapAt = nil
        lastAutomaticDecision = nil
    }

    /// What the space key does now: a plain space, or ". " in place of the space just typed.
    mutating func spaceEdit(before: String?, at time: TimeInterval) -> SpaceEdit {
        lastShiftTapAt = nil
        lastAutomaticDecision = nil
        defer { if layer != .letters { layer = .letters } }
        if let last = lastSpaceAt, time >= last, time - last <= parameters.doubleSpaceInterval,
           DoubleSpacePeriod.applies(before: before) {
            lastSpaceAt = nil
            return .replaceSpaceWithPeriod
        }
        lastSpaceAt = time
        return .space
    }

    /// Return also leaves the number and symbol layers.
    mutating func didTypeReturn() {
        layer = .letters
        lastSpaceAt = nil
        lastShiftTapAt = nil
        lastAutomaticDecision = nil
    }

    mutating func didDelete() {
        lastSpaceAt = nil
        lastShiftTapAt = nil
        lastAutomaticDecision = nil
    }

    /// Auto-capitalization only moves between off and an automatic one-shot shift; it never
    /// overrides a shift the user set or caps lock. It acts only when what the text calls for changes,
    /// or after the text or the field did (an edit, `resetTiming`): a shift the user just turned off
    /// stays off while callbacks report the same text (ARCHITECTURE.md, "Typing correctness is
    /// paramount": a late trackpad report never re-cases the next key).
    mutating func updateAutomaticShift(_ shouldCapitalize: Bool) {
        guard shouldCapitalize != lastAutomaticDecision else { return }
        lastAutomaticDecision = shouldCapitalize
        if shouldCapitalize, shift == .off {
            shift = .once
            shiftIsAutomatic = true
        } else if !shouldCapitalize, shift == .once, shiftIsAutomatic {
            shift = .off
            shiftIsAutomatic = false
        }
    }

    /// The field changed under the keyboard (focus or a cursor move): forget the space timing.
    mutating func resetTiming() {
        lastSpaceAt = nil
        lastShiftTapAt = nil
        lastAutomaticDecision = nil
    }
}

enum SpaceEdit: Equatable, Sendable {
    case space
    /// Delete the space just typed and insert ". ".
    case replaceSpaceWithPeriod
}

enum AutoCapitalization {
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "\u{2026}"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "\u{00BB}"]

    /// Whether the next letter should be uppercase. `before` is the text before the caret; nil or
    /// empty is the start of the field.
    static func shouldCapitalize(before: String?, mode: AutocapitalizationMode) -> Bool {
        switch mode {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            guard let last = before?.last else { return true }
            return last.isWhitespace
        case .sentences:
            guard let before, let last = before.last else { return true }
            if last.isNewline { return true }
            guard last == " " || last == "\t" else { return false }
            var trimmed = Substring(before)
            while let character = trimmed.last, character == " " || character == "\t" { trimmed = trimmed.dropLast() }
            guard let end = trimmed.last else { return true }
            if end.isNewline { return true }
            while let character = trimmed.last, closers.contains(character) { trimmed = trimmed.dropLast() }
            return trimmed.last.map(sentenceEnds.contains) ?? false
        }
    }
}

enum DoubleSpacePeriod {
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}"]

    /// Whether a second space right after `before` (which ends in the first one) becomes ". ": the
    /// space must follow a word, a number or a closing bracket or quote, not punctuation or another
    /// space.
    static func applies(before: String?) -> Bool {
        guard let before, before.last == " " else { return false }
        guard let previous = before.dropLast().last else { return false }
        return previous.isLetter || previous.isNumber || closers.contains(previous)
    }
}

/// The text before the caret as this keyboard last changed it. The proxy's context can lag the
/// keyboard's own edits by a frame or more, so typing decisions read this model while the proxy still
/// shows the field as it was before one of them (exactly what it read before an edit, or the model as
/// an earlier edit left it), or a shorter view of the model. Once the proxy shows the model, or reads
/// anything else (it caught up, and the model was built on a reading that was itself behind), the
/// proxy answers. Memory only, a bounded tail, forgotten on any outside change, once the proxy shows
/// it, and at the latest `lifetime` after it was first held: more typing never extends that.
struct ContextTail: Equatable, Sendable {
    static let limit = 256
    static let lifetime: TimeInterval = 10
    /// Edits remembered for telling a lagging proxy from one that moved on.
    static let history = 8
    private(set) var known: String?
    /// When the current model was first held.
    private(set) var knownSince: TimeInterval?
    /// What the proxy read before each recent edit, and the model as each recent edit before the last
    /// left it: a proxy reading one of these has not caught up yet.
    private var readingsBefore: [String] = []
    private var earlierModels: [String] = []

    /// When the model must be forgotten, if one is held.
    var expiresAt: TimeInterval? { knownSince.map { $0 + Self.lifetime } }

    /// The best estimate of the text before the caret.
    func current(proxyBefore: String?) -> String? {
        guard let known else { return proxyBefore }
        if Self.shows(proxyBefore, known) { return proxyBefore }
        let proxy = proxyBefore ?? ""
        // A shorter view of the same text (a window that starts at the last line break), or the field as
        // it was before one of our edits: the model knows more.
        let narrower = known.hasSuffix(proxy)
        let behind = readingsBefore.contains(proxy) || earlierModels.contains { !$0.isEmpty && proxy.hasSuffix($0) }
        return narrower || behind ? known : proxyBefore
    }

    mutating func inserted(_ text: String, proxyBefore: String?, at time: TimeInterval) {
        let base = current(proxyBefore: proxyBefore) ?? ""
        hold(String((base + text).suffix(Self.limit)), readingBefore: proxyBefore, at: time)
    }

    mutating func deleted(graphemes count: Int, proxyBefore: String?, at time: TimeInterval) {
        guard let base = current(proxyBefore: proxyBefore), base.count >= count else {
            // Deleted past what is known: what precedes is unknown until the proxy says.
            forget()
            return
        }
        // Deleted exactly what is known: the caret is at the start of what the proxy showed, which starts
        // a sentence or a line (measured in UIKit), unless that was the line break the proxy shows alone
        // at a line's start, which joins the line to one it never showed.
        if base.count == count, base.first?.isNewline == true {
            forget()
            return
        }
        hold(String(base.dropLast(count)), readingBefore: proxyBefore, at: time)
    }

    /// A caret move of ours (the trackpad) leaves `before` before the caret; the proxy may show it late.
    mutating func moved(before: String, proxyBefore: String?, at time: TimeInterval) {
        forget()
        hold(String(before.suffix(Self.limit)), readingBefore: proxyBefore, at: time)
        acknowledge(proxyBefore: proxyBefore)
    }

    /// Forgets the model once its lifetime is over.
    mutating func expire(now: TimeInterval) {
        guard let expiresAt, now >= expiresAt else { return }
        forget()
    }

    private mutating func hold(_ text: String, readingBefore: String?, at time: TimeInterval) {
        if known == nil { knownSince = time }
        if let known { earlierModels = Array((earlierModels + [known]).suffix(Self.history)) }
        readingsBefore = Array((readingsBefore + [readingBefore ?? ""]).suffix(Self.history))
        known = text
    }

    /// Call on a host callback of ours (a report of our edits or caret moves; an outside change forgets
    /// the model). Keeps the model only if the proxy shows it, or a shorter view of it.
    mutating func proxyChanged(before: String?) {
        guard let known else { return }
        if Self.shows(before, known) { return }
        if known.hasSuffix(before ?? ""), before?.isEmpty == false { return }
        forget()
    }

    /// The proxy shows the model, and maybe more before it. An empty model (the caret at the start of
    /// what is known) is shown only by an empty proxy.
    private static func shows(_ proxyBefore: String?, _ known: String) -> Bool {
        known.isEmpty ? (proxyBefore ?? "").isEmpty : proxyBefore?.hasSuffix(known) == true
    }

    mutating func forget() {
        known = nil
        knownSince = nil
        readingsBefore = []
        earlierModels = []
    }

    /// Releases the model once the proxy shows it: the proxy is then the only copy, so the typed text
    /// is not held a moment longer than the edit that needed it.
    mutating func acknowledge(proxyBefore: String?) {
        guard let known, Self.shows(proxyBefore, known) else { return }
        forget()
    }
}
