import Foundation

/// Text normalisation and answer grading, mirroring the classic "accept small slips" behaviour
/// (same rules as shared/engine/Text.kt).
public enum Grading {

    private static let punctuation: Set<Character> = ["¿", "¡", ".", ",", "!", "?", ";", ":", "\"", "«", "»"]

    private static func replacingPunctuation(_ s: String) -> String {
        String(s.map { punctuation.contains($0) ? " " : $0 })
    }

    private static func collapsingSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func tokens(_ s: String) -> [String] {
        replacingPunctuation(s).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    public static func norm(_ s: String) -> String {
        let apostrophes = s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "`", with: "'")
            .replacingOccurrences(of: "´", with: "'")
        return collapsingSpaces(replacingPunctuation(apostrophes))
    }

    /// Removes accents, umlauts, ligatures and apostrophes for a lenient second comparison.
    public static func loose(_ s: String) -> String {
        let decomposed = s.replacingOccurrences(of: "'", with: "").decomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for u in decomposed.unicodeScalars {
            switch u.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: scalars.append(u)
            }
        }
        return String(scalars)
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "æ", with: "ae")
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        if b.isEmpty { return a.count }
        var d = Array(0...b.count)
        if a.isEmpty { return b.count }
        for i in 1...a.count {
            var prev = d[0]
            d[0] = i
            for j in 1...b.count {
                let tmp = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = tmp
            }
        }
        return d[b.count]
    }

    public struct Grade: Equatable, Sendable {
        public let correct: Bool
        public let note: String?

        public init(correct: Bool, note: String? = nil) {
            self.correct = correct
            self.note = note
        }
    }

    /// Grades free text against the accepted answers.
    public static func grade(_ input: String, accepted: [String]) -> Grade {
        let n = norm(input)
        if n.isEmpty { return Grade(correct: false) }
        if accepted.contains(where: { norm($0) == n }) { return Grade(correct: true) }
        if let match = accepted.first(where: { loose(norm($0)) == loose(n) }) {
            return Grade(correct: true, note: "Achte auf Akzente und Apostrophe: \(match)")
        }
        let endings = ["s", "n", "e", "t"]
        for a in accepted {
            let want = norm(a).split(separator: " ").map(String.init)
            let got = n.split(separator: " ").map(String.init)
            if want.count != got.count { continue }
            var diff = 0
            var typo = true
            for i in want.indices {
                if want[i] == got[i] { continue }
                diff += 1
                let x = loose(want[i])
                let y = loose(got[i])
                // A missing/extra ending is usually grammar, not a typo.
                let grammar = endings.contains { x + $0 == y || y + $0 == x }
                if want[i].count < 6 || levenshtein(x, y) > 1 || grammar { typo = false }
            }
            if diff == 1 && typo { return Grade(correct: true, note: "Kleiner Tippfehler – richtig: \(a)") }
        }
        return Grade(correct: false)
    }
}
