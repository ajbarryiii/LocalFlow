import Foundation

/// Restores the exact spelling of dictionary entries that carry case
/// (DESIGN §1.4). Runs on the raw transcript, before LocalDictationCore.
enum CasingRestorer {
    private struct Pattern {
        let text: [Unicode.Scalar]
        let folded: [Unicode.Scalar]
    }

    static func apply(_ transcript: String, entries: [DictionaryEntry]) -> String {
        // Only entries with a scalar that folding changes can restore anything.
        let patterns = entries.compactMap { entry -> Pattern? in
            let text = Array(entry.text.unicodeScalars)
            guard text.contains(where: { DictionaryText.fold($0) != [$0] }) else { return nil }
            return Pattern(text: text, folded: DictionaryText.fold(text))
        }
        // Longest first, then by entry text in scalar order.
        .sorted { lhs, rhs in
            if lhs.text.count != rhs.text.count { return lhs.text.count > rhs.text.count }
            return lhs.text.lexicographicallyPrecedes(rhs.text) { $0.value < $1.value }
        }
        guard !patterns.isEmpty else { return transcript }

        let input = Array(transcript.unicodeScalars)
        let folds = input.map(DictionaryText.fold)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(input.count)
        var position = 0
        scan: while position < input.count {
            if position == 0 || !DictionaryText.isWordCharacter(input[position - 1]) {
                for pattern in patterns {
                    if let end = match(pattern.folded, folds: folds, from: position),
                       end == input.count || !DictionaryText.isWordCharacter(input[end]) {
                        output += pattern.text
                        position = end
                        continue scan
                    }
                }
            }
            output.append(input[position])
            position += 1
        }
        return DictionaryText.string(output)
    }

    /// End of the shortest transcript run starting at `start` whose folded
    /// scalars equal `folded` exactly, or nil.
    private static func match(_ folded: [Unicode.Scalar], folds: [[Unicode.Scalar]], from start: Int) -> Int? {
        var offset = 0
        var index = start
        while offset < folded.count {
            guard index < folds.count else { return nil }
            let piece = folds[index]
            guard offset + piece.count <= folded.count,
                  folded[offset..<offset + piece.count].elementsEqual(piece) else { return nil }
            offset += piece.count
            index += 1
        }
        return index
    }
}
