import Foundation

/// Text normalisation and answer grading, mirroring the classic "accept small slips" behaviour
/// (same rules as shared/engine/Text.kt).
public enum Grading {

    private static let punctuation: Set<Character> = ["¿", "¡", ".", ",", "!", "?", ";", ":", "\"", "«", "»", "…", "“", "”", "„"]

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
            .replacingOccurrences(of: "‘", with: "'")
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

    /// Without spaces and hyphens: "e-mail" = "email", "as-tu" = "as tu".
    public static func compact(_ s: String) -> String {
        loose(norm(s)).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
    }

    /// Form of a word used to look it up in a course's vocabulary (see CourseIndex.known).
    public static func key(_ word: String) -> String { loose(norm(word)) }

    /// Edit distance where swapping two neighbouring letters ("thnak") counts as one edit.
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    private static let endings = ["s", "n", "e", "t", "d", "r", "m", "es", "en", "er", "em", "ed"]
    private static let grammarLast: Set<Character> = ["n", "m", "r", "s", "e"]

    /// Different endings are usually grammar (eat/eats, petit/petite, einen/einem), not a typo.
    private static func grammar(_ x: String, _ y: String) -> Bool {
        if endings.contains(where: { x + $0 == y || y + $0 == x }) { return true }
        guard x.count == y.count, x.count > 1, let lx = x.last, let ly = y.last else { return false }
        return x.dropLast() == y.dropLast() && grammarLast.contains(lx) && grammarLast.contains(ly)
    }

    /// Whether `typed` is a slip of the keyboard for `wanted` (both already loose): one wrong, missing, extra or
    /// swapped letter (two in words of 8+ letters). Very short words only allow swapped letters, and words under 6
    /// letters must start with the right letter – otherwise "he"/"she" or "cat"/"car" would pass.
    private static func isTypo(_ wanted: String, _ typed: String) -> Bool {
        if grammar(wanted, typed) || wanted.count < 3 { return false }
        let d = levenshtein(wanted, typed)
        if wanted.count == 3 { return d == 1 && wanted.sorted() == typed.sorted() }
        if wanted.count < 6 && wanted.first != typed.first { return false }
        return d <= (wanted.count >= 8 ? 2 : 1)
    }

    public struct Grade: Equatable, Sendable {
        public let correct: Bool
        public let note: String?

        public init(correct: Bool, note: String? = nil) {
            self.correct = correct
            self.note = note
        }
    }

    /// Grades free text against the accepted answers. Punctuation, capital letters, accents, apostrophes and
    /// hyphens never make an answer wrong; small typos are accepted with a note (one word in short sentences, two
    /// in sentences of 6+ words). `known` are the course's words in the answer language (see CourseIndex.known):
    /// a typed word that is itself a real word (ist/isst, women/woman) is a mistake, not a typo.
    public static func grade(_ input: String, accepted: [String], known: Set<String> = []) -> Grade {
        let n = norm(input)
        if n.isEmpty { return Grade(correct: false) }
        if accepted.contains(where: { norm($0) == n }) { return Grade(correct: true) }
        if let match = accepted.first(where: { loose(norm($0)) == loose(n) }) {
            return Grade(correct: true, note: "Achte auf Akzente und Apostrophe: \(match)")
        }
        if let match = accepted.first(where: { compact($0) == compact(n) }) {
            return Grade(correct: true, note: "Achte auf die Schreibweise: \(match)")
        }
        let got = n.split(separator: " ").map(String.init)
        for a in accepted {
            let want = norm(a).split(separator: " ").map(String.init)
            if want.count != got.count { continue }
            var typos = 0
            var ok = true
            for i in want.indices where want[i] != got[i] {
                let x = loose(want[i])
                let y = loose(got[i])
                if x == y { continue }
                if known.contains(y) || !isTypo(x, y) {
                    ok = false
                    break
                }
                typos += 1
            }
            if ok && typos > 0 && typos <= (want.count >= 6 ? 2 : 1) {
                return Grade(correct: true, note: "Kleiner Tippfehler – richtig: \(a)")
            }
        }
        return Grade(correct: false)
    }
}
