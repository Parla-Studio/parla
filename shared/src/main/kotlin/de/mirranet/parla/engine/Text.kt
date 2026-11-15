package de.mirranet.parla.engine

import java.text.Normalizer

/** Text normalisation and answer grading, mirroring the classic "accept small slips" behaviour. */
object Text {

    private val PUNCT = Regex("[¿¡.,!?;:\"«»…“”„]")
    private val SPACES = Regex("\\s+")
    private val MARKS = Regex("\\p{M}+")

    fun tokens(s: String): List<String> =
        s.replace(PUNCT, " ").trim().split(SPACES).filter { it.isNotEmpty() }

    fun norm(s: String): String =
        s.lowercase().replace('’', '\'').replace('‘', '\'').replace('`', '\'').replace('´', '\'')
            .replace(PUNCT, " ").replace(SPACES, " ").trim()

    /** Removes accents, umlauts, ligatures and apostrophes for a lenient second comparison. */
    fun loose(s: String): String =
        Normalizer.normalize(s.replace("'", ""), Normalizer.Form.NFD).replace(MARKS, "")
            .replace("ß", "ss").replace("œ", "oe").replace("æ", "ae")

    /** Without spaces and hyphens: "e-mail" = "email", "as-tu" = "as tu". */
    fun compact(s: String): String = loose(norm(s)).replace(" ", "").replace("-", "")

    /** Form of a word used to look it up in a course's vocabulary (see CourseIndex.known). */
    fun key(word: String): String = loose(norm(word))

    /** Edit distance where swapping two neighbouring letters ("thnak") counts as one edit. */
    fun levenshtein(a: String, b: String): Int {
        val d = Array(a.length + 1) { i -> IntArray(b.length + 1) { j -> if (i == 0) j else if (j == 0) i else 0 } }
        for (i in 1..a.length) {
            for (j in 1..b.length) {
                val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                d[i][j] = minOf(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) {
                    d[i][j] = minOf(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.length][b.length]
    }

    private val ENDINGS = listOf("s", "n", "e", "t", "d", "r", "m", "es", "en", "er", "em", "ed")

    /** Different endings are usually grammar (eat/eats, petit/petite, einen/einem), not a typo. */
    private fun grammar(x: String, y: String): Boolean =
        ENDINGS.any { x + it == y || y + it == x } ||
            (x.length == y.length && x.length > 1 && x.dropLast(1) == y.dropLast(1) &&
                x.last() in "nmrse" && y.last() in "nmrse")

    /**
     * Whether `typed` is a slip of the keyboard for `wanted` (both already loose): one wrong, missing, extra or
     * swapped letter (two in words of 8+ letters). Very short words only allow swapped letters, and words under 6
     * letters must start with the right letter – otherwise "he"/"she" or "cat"/"car" would pass.
     */
    private fun isTypo(wanted: String, typed: String): Boolean {
        if (grammar(wanted, typed) || wanted.length < 3) return false
        val d = levenshtein(wanted, typed)
        if (wanted.length == 3) return d == 1 && wanted.toList().sorted() == typed.toList().sorted()
        if (wanted.length < 6 && wanted.first() != typed.firstOrNull()) return false
        return d <= if (wanted.length >= 8) 2 else 1
    }

    data class Grade(val correct: Boolean, val note: String? = null)

    /**
     * Grades free text against the accepted answers. Punctuation, capital letters, accents, apostrophes and
     * hyphens never make an answer wrong; small typos are accepted with a note (one word in short sentences, two in
     * sentences of 6+ words). `known` are the course's words in the answer language (see CourseIndex.known):
     * a typed word that is itself a real word (ist/isst, women/woman) is a mistake, not a typo.
     */
    fun grade(input: String, accepted: List<String>, known: Set<String> = emptySet()): Grade {
        val n = norm(input)
        if (n.isEmpty()) return Grade(false)
        if (accepted.any { norm(it) == n }) return Grade(true)
        accepted.firstOrNull { loose(norm(it)) == loose(n) }?.let {
            return Grade(true, "Achte auf Akzente und Apostrophe: $it")
        }
        accepted.firstOrNull { compact(it) == compact(n) }?.let {
            return Grade(true, "Achte auf die Schreibweise: $it")
        }
        val got = n.split(' ')
        for (a in accepted) {
            val want = norm(a).split(' ')
            if (want.size != got.size) continue
            var typos = 0
            var ok = true
            for (i in want.indices) {
                if (want[i] == got[i]) continue
                val x = loose(want[i])
                val y = loose(got[i])
                if (x == y) continue
                if (y in known || !isTypo(x, y)) {
                    ok = false
                    break
                }
                typos++
            }
            if (ok && typos > 0 && typos <= if (want.size >= 6) 2 else 1) {
                return Grade(true, "Kleiner Tippfehler – richtig: $a")
            }
        }
        return Grade(false)
    }
}
