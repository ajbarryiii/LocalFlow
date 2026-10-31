import Foundation

/// Builds the text the keyboard inserts for a result. `contextBefore` and `contextAfter` are the
/// document text before and after the cursor; they only fit the transcript to its surroundings
/// (`InsertionContextFormatter`) and are never stored.
enum TextInsertionFormatter {
    static func text(for result: DictationResult, contextBefore: String?, contextAfter: String? = nil) -> String {
        let text = InsertionContextFormatter.text(for: result.text, before: contextBefore ?? "", after: contextAfter)
        // A transcript that was only "press enter" still presses Enter, as on macOS.
        return text + (result.pressEnter ? "\n" : "")
    }
}
