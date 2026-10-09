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
    }

    /// What the space key does now: a plain space, or ". " in place of the space just typed.
    mutating func spaceEdit(before: String?, at time: TimeInterval) -> SpaceEdit {
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
    }

    mutating func didDelete() {
        lastSpaceAt = nil
    }

    /// Auto-capitalization only moves between off and an automatic one-shot shift; it never
    /// overrides a shift the user set or caps lock.
    mutating func updateAutomaticShift(_ shouldCapitalize: Bool) {
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
/// keyboard's own edits by a frame or more, so typing decisions read this model until the proxy
/// agrees. Memory only, a bounded tail, forgotten on any outside change.
struct ContextTail: Equatable, Sendable {
    static let limit = 256
    private(set) var known: String?

    /// The best estimate of the text before the caret.
    func current(proxyBefore: String?) -> String? {
        guard let known else { return proxyBefore }
        if let proxyBefore, proxyBefore.hasSuffix(known) { return proxyBefore }
        return known
    }

    mutating func inserted(_ text: String, proxyBefore: String?) {
        let base = current(proxyBefore: proxyBefore) ?? ""
        known = String((base + text).suffix(Self.limit))
    }

    mutating func deleted(graphemes count: Int, proxyBefore: String?) {
        guard let base = current(proxyBefore: proxyBefore), base.count > count else {
            // Deleted past what is known: what precedes is unknown until the proxy says.
            known = nil
            return
        }
        known = String(base.dropLast(count))
    }

    /// Call when the document changed outside this keyboard's edits. Keeps the model only if the
    /// proxy already shows it.
    mutating func proxyChanged(before: String?) {
        guard let known else { return }
        if let before, before.hasSuffix(known) { return }
        self.known = nil
    }

    mutating func forget() {
        known = nil
    }
}
