import Foundation

struct VoiceMacro: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var command: String
    var payload: String
}

struct LocalDictationResult: Equatable {
    let rawTranscript: String
    let output: String
    let shouldPressEnter: Bool
    let usedMacro: Bool

    var status: String {
        let base = usedMacro ? "Local voice macro" : "Local transcription"
        return shouldPressEnter ? "\(base); detected press enter command" : base
    }
}

/// Deterministic commands only. Dictated instructions are always text; no model
/// other than the bundled speech recognizer processes the result.
enum LocalDictationCore {
    private static let trailingPressEnter = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[ \t\r\n,;:\-]+)press[ \t\r\n]+enter[\s\p{P}]*$"#
    )

    static func process(_ transcript: String, macros: [VoiceMacro], pressEnterEnabled: Bool) -> LocalDictationResult {
        var raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var shouldPressEnter = false
        if pressEnterEnabled,
           let match = trailingPressEnter.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
           let range = Range(match.range, in: raw) {
            raw.removeSubrange(range)
            raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            shouldPressEnter = true
        }
        let normalized = normalize(raw)
        let macro = normalized.isEmpty ? nil : macros.first { normalize($0.command) == normalized }
        return LocalDictationResult(rawTranscript: raw,
                                    output: (macro?.payload ?? raw).trimmingCharacters(in: .whitespacesAndNewlines),
                                    shouldPressEnter: shouldPressEnter, usedMacro: macro != nil)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().components(separatedBy: .punctuationCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
