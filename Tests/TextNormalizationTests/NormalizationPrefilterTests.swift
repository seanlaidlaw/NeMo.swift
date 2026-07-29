import Foundation
import Testing
@testable import TextNormalization

// Guards the pre-filter's recall guarantee: anything NeMo would change must NOT
// be skipped; genuine no-ops should be. Cases mirror ground truth obtained by
// running the real Sparrowhawk grammar (see design notes).

@Suite struct NormalizationPrefilterLightNormalizeTests {
    @Test func foldsFancyQuotesToAscii() {
        #expect(NormalizationPrefilter.lightNormalize("\u{201C}Hello,\u{201D} he said")
            == "\"Hello,\" he said")
        #expect(NormalizationPrefilter.lightNormalize("the word \u{2018}anarchy\u{2019}")
            == "the word 'anarchy'")
    }

    @Test func collapsesAndTrimsWhitespace() {
        #expect(NormalizationPrefilter.lightNormalize("  a\u{00A0}\u{00A0}b\t c  ") == "a b c")
    }

    @Test func preservesNonAsciiLetters() {
        #expect(NormalizationPrefilter.lightNormalize("coup d\u{2019}\u{00E9}tat") == "coup d'\u{00E9}tat")
        // Hebrew survives untouched
        let he = "the \u{05E8}\u{05D0}\u{05E9} once"
        #expect(NormalizationPrefilter.lightNormalize(he) == he)
    }
}

@Suite struct NormalizationPrefilterSkipTests {
    // Sentences with nothing for NeMo to do → skippable.
    @Test(arguments: [
        "The cat sat on the mat",
        "All rights reserved.",
        "Why Marriages Succeed or Fail with Nan Silver",
        "the US economy grew fast",          // bare acronyms unchanged by NeMo
        "the EU and GB and NATO and the FBI",
        "Chapter IV",                        // standalone roman not converted
        "Louis XIV", "Sam II", "II.",
        "Dr Smith", "Mr Brown", "Mt Everest",  // titles WITHOUT a period
        "STOP",
        "coup d'\u{00E9}tat",
        "the \u{05E8}\u{05D0}\u{05E9} once told me",
    ]) func skipsNoOps(_ s: String) {
        #expect(NormalizationPrefilter.shouldSkip(NormalizationPrefilter.lightNormalize(s)))
    }

    // Sentences NeMo changes → must be run.
    @Test(arguments: [
        "Copyright 2001 by John M. Gottman",   // digit + initial
        "get me a Dr. Pepper",                 // Dr. -> doctor
        "particularly Drs. Smith",             // Drs. -> doctors
        "St Augustine",                        // St -> Saint
        "World War II changed everything",     // whitelist multiword
        "he uses vs in citations",             // vs -> versus
        "released on iOS",                     // iOS -> IOS
        "C. S. Lewis wrote",                   // initials
        "e.g. this one", "i.e. that",          // contiguous letter.letter
        "cost is $5", "50%", "3/4 cup",        // symbols
        "the symbol \u{03B1} is used",         // Greek letter -> alpha
        "Springfield, CA",                     // comma-gated state
        "www.example.com",                     // url (letter.letter)
    ]) func runsSemioticSentences(_ s: String) {
        #expect(!NormalizationPrefilter.shouldSkip(NormalizationPrefilter.lightNormalize(s)))
    }
}
