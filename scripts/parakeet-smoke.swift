import Foundation

/// Build with Sources/Parakeet/*.swift only. Takes a model bundle and invented
/// synthetic audio; never launches FreeFlow or reads its settings or history.
@main
struct ParakeetSmoke {
    static func main() async throws {
        guard (3...4).contains(CommandLine.arguments.count) else { fatalError("Usage: parakeet-smoke BUNDLE SYNTHETIC_AUDIO [EXPECTED_SYNTHETIC_TEXT]") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let preparationStart = Date()
        try await LocalParakeetService.shared.prepare(directory: directory)
        let preparationSeconds = Date().timeIntervalSince(preparationStart)
        let repeatedPreparationStart = Date()
        try await LocalParakeetService.shared.prepare(directory: directory)
        let repeatedPreparationSeconds = Date().timeIntervalSince(repeatedPreparationStart)
        let start = Date()
        let text = try await LocalParakeetService.shared.transcribe(
            fileURL: URL(fileURLWithPath: CommandLine.arguments[2]),
            directory: directory
        )
        // No transcript output. Compare a fixed, invented utterance.
        let expected = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : "the blue lantern is beside the green notebook"
        let normalized = text.lowercased().filter { $0.isLetter || $0.isWhitespace }
        print(String(format: "Synthetic smoke: preparation_s=%.3f, repeated_preparation_s=%.3f, transcription_s=%.3f, expected_match=%@", preparationSeconds, repeatedPreparationSeconds, Date().timeIntervalSince(start), String(normalized == expected)))
        guard normalized == expected else { throw LocalParakeetError.invalid("Synthetic utterance did not match the expected transcription.") }
    }
}
