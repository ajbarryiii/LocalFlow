import Foundation

/// The word corrector (ARCHITECTURE.md, "Word autocorrect"): replaces a just-typed word with a lexicon form
/// when the touch evidence and the word model favour it by the margin. Pure and deterministic, Float64.
/// Reference: localflow-swipe `tap/autocorrect.py` (`Corrector`), whose contract this port follows; it
/// matches the reference on the generated fixtures (`AutocorrectFixtures`).
///
/// - The typed key is the word's letters (apostrophes removed), each paired with its tap. Keys shorter than
///   `minLength` letters are kept.
/// - Candidates: every lexicon key within optimal-string-alignment distance `maxEdits` of the typed key
///   (`maxEditsShort` for keys of at most `shortLength` letters), with all its forms.
/// - Score: the channel (the best alignment within the edit limit: a typed letter at a candidate letter
///   scores log(1 − pOmit − pInsert − pTranspose) plus its tap's touch log likelihood there, a letter without
///   a tap 0 at its own letter and −∞ elsewhere; an omitted candidate letter log pOmit; an inserted typed
///   letter log pInsert + log q, q mixing a repeat of the previous candidate letter, a slip onto its
///   neighbours and a uniform stray tap over the letters area; two swapped letters log pTranspose plus both
///   taps at their keys) plus `lmWeight` × the word model's log probability given the sentence's words.
/// - Spelling channel ("Spelling channel"), with `wSpelling` > 0 and `spelling` tables: each step of an
///   alignment that is an edit scores logaddexp(motor, log `wSpelling` + spelling), motor its score above and
///   spelling, with m the match log above and t(x) the step's tap's touch log likelihood at key x (0 for a
///   letter without a tap typed as x): typed x at candidate letter c ≠ x, m + sub[c, x] + t(x); candidate
///   letter c omitted after p (START for the first), dele[p, c]; typed x inserted after candidate letter c
///   (START before the first, where the motor term still judges it against the first), m + ins[c, x] + t(x);
///   candidate letters p, c typed as c, p, 2m + trans[p, c] + both taps' touch log likelihoods. Matches and
///   keep are unchanged. `wSpelling` 0 ignores the tables: the scores are the motor channel's, bit for bit.
/// - Keep scores the typed key with every letter matched, plus `lmWeight` × its model log probability if it
///   is a lexicon form, else `lmWeight` × log P("<unk>") + `logOOV`.
/// - The best form (ties: higher frequency, then alphabetically first) replaces the word only if it beats
///   keep by log(margin): `marginOOV` for a word outside the lexicon; for a lexicon word `marginApostrophe`
///   when the best has the typed key, else `marginKnown`.
/// - Suggestions (the strip after a commit key) rank the same scores without a margin.
///
/// Where the reference raises (taps of the wrong count, a word with characters other than a–z and
/// apostrophes, invalid parameters, a negative, NaN or infinite `wSpelling`, keys without a letter pitch),
/// this keeps the word. One exception: `wSpelling` > 0 without tables scores the motor channel alone (the
/// reference raises; the manifest refuses such presets, so only a stale override gets here). Main thread
/// only: the word model caches by context until `forgetContext()`, and the corrector its letters layout
/// and spelling constants. Nothing here logs, stores or sends its inputs.
final class Autocorrector: WordCorrecting {
    /// The model's word for every word outside its vocabulary (`tap.wordlm.UNK`).
    static let unknown = WordModelVocabulary.unknown
    /// Neighbours for slips: other letter keys whose centres are within this many letter pitches
    /// (`tap.typos.NEIGHBOUR_REACH`).
    static let neighbourReach = 1.5

    let lexicon: WordLexicon
    let model: WordModel
    let touch: TapDecoder.TouchModel
    /// The spelling channel's tables; nil scores the motor channel alone whatever `wSpelling` is.
    let spelling: SpellingTables?

    private var layout: Layout?
    private var spellingConstants: SpellingConstants?

    init(lexicon: WordLexicon, model: WordModel, touch: TapDecoder.TouchModel = .standard, spelling: SpellingTables? = nil) {
        self.lexicon = lexicon
        self.model = model
        self.touch = touch
        self.spelling = spelling
    }

    // MARK: Correcting

    func correct(context: String, word: String, points: [(x: Double, y: Double)?], keys: [PlacedKey],
                 params: AutocorrectParams) -> String {
        guard let typed = Typed(word), points.count == typed.bytes.count else { return word }
        let p = params
        let n = typed.codes.count
        guard n >= p.minLength else { return word }
        guard n > 0, let constants = Constants(p) else { return word }
        let known = lexicon.contains(word)
        let lowest: Double
        if !known {
            lowest = constants.thresholdOOV
        } else if lexicon.forms(ofKey: typed.key).contains(where: { $0 != word }) {
            lowest = min(constants.thresholdKnown, constants.thresholdApostrophe)
        } else {
            lowest = constants.thresholdKnown
        }
        guard lowest != .infinity else { return word }
        guard let search = search(typed, points: points, keys: keys, params: p, constants: constants) else { return word }
        let words = Self.sentenceWords(context)
        var keep = Double(n) * constants.match + Self.pairwiseSum((0 ..< n).map { search.table[$0 * 26 + typed.codes[$0]] })
        keep += p.lmWeight * (model.logProbs(context: words, words: [known ? word : Self.unknown]).first ?? -.infinity)
        if !known { keep += p.logOOV }

        // A model log probability is at most 0, so a channel below keep + the lowest threshold cannot win.
        guard let scored = scoredForms(search, words: words, params: p, bar: p.lmWeight >= 0 ? keep + lowest : nil)
        else { return word }
        let (ids, forms, scores) = scored
        var best = -1
        var bestFrequency = 0
        for index in forms.indices {
            let frequency = lexicon.frequency(ofFormAt: ids[index])
            if best < 0 || Self.precedes(scores[index], frequency, forms[index], scores[best], bestFrequency, forms[best]) {
                best = index
                bestFrequency = frequency
            }
        }
        let threshold: Double
        if !known {
            threshold = constants.thresholdOOV
        } else if Self.key(of: forms[best]) == typed.key {
            threshold = constants.thresholdApostrophe
        } else {
            threshold = constants.thresholdKnown
        }
        guard forms[best] != word, scores[best].isFinite, scores[best] - keep >= threshold else { return word }
        return forms[best]
    }

    func suggestions(context: String, word: String, points: [(x: Double, y: Double)?], keys: [PlacedKey],
                     params: AutocorrectParams, limit: Int) -> [String] {
        guard limit > 0, let typed = Typed(word), points.count == typed.bytes.count, !lexicon.contains(word) else { return [] }
        let n = typed.codes.count
        guard n >= params.minLength, n > 0, let constants = Constants(params),
              let search = search(typed, points: points, keys: keys, params: params, constants: constants),
              let scored = scoredForms(search, words: Self.sentenceWords(context), params: params, bar: nil)
        else { return [] }
        let (ids, forms, scores) = scored
        let frequencies = ids.map(lexicon.frequency(ofFormAt:))
        let ranked = forms.indices.filter { scores[$0].isFinite }.sorted {
            Self.precedes(scores[$0], frequencies[$0], forms[$0], scores[$1], frequencies[$1], forms[$1])
        }
        return ranked.prefix(limit).map { forms[$0] }
    }

    /// Drops the word model's caches of sentence contexts. The corrector itself keeps no context or word
    /// between calls (only the letters layout it last saw).
    func forgetContext() {
        model.forgetContext()
    }

    /// The lexicon keys a typed key's corrections are drawn from, sorted (`Corrector.candidates`); empty for
    /// a key with characters other than a–z.
    func candidates(key: String, params: AutocorrectParams) -> [String] {
        guard let typed = Typed(key), typed.key == key else { return [] }
        let limit = limit(typed.codes.count, params)
        guard limit >= 0 else { return [] }
        return lexicon.keys(within: limit, of: typed.codes).map { candidate in
            String(decoding: candidate.codes.map { UInt8(ascii: "a") + UInt8($0) }, as: UTF8.self)
        }
    }

    /// The words a word model sees (`tap.words.sentence_words`): the word tokens (maximal runs of a–z and
    /// apostrophes, without leading or trailing apostrophes, holding a letter) of the text after its last ".".
    static func sentenceWords(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        let start = bytes.lastIndex(of: UInt8(ascii: ".")).map { $0 + 1 } ?? 0
        var words: [String] = []
        var index = start
        while index < bytes.count {
            guard isTokenByte(bytes[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < bytes.count, isTokenByte(bytes[end]) { end += 1 }
            var lo = index, hi = end
            while lo < hi, bytes[lo] == apostrophe { lo += 1 }
            while hi > lo, bytes[hi - 1] == apostrophe { hi -= 1 }
            if lo < hi { words.append(String(decoding: bytes[lo ..< hi], as: UTF8.self)) }
            index = end
        }
        return words
    }

    /// A word's key: its letters, apostrophes removed (`tap.words.word_key`).
    static func key(of word: String) -> String {
        String(decoding: word.utf8.filter { $0 != apostrophe }, as: UTF8.self)
    }

    // MARK: Pieces

    /// The typed key's candidate keys within its edit limit, its taps' touch table and the channel that scores
    /// a candidate; nil (the word kept) for a negative limit, no candidate, or keys without a letters layout.
    private struct Search {
        let candidates: [(node: Int, codes: [Int])]
        let table: [Double]
        let channel: Channel
    }

    private func search(_ typed: Typed, points: [(x: Double, y: Double)?], keys: [PlacedKey], params p: AutocorrectParams,
                        constants: Constants) -> Search? {
        let n = typed.codes.count
        let limit = limit(n, p)
        guard limit >= 0 else { return nil }
        let candidates = lexicon.keys(within: limit, of: typed.codes)
        guard !candidates.isEmpty, let layout = layout(for: keys) else { return nil }
        let table = touchTable(typed: typed, points: points, layout: layout)
        let inserted = insertions(table: table, rows: n, layout: layout, constants: constants)
        var spelled: SpellingTerms?
        if let spelling, let logWeight = constants.logSpelling {
            spelled = spellingTerms(typed: typed.codes, table: table, inserted: inserted, tables: spelling, logWeight: logWeight,
                                    constants: constants)
        }
        let channel = Channel(typed: typed.codes, edits: limit + 1, longest: candidates.map(\.codes.count).max() ?? 0, table: table,
                              inserted: inserted, spelled: spelled, constants: constants)
        return Search(candidates: candidates, table: table, channel: channel)
    }

    /// Every form of the candidates with a finite channel (that reaches `bar`, when given), with its id, scored
    /// channel + `lmWeight` × its model log probability given `words`; nil when there is none or the model fails.
    private func scoredForms(_ search: Search, words: [String], params p: AutocorrectParams,
                             bar: Double?) -> (ids: [Int], forms: [String], scores: [Double])? {
        var ids: [Int] = []
        var scores: [Double] = []
        for candidate in search.candidates {
            let score = search.channel.score(candidate.codes)
            guard score.isFinite else { continue }
            if let bar, !(score >= bar - 1e-9 * (1 + abs(bar))) { continue }
            for id in lexicon.formIDs(ofNode: candidate.node) {
                ids.append(id)
                scores.append(score)
            }
        }
        guard !ids.isEmpty else { return nil }
        let forms = ids.map(lexicon.form(at:))
        let logProbs = model.logProbs(context: words, words: forms)
        guard logProbs.count == forms.count else { return nil }
        for index in forms.indices { scores[index] += p.lmWeight * logProbs[index] }
        return (ids, forms, scores)
    }

    private static let apostrophe = UInt8(ascii: "'")

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || byte == apostrophe
    }

    /// The edit limit for a typed key of `letters` letters, at most letters + the longest key: no alignment
    /// uses more edits (each typed letter inserted, each candidate letter omitted), so a larger limit is the
    /// same limit, and bounding it keeps the buffers and their sizes finite.
    private func limit(_ letters: Int, _ p: AutocorrectParams) -> Int {
        min(letters <= p.shortLength ? p.maxEditsShort : p.maxEdits, letters + lexicon.longestKey)
    }

    /// Whether (score, frequency, form) ranks before the other: higher score, then higher frequency, then the
    /// alphabetically first form (by code point, as Python compares strings).
    private static func precedes(_ score: Double, _ frequency: Int, _ form: String, _ otherScore: Double, _ otherFrequency: Int,
                                 _ otherForm: String) -> Bool {
        if score != otherScore { return score > otherScore }
        if frequency != otherFrequency { return frequency > otherFrequency }
        return form.utf8.lexicographicallyPrecedes(otherForm.utf8)
    }

    /// The typed word: its bytes (a–z and apostrophes only), its key and the key's letter codes (0...25).
    private struct Typed {
        let bytes: [UInt8]
        let key: String
        let codes: [Int]

        init?(_ word: String) {
            bytes = Array(word.utf8)
            var codes: [Int] = []
            codes.reserveCapacity(bytes.count)
            for byte in bytes where byte != Autocorrector.apostrophe {
                guard (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) else { return nil }
                codes.append(Int(byte - UInt8(ascii: "a")))
            }
            self.codes = codes
            key = String(decoding: bytes.filter { $0 != Autocorrector.apostrophe }, as: UTF8.self)
        }
    }

    /// The parameters' logs, or nil for parameters the reference rejects.
    struct Constants {
        let match: Double
        let omit: Double
        let insert: Double
        let transpose: Double
        let logRepeat: Double
        let logSlip: Double
        /// log(1 − wRepeat − wSlip), before dividing by the area.
        let logStrayWeight: Double
        let thresholdOOV: Double
        let thresholdKnown: Double
        let thresholdApostrophe: Double
        /// log wSpelling, nil for 0 (the motor channel alone).
        let logSpelling: Double?

        /// Nil for parameters the reference rejects, except insertion weights summing to more than 1 by at most
        /// `AutocorrectManifest.weightSumTolerance` (rounding, which the manifest and the settings accept):
        /// those are scaled to sum to 1, leaving no uniform share. The reference has no tolerance.
        init?(_ p: AutocorrectParams) {
            let sum = p.wRepeat + p.wSlip
            guard p.wRepeat >= 0, p.wSlip >= 0, sum <= 1 + AutocorrectManifest.weightSumTolerance else { return nil }
            let (wRepeat, wSlip, stray) = sum > 1 ? (p.wRepeat / sum, p.wSlip / sum, 0.0) : (p.wRepeat, p.wSlip, 1 - p.wRepeat - p.wSlip)
            let keep = 1 - p.pOmit - p.pInsert - p.pTranspose
            guard keep > 0, keep.isFinite, p.lmWeight.isFinite, !p.logOOV.isNaN, p.wSpelling.isFinite, p.wSpelling >= 0 else { return nil }
            match = log(keep)
            omit = Self.log0(p.pOmit)
            insert = Self.log0(p.pInsert)
            transpose = Self.log0(p.pTranspose)
            logRepeat = Self.log0(wRepeat)
            logSlip = Self.log0(wSlip)
            logStrayWeight = Self.log0(stray)
            thresholdOOV = Self.log0(p.marginOOV)
            thresholdKnown = Self.log0(p.marginKnown)
            thresholdApostrophe = Self.log0(p.marginApostrophe)
            logSpelling = p.wSpelling > 0 ? log(p.wSpelling) : nil
        }

        /// The reference's `_log`: log x for x > 0, else −∞.
        static func log0(_ x: Double) -> Double { x > 0 ? Foundation.log(x) : -.infinity }
    }

    /// What the corrector needs of a letters layout: each letter's key (the last with that letter), the
    /// letters area's log, each letter's neighbours and the touch model over the keys.
    private struct Layout {
        let keys: [PlacedKey]
        let columns: [Int?]
        let logArea: Double
        /// Per letter c, its neighbours x (alphabetically) with weight 1 / (c's neighbour count).
        let slip: [[(letter: Int, weight: Double)]]
        let decoder: TapDecoder
    }

    private func layout(for keys: [PlacedKey]) -> Layout? {
        if let layout, layout.keys == keys { return layout }
        guard let pitch = TapDecoder.letterPitch(in: keys) else { return nil }
        var columns = [Int?](repeating: nil, count: 26)
        for (index, key) in keys.enumerated() {
            if let column = TapDecoder.outputIndex(of: key.action), column < 26 { columns[column] = index }
        }
        // The area of the letter and space keys' bounding box: a uniform stray tap.
        let pad = keys.filter { TapDecoder.outputIndex(of: $0.action) != nil }
        guard let minX = pad.map(\.frame.x).min(), let maxX = pad.map({ $0.frame.x + $0.frame.width }).max(),
              let minY = pad.map(\.frame.y).min(), let maxY = pad.map({ $0.frame.y + $0.frame.height }).max() else { return nil }
        let area = (maxX - minX) * (maxY - minY)
        guard area > 0, area.isFinite else { return nil }
        // Neighbours as `tap.typos.neighbours`: every other letter key within the reach, by key.
        let letters = keys.indices.filter { TapDecoder.outputIndex(of: keys[$0].action).map { $0 < 26 } ?? false }
        let reach = Self.neighbourReach * pitch
        var near = [Set<Int>](repeating: [], count: 26)
        var counted = [Int](repeating: 0, count: 26)
        for a in letters {
            let c = TapDecoder.outputIndex(of: keys[a].action)!
            var labels = Set<Int>()
            var count = 0
            for b in letters where b != a {
                let dx = keys[a].frame.midX - keys[b].frame.midX, dy = keys[a].frame.midY - keys[b].frame.midY
                if (dx * dx + dy * dy).squareRoot() <= reach {
                    labels.insert(TapDecoder.outputIndex(of: keys[b].action)!)
                    count += 1
                }
            }
            // A later key with the same letter replaces an earlier one, as the reference's dict does.
            near[c] = labels
            counted[c] = count
        }
        let slip = (0 ..< 26).map { c in
            near[c].sorted().map { (letter: $0, weight: 1 / Double(counted[c])) }
        }
        let layout = Layout(keys: keys, columns: columns, logArea: log(area), slip: slip,
                            decoder: TapDecoder(touch: touch, rule: TapDecoder.Rule(centre: 1, margin: 1, maxSurprise: nil)))
        self.layout = layout
        return layout
    }

    /// (letters × 26): each typed letter's tap log likelihood at each letter key; a letter without a tap
    /// scores 0 at its own letter and −∞ elsewhere.
    private func touchTable(typed: Typed, points: [(x: Double, y: Double)?], layout: Layout) -> [Double] {
        var table = [Double](repeating: -.infinity, count: typed.codes.count * 26)
        var row = 0
        for (byte, point) in zip(typed.bytes, points) where byte != Self.apostrophe {
            if let point, point.x.isFinite, point.y.isFinite {
                let likelihoods = layout.decoder.logLikelihoods(x: point.x, y: point.y, keys: layout.keys)
                if likelihoods.count == layout.keys.count {
                    for c in 0 ..< 26 { if let column = layout.columns[c] { table[row * 26 + c] = likelihoods[column] } }
                }
            } else {
                table[row * 26 + typed.codes[row]] = 0
            }
            row += 1
        }
        return table
    }

    /// (letters × 26): log pInsert + log q of each typed letter's tap inserted after each letter, with
    /// q = wRepeat touch(tap | c) + wSlip mean over c's neighbours of touch(tap | n) + (1 − wRepeat − wSlip) / area.
    private func insertions(table: [Double], rows: Int, layout: Layout, constants: Constants) -> [Double] {
        let logStray = constants.logStrayWeight - layout.logArea
        var out = [Double](repeating: -.infinity, count: rows * 26)
        var scaled = [Double](repeating: 0, count: 26)
        for i in 0 ..< rows {
            let top = table[i * 26 ..< i * 26 + 26].max() ?? -.infinity
            for x in 0 ..< 26 { scaled[x] = top.isFinite ? exp(table[i * 26 + x] - top) : 0 }
            for c in 0 ..< 26 {
                var sum = 0.0
                for (x, weight) in layout.slip[c] { sum += scaled[x] * weight }
                let slip = top.isFinite ? log(sum) + top : -.infinity
                let mixed = TapDecoder.logAddExp(constants.logRepeat + table[i * 26 + c], constants.logSlip + slip)
                out[i * 26 + c] = constants.insert + TapDecoder.logAddExp(mixed, logStray)
            }
        }
        return out
    }

    /// The spelling channel's terms per parameters (the reference's `_spell_omit` and `_spell_trans`), the
    /// motor cost mixed in: omissions [context p (START 26) × 26 + omitted c] = logaddexp(log pOmit, log w +
    /// dele[p, c]), transpositions [intended first × 26 + second] = logaddexp(log pTranspose, (log w + 2m) +
    /// trans), both touches added later. Cached for the last parameters.
    private struct SpellingConstants {
        let logWeight: Double, match: Double, omit: Double, transpose: Double
        let omits: [Double]
        let transposes: [Double]
    }

    /// Per word, every spelling alternative mixed into its motor cost as the reference orders the sums (rows
    /// typed letters, 26 columns): `aligned` [i × 26 + c] typed letter i at candidate letter c (the motor
    /// cost alone where c is the letter typed), `inserted` [i × 26 + c] inserted after c, `before` [i × 26 + c]
    /// inserted before a first candidate letter c; then the cached omissions and transpositions.
    struct SpellingTerms {
        let aligned: [Double]
        let inserted: [Double]
        let before: [Double]
        let omits: [Double]
        let transposes: [Double]
    }

    private func spellingTerms(typed codes: [Int], table: [Double], inserted motor: [Double], tables: SpellingTables, logWeight w: Double,
                               constants: Constants) -> SpellingTerms {
        let m = constants.match
        if spellingConstants.map({ $0.logWeight != w || $0.match != m || $0.omit != constants.omit || $0.transpose != constants.transpose })
            ?? true {
            let twice = w + 2 * m
            spellingConstants = SpellingConstants(
                logWeight: w, match: m, omit: constants.omit, transpose: constants.transpose,
                omits: tables.dele.map { TapDecoder.logAddExp(constants.omit, w + $0) },
                transposes: tables.trans.map { TapDecoder.logAddExp(constants.transpose, twice + $0) })
        }
        let shared = spellingConstants!
        let n = codes.count, wm = w + m, start = SpellingTables.start * 26
        var aligned = [Double](repeating: -.infinity, count: n * 26)
        var inserted = motor
        var before = motor
        for i in 0 ..< n {
            let x = codes[i], own = table[i * 26 + x]
            for c in 0 ..< 26 {
                let index = i * 26 + c
                let motorAligned = m + table[index]
                // A match has sub = −∞ on the diagonal: logaddexp leaves the motor score, so it is taken as is.
                aligned[index] = c == x ? motorAligned : TapDecoder.logAddExp(motorAligned, (wm + tables.sub[c * 26 + x]) + own)
                inserted[index] = TapDecoder.logAddExp(motor[index], (wm + tables.ins[c * 26 + x]) + own)
                before[index] = TapDecoder.logAddExp(motor[index], (wm + tables.ins[start + x]) + own)
            }
        }
        return SpellingTerms(aligned: aligned, inserted: inserted, before: before, omits: shared.omits, transposes: shared.transposes)
    }

    /// numpy's pairwise summation of a float64 array (`np.sum`): sequential below 8 values, eight
    /// accumulators up to 128, halves (cut to a multiple of 8) above, so sums match the reference's bits.
    static func pairwiseSum(_ values: [Double]) -> Double {
        values.withUnsafeBufferPointer { 0.0 + pairwiseSum($0[...]) }
    }

    static func pairwiseSum(_ a: Slice<UnsafeBufferPointer<Double>>) -> Double {
        let n = a.count, base = a.startIndex
        if n < 8 {
            var sum = 0.0
            for value in a { sum += value }
            return sum
        }
        if n <= 128 {
            var r = (0 ..< 8).map { a[base + $0] }
            var i = 8
            while i < n - n % 8 {
                for k in 0 ..< 8 { r[k] += a[base + i + k] }
                i += 8
            }
            var sum = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
            while i < n {
                sum += a[base + i]
                i += 1
            }
            return sum
        }
        var half = n / 2
        half -= half % 8
        return pairwiseSum(a[base ..< base + half]) + pairwiseSum(a[(base + half)...])
    }
}

/// The channel's Viterbi over (typed letters consumed, edits used), one candidate letter (column) at a time.
/// Candidates come in key order, so the columns of the prefix a candidate shares with the previous one are
/// reused: a column depends only on the candidate's letters up to it (column 0 on its first letter). Every
/// sum is formed in the reference's order, so scores match its bits whatever is reused. Plain pointers and
/// comparisons: it runs for every candidate, and the keyboard may be built without optimization. With the
/// spelling channel the same loops read its precomputed terms (`Autocorrector.SpellingTerms`) instead of the
/// motor costs; without, they run exactly as before.
private final class Channel {
    private let n: Int
    private let edits: Int
    /// Values per column: (n + 1) × edits, index t × edits + k.
    private let stride: Int
    private let columns: UnsafeMutablePointer<Double>
    private let typed: UnsafeMutablePointer<Int>
    private let table: UnsafeMutablePointer<Double>
    private let inserted: UnsafeMutablePointer<Double>
    private let match: Double, omit: Double, transpose: Double
    /// The spelling channel's terms (nil: the motor channel): aligned and before (n × 26), omissions
    /// (27 × 26) and transpositions (26 × 26); `inserted` then holds its insertions.
    private let spelled: (aligned: UnsafeMutablePointer<Double>, before: UnsafeMutablePointer<Double>, omits: UnsafeMutablePointer<Double>,
                          transposes: UnsafeMutablePointer<Double>)?
    private var previous: [Int] = []

    init(typed codes: [Int], edits: Int, longest: Int, table rows: [Double], inserted insertions: [Double],
         spelled terms: Autocorrector.SpellingTerms?, constants: Autocorrector.Constants) {
        n = codes.count
        self.edits = edits
        stride = (codes.count + 1) * edits
        columns = .allocate(capacity: (longest + 1) * stride)
        columns.initialize(repeating: -.infinity, count: (longest + 1) * stride)
        typed = .allocate(capacity: max(codes.count, 1))
        typed.initialize(from: codes, count: codes.count)
        table = .allocate(capacity: max(rows.count, 1))
        table.initialize(from: rows, count: rows.count)
        let mixed = terms?.inserted ?? insertions
        inserted = .allocate(capacity: max(mixed.count, 1))
        inserted.initialize(from: mixed, count: mixed.count)
        spelled = terms.map { terms in
            func copy(_ values: [Double]) -> UnsafeMutablePointer<Double> {
                let pointer = UnsafeMutablePointer<Double>.allocate(capacity: max(values.count, 1))
                pointer.initialize(from: values, count: values.count)
                return pointer
            }
            return (copy(terms.aligned), copy(terms.before), copy(terms.omits), copy(terms.transposes))
        }
        match = constants.match
        omit = constants.omit
        transpose = constants.transpose
    }

    deinit {
        columns.deallocate()
        typed.deallocate()
        table.deallocate()
        inserted.deallocate()
        if let spelled {
            spelled.aligned.deallocate()
            spelled.before.deallocate()
            spelled.omits.deallocate()
            spelled.transposes.deallocate()
        }
    }

    /// log P(taps | candidate key) within the edit limit; −∞ when no alignment fits.
    func score(_ candidate: [Int]) -> Double {
        let m = candidate.count, e = edits
        guard m > 0 else { return -.infinity }
        var shared = 0
        while shared < m, shared < previous.count, candidate[shared] == previous[shared] { shared += 1 }
        previous = candidate
        if shared == 0 {
            // Column 0: insertions before the first candidate letter, judged against it.
            for index in 0 ..< stride { columns[index] = -.infinity }
            columns[0] = 0
            let before = spelled?.before ?? inserted
            var i = 1
            while i <= n, i < e {
                columns[i * e + i] = columns[(i - 1) * e + i - 1] + before[(i - 1) * 26 + candidate[0]]
                i += 1
            }
        }
        var j = max(shared, 0) + 1
        while j <= m {
            column(j, candidate)
            j += 1
        }
        let last = columns + m * stride + n * e
        var best = -Double.infinity
        for k in 0 ..< e where last[k] > best { best = last[k] }
        return best
    }

    /// Column j (candidate letter j − 1) from columns j − 1 and j − 2.
    private func column(_ j: Int, _ candidate: [Int]) {
        let e = edits, c = candidate[j - 1]
        let current = columns + j * stride, before = columns + (j - 1) * stride
        for index in 0 ..< stride { current[index] = -.infinity }
        // A typed letter at candidate letter c: a match, or a substitution (one edit).
        let aligned = spelled?.aligned
        var t = 1
        while t <= n {
            let add: Double
            if let aligned { add = aligned[(t - 1) * 26 + c] } else { add = match + table[(t - 1) * 26 + c] }
            if typed[t - 1] == c {
                for k in 0 ..< e { current[t * e + k] = before[(t - 1) * e + k] + add }
            } else {
                var k = 1
                while k < e {
                    current[t * e + k] = before[(t - 1) * e + k - 1] + add
                    k += 1
                }
            }
            t += 1
        }
        guard e > 1 else { return }
        // Candidate letter c omitted (after candidate letter j − 2, START for the first).
        let omitted = spelled.map { $0.omits[(j >= 2 ? candidate[j - 2] : SpellingTables.start) * 26 + c] } ?? omit
        t = 0
        while t <= n {
            var k = 1
            while k < e {
                let value = before[t * e + k - 1] + omitted
                if value > current[t * e + k] { current[t * e + k] = value }
                k += 1
            }
            t += 1
        }
        // Two different candidate letters typed in swapped order.
        if j >= 2, n >= 2, candidate[j - 2] != c {
            let cp = candidate[j - 2], before2 = columns + (j - 2) * stride
            let transposed = spelled.map { $0.transposes[cp * 26 + c] } ?? transpose
            t = 2
            while t <= n {
                if typed[t - 1] == cp, typed[t - 2] == c {
                    let add = transposed + table[(t - 2) * 26 + c] + table[(t - 1) * 26 + cp]
                    var k = 1
                    while k < e {
                        let value = before2[(t - 2) * e + k - 1] + add
                        if value > current[t * e + k] { current[t * e + k] = value }
                        k += 1
                    }
                }
                t += 1
            }
        }
        // Typed letters inserted after c.
        t = 1
        while t <= n {
            let add = inserted[(t - 1) * 26 + c]
            var k = 1
            while k < e {
                let value = current[(t - 1) * e + k - 1] + add
                if value > current[t * e + k] { current[t * e + k] = value }
                k += 1
            }
            t += 1
        }
    }
}
