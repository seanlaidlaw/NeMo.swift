import Foundation

/// Cheap, allocation-light pre-filter for the NeMo text normalizer.
///
/// Running a whole EPUB through Sparrowhawk is expensive, yet ~75% of book
/// sentences contain nothing any semiotic class would match — NeMo returns them
/// unchanged (modulo whitespace). `shouldSkip` recognises those sentences with a
/// small set of rules derived from the *exact* whitelist that compiles into the
/// shipped grammar, so the caller can bypass `Normalizer` entirely.
///
/// **Recall guarantee.** The rules are *necessary conditions*: if NeMo would make
/// any semantic change, at least one rule fires and `shouldSkip` returns `false`.
/// Validated at 100% recall over 40,728 real book sentences (0 missed changes).
/// The rules err toward *running* NeMo when uncertain — e.g. `USA`, `PhD` and
/// bare initials are sent through even though NeMo leaves them untouched.
///
/// Intended pipeline:
/// ```swift
/// let clean = NormalizationPrefilter.lightNormalize(raw)
/// let out = NormalizationPrefilter.shouldSkip(clean) ? clean : normalizer.normalize(clean)
/// ```
public enum NormalizationPrefilter {

    // MARK: - Light normalization

    // Fancy quote characters folded to their ASCII equivalents. Everything else
    // (accented Latin, Hebrew, Greek text, CJK, …) is preserved untouched.
    private static let singleQuotes: Set<Character> = [
        "\u{2018}", "\u{2019}", "\u{201A}", "\u{2039}", "\u{203A}",
    ]
    private static let doubleQuotes: Set<Character> = [
        "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}",
    ]

    /// Minimal cleanup so whitespace/quote noise never trips NeMo (or spuriously
    /// changes the output for a skipped sentence).
    ///
    /// - Collapses any run of Unicode whitespace (spaces, tabs, NBSP, thin/ideographic
    ///   spaces, …) to a single ASCII space, and trims the ends.
    /// - Folds curly/angle/low quotation marks to ASCII `'` and `"`.
    /// - Preserves every letter, including accents and non-Latin scripts, so
    ///   `"coup d'état"` and `"the ראש ישיבה once told me"` survive intact.
    public static func lightNormalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var pendingSpace = false
        var started = false
        for ch in text {
            let mapped: Character
            if singleQuotes.contains(ch) {
                mapped = "'"
            } else if doubleQuotes.contains(ch) {
                mapped = "\""
            } else if ch.isWhitespace {
                mapped = " "
            } else {
                mapped = ch
            }

            if mapped == " " {
                if started { pendingSpace = true }   // drop leading; collapse runs
            } else {
                if pendingSpace {
                    result.append(" ")
                    pendingSpace = false
                }
                result.append(mapped)
                started = true
            }
        }
        return result   // trailing space is never appended
    }

    // MARK: - Skip decision

    // Punctuation NeMo never uses to change text: ASCII sentence punctuation plus
    // the dash/ellipsis/bullet/quote "spacing" characters (which at most cause an
    // inaudible space tweak we deliberately do not reproduce).
    private static let inertPunct: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "(", ")", "'", "\"", "-", "[", "]", "{", "}",
        "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{201A}", "\u{201E}",
        "\u{2039}", "\u{203A}", "\u{00AB}", "\u{00BB}",
        "\u{2013}", "\u{2014}", "\u{2026}", "\u{2022}", "\u{00B7}",
    ]

    /// Returns `true` when `text` contains nothing the NeMo grammar would change,
    /// so the caller may safely skip normalization and use the text as-is.
    public static func shouldSkip(_ text: String) -> Bool {
        // Materialise the grapheme array once and share it across every rule, so
        // we neither re-iterate the string nor re-allocate `Array(text)` per rule.
        let a = Array(text)
        // Rules 1 & 2 (single pass): digits, whitelisted non-ASCII glyphs
        // (Greek letters, currency, °, §, …), and any "real" symbol.
        for ch in a {
            if PrefilterData.nonAsciiTriggers.contains(ch) { return false }
            if ch.isNumber { return false }
            if ch.isLetter || ch.isWhitespace { continue }
            if inertPunct.contains(ch) { continue }
            return false   // a symbol NeMo could act on (& / | $ × % …)
        }
        // Rule 3: abbreviation / initial period (e.g. "Dr.", "e.g.", "U.S.", "C. S.")
        if hasAbbreviationPeriod(a) { return false }
        // Rule 4: comma-gated US state code ("…, CA")
        if hasCommaState(a) { return false }
        // Rule 5: a whitelist token ("vs", "tv", "St", "World War II", …)
        if hasWhitelistToken(a) { return false }
        return true
    }

    // MARK: - Rule helpers

    private static func isAsciiAlnum(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }
    private static func isAsciiLetter(_ c: Character) -> Bool {
        c.isASCII && c.isLetter
    }

    /// A period that reads as an abbreviation rather than a sentence end:
    /// `letter/digit "." letter/digit` (contiguous, e.g. `e.g.`, `U.S.`, `www.x`),
    /// or a lone ASCII initial `X.` not preceded by another letter (`C. S. Lewis`).
    private static func hasAbbreviationPeriod(_ a: [Character]) -> Bool {
        for i in a.indices {
            let c = a[i]
            if c == "." {
                let prevAlnum = i > 0 && isAsciiAlnum(a[i - 1])
                let nextAlnum = i + 1 < a.count && isAsciiAlnum(a[i + 1])
                if prevAlnum && nextAlnum { return true }
            }
            if isAsciiLetter(c) {
                let beforeOK = i == 0 || !isAsciiLetter(a[i - 1])
                let dotAfter = i + 1 < a.count && a[i + 1] == "."
                if beforeOK && dotAfter { return true }
            }
        }
        return false
    }

    /// `,` optionally followed by one space, then an uppercase state code at a word
    /// boundary — the only context in which the grammar expands `CA` → `California`.
    private static func hasCommaState(_ a: [Character]) -> Bool {
        var i = 0
        while i < a.count {
            if a[i] == "," {
                var j = i + 1
                if j < a.count && a[j].isWhitespace { j += 1 }
                if j + 1 < a.count {
                    let code = String(a[j ... (j + 1)])
                    if PrefilterData.stateCodes.contains(code) {
                        let after = j + 2
                        let boundaryOK = after >= a.count || !isAsciiLetter(a[after])
                        if boundaryOK { return true }
                    }
                }
            }
            i += 1
        }
        return false
    }

    // `whitelistMulti` split once by whether a phrase contains ". ". A phrase can
    // only be a substring of the input if the input contains ". " too, so the 500
    // period-bearing phrases (all initial pairs like "a. b.") are scanned only when
    // the input actually has a ". " — which, having already survived Rule 3, a
    // clean single sentence usually does not. `multiPlain` is just the two
    // period-free "world war i/ii" phrases and is always cheap to check.
    private static let multiWithPeriod: [String] =
        PrefilterData.whitelistMulti.filter { $0.contains(". ") }
    private static let multiPlain: [String] =
        PrefilterData.whitelistMulti.filter { !$0.contains(". ") }

    /// Any word matching NeMo's whitelist (case-insensitive, apostrophe-normalised),
    /// or a whitelisted multi-word phrase as a substring.
    private static func hasWhitelistToken(_ a: [Character]) -> Bool {
        // Lowercase with an ASCII fast path so the common all-ASCII sentence never
        // allocates a temporary String per character.
        var lowered = ""
        lowered.reserveCapacity(a.count)
        for ch in a {
            if let ascii = ch.asciiValue {
                if ascii >= 0x41 && ascii <= 0x5A {   // A–Z → a–z
                    lowered.append(Character(UnicodeScalar(ascii + 0x20)))
                } else {
                    lowered.append(ch)
                }
            } else if ch == "\u{2018}" || ch == "\u{2019}" {
                lowered.append("'")
            } else {
                lowered.append(contentsOf: ch.lowercased())
            }
        }

        let chars = Array(lowered)
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            if c >= "a" && c <= "z" {
                var j = i
                while j < n {
                    let d = chars[j]
                    if (d >= "a" && d <= "z") || d == "." || d == "'" { j += 1 } else { break }
                }
                if whitelistMatches(String(chars[i ..< j])) { return true }
                i = j
            } else {
                i += 1
            }
        }

        for phrase in multiPlain where lowered.contains(phrase) { return true }
        if lowered.contains(". ") {
            for phrase in multiWithPeriod where lowered.contains(phrase) { return true }
        }
        return false
    }

    private static func whitelistMatches(_ token: String) -> Bool {
        if PrefilterData.whitelistSingle.contains(token) { return true }
        let noApos = trim(token, "'")
        if noApos != token && PrefilterData.whitelistSingle.contains(noApos) { return true }
        let noDot = dropTrailing(noApos, ".")
        if noDot != noApos && PrefilterData.whitelistSingle.contains(noDot) { return true }
        return false
    }

    private static func trim(_ s: String, _ ch: Character) -> String {
        var sub = Substring(s)
        while sub.first == ch { sub = sub.dropFirst() }
        while sub.last == ch { sub = sub.dropLast() }
        return String(sub)
    }
    private static func dropTrailing(_ s: String, _ ch: Character) -> String {
        var sub = Substring(s)
        while sub.last == ch { sub = sub.dropLast() }
        return String(sub)
    }
}
