import Foundation

/// SentencePiece BPE encoding over Unicode scalars (DESIGN §1.3, pin P4).
/// A piece's id is its merge rank: lower ids merge first. Pieces are keyed by
/// exact scalar sequence, never by `String`, so canonically equivalent text
/// does not collapse onto one piece.
final class BPEEncoder {
    static let unknownID = 0
    static let wordBoundary: Unicode.Scalar = "\u{2581}"

    private let ids: [[Unicode.Scalar]: Int]

    /// Pieces in id order. `<unk>` and empty pieces are never produced from text;
    /// a duplicated piece keeps its lowest id.
    init(pieces: [String]) {
        var ids: [[Unicode.Scalar]: Int] = [:]
        for (id, piece) in pieces.enumerated() {
            let scalars = Array(piece.unicodeScalars)
            guard !scalars.isEmpty, !scalars.elementsEqual("<unk>".unicodeScalars), ids[scalars] == nil else { continue }
            ids[scalars] = id
        }
        self.ids = ids
    }

    /// The bundled `vocabulary.json`: `{"0": piece, …, "1023": piece}`. The
    /// numeric order is the rank. Keys are read from UTF-8 bytes into scalars.
    convenience init(vocabularyFile url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count <= 1 << 20,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              object.count == 1024 else {
            throw LocalParakeetError.invalid("Invalid local vocabulary.")
        }
        var pieces: [String] = []
        for id in 0..<1024 {
            guard let piece = object[String(id)] else { throw LocalParakeetError.invalid("Invalid local vocabulary.") }
            pieces.append(piece)
        }
        self.init(pieces: pieces)
    }

    func encode(_ text: String) -> [Int] {
        // Empty text still gets the dummy prefix (pin P7), as SentencePiece does.
        var symbols: [[Unicode.Scalar]] = [[Self.wordBoundary]]
        for scalar in text.unicodeScalars {
            symbols.append([scalar == " " ? Self.wordBoundary : scalar])
        }
        // Inputs are at most a few hundred scalars, so a quadratic scan is cheap
        // and keeps the tie rule (lowest id, then leftmost) obvious.
        while symbols.count > 1 {
            var best: (index: Int, id: Int)?
            for index in 0..<(symbols.count - 1) {
                guard let id = ids[symbols[index] + symbols[index + 1]] else { continue }
                if best == nil || id < best!.id { best = (index, id) }
            }
            guard let best else { break }
            symbols[best.index] += symbols[best.index + 1]
            symbols.remove(at: best.index + 1)
        }
        var tokens: [Int] = []
        var previousUnknown = false
        for symbol in symbols {
            if let id = ids[symbol] {
                tokens.append(id)
                previousUnknown = false
            } else {
                // A run of non-pieces is one <unk>.
                if !previousUnknown { tokens.append(Self.unknownID) }
                previousUnknown = true
            }
        }
        return tokens
    }

    func encodesWithoutUnknown(_ text: String) -> Bool {
        let tokens = encode(text)
        return !tokens.isEmpty && !tokens.contains(Self.unknownID)
    }
}
