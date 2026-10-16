import Foundation

/// The width-normalized frame the swipe encoder was trained in (ARCHITECTURE.md, "Typing model v4
/// and swipe typing", step 1): x from 0.05 at the top row's first key center to 0.95 at its last,
/// y down from half a row pitch above the top row's centers, in the same unit as x.
struct SwipeFrame: Equatable, Sendable {
    private static let letters = "abcdefghijklmnopqrstuvwxyz".map(String.init)

    private let originX: Double
    private let originY: Double
    private let width: Double

    /// 52 values: centers of a…z in frame coordinates, x then y per letter.
    let letterCenters: [Double]

    /// From the letters layer's keys; nil unless all of a–z are present as `.character` keys.
    init?(keys: [PlacedKey]) {
        var centers: [String: (x: Double, y: Double)] = [:]
        for key in keys {
            guard case let .character(text) = key.action, centers[text] == nil else { continue }
            centers[text] = (key.frame.midX, key.frame.midY)
        }
        guard let q = centers["q"], let z = centers["z"],
              Self.letters.allSatisfy({ centers[$0] != nil }) else { return nil }

        // The top row: the character keys whose centers share q's row.
        var minX = Double.infinity, maxX = -Double.infinity
        for key in keys {
            guard case .character = key.action, key.frame.midY == q.y else { continue }
            minX = min(minX, key.frame.midX)
            maxX = max(maxX, key.frame.midX)
        }
        let width = (maxX - minX) / 0.9
        let pitch = (z.y - q.y) / 2
        guard width.isFinite, width > 0, pitch.isFinite else { return nil }
        originX = minX - 0.05 * width
        originY = q.y - pitch / 2
        self.width = width

        var values: [Double] = []
        values.reserveCapacity(52)
        for letter in Self.letters {
            let center = centers[letter]!
            values.append((center.x - originX) / width)
            values.append((center.y - originY) / width)
        }
        letterCenters = values
    }

    func normalize(x: Double, y: Double) -> (x: Double, y: Double) {
        ((x - originX) / width, (y - originY) / width)
    }
}
