import Foundation

/// The text just before and after the insertion point of the focused field;
/// either is nil when it could not be read.
struct InsertionContext: Equatable {
    let before: String?
    let after: String?
}

/// Reads a few characters on each side of the focused field's selection just
/// before a paste, so `InsertionContextFormatter` can fit the dictation to
/// them. High risk: it reads another application's text. Only the field's
/// focus, role, secure state, character count, selection and at most `span`
/// UTF-16 units on each side are read, through the same bounded reader as the
/// correction watcher. Nothing read is logged or kept after the paste.
final class InsertionContextProbe: @unchecked Sendable {
    static let span = 16
    static let deadline: TimeInterval = 0.3

    private let reader: TextFieldReader
    private let queue = DispatchQueue(label: "localflow.insertion-context", qos: .userInitiated)

    init(reader: TextFieldReader) {
        self.reader = reader
    }

    /// `completion` runs once on the main thread, within the deadline, with
    /// nil when the context is unknown, so a slow application never holds the
    /// paste up for long.
    func read(completion: @escaping (InsertionContext?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        var delivered = false
        let deliver: (InsertionContext?) -> Void = { context in
            guard !delivered else { return }
            delivered = true
            completion(context)
        }
        queue.async { [reader] in
            let context = Self.read(using: reader)
            DispatchQueue.main.async { deliver(context) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deadline) {
            deliver(nil)
        }
    }

    /// The context of another app's focused, editable, non-secure text field,
    /// or nil when there is none or nothing could be read. As in the correction
    /// watcher, the field is checked before every read and after the last one:
    /// a field that loses focus or turns secure meanwhile yields nothing.
    static func read(using reader: TextFieldReader) -> InsertionContext? {
        guard reader.isTrusted(), let target = reader.captureFocusedTextField() else { return nil }
        func stillEligible() -> Bool { reader.isTrusted() && reader.check(target) == .ok }
        guard stillEligible(), let selection = reader.selectedRange(target),
              stillEligible(), let count = reader.characterCount(target),
              selection.location + selection.length <= count else { return nil }
        let start = max(0, selection.location - span)
        let end = selection.location + selection.length
        var before: String? = ""
        if selection.location > 0 {
            guard stillEligible() else { return nil }
            before = reader.string(target, range: TextFieldRange(location: start, length: selection.location - start))
        }
        var after: String? = ""
        if end < count {
            guard stillEligible() else { return nil }
            after = reader.string(target, range: TextFieldRange(location: end, length: min(span, count - end)))
        }
        guard stillEligible(), before != nil || after != nil else { return nil }
        return InsertionContext(before: before, after: after)
    }
}
