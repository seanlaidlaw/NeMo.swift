// Normalizer.swift
//
// Public Swift facade over the Sparrowhawk text normalizer.
//
// Usage (TTS preprocessing, one shared instance per app):
//
//   let normalizer = try Normalizer()
//   let spoken = normalizer.normalize("The cost is $20.50 per item.")
//   // → "The cost is twenty dollars fifty cents per item."
//
// Initializing the normalizer is expensive (parses .far grammar files).
// Create it once and reuse across calls. It is Sendable and safe to call
// from any actor or thread concurrently.

import Foundation
import CSparrowhawk

/// Text Normalization errors.
public enum NormalizerError: Error, CustomStringConvertible {
    /// A required bundled grammar resource is missing (not generated yet).
    case grammarResourceMissing(String)
    /// The underlying Sparrowhawk library failed to initialize.
    case initializationFailed
    /// An expected temp config file could not be written.
    case configSetupFailed(String)

    public var description: String {
        switch self {
        case .grammarResourceMissing(let name):
            return "Grammar resource not found: \(name). Run Scripts/export_grammars.sh."
        case .initializationFailed:
            return "Sparrowhawk failed to initialize. Check config paths and grammar files."
        case .configSetupFailed(let detail):
            return "Config setup failed: \(detail)"
        }
    }
}

/// Converts written English text to its spoken form for TTS input.
///
/// Handles semiotic classes: cardinal numbers, ordinals, money, dates, times,
/// measurements, electronic (URLs, emails), telephone numbers, roman numerals,
/// whitelisted abbreviations (Dr., UN, FARC, etc.) and more.
///
/// Thread-safe. `Sendable`. Initialise once; the underlying Sparrowhawk
/// `Normalizer` is immutable after `Initialize()`.
public final class Normalizer: @unchecked Sendable {

    // The C handle to the Sparrowhawk normalizer.
    private let ref: SHNormalizerRef
    // Serialize normalize() calls: Sparrowhawk's internal FST registry
    // and logging (std::cerr) are not thread-safe across concurrent calls.
    private let lock = NSLock()

    // ── Init ──────────────────────────────────────────────────────────────────
    /// Load the bundled grammars and initialize the Sparrowhawk runtime.
    ///
    /// This is **expensive** (reads and parses the .far grammar archives —
    /// typically 10–100 ms). Call once and cache the result.
    ///
    /// - Throws: `NormalizerError` if the grammar resources are missing
    ///           (run `Scripts/export_grammars.sh` first) or if Sparrowhawk
    ///           initialization fails.
    public init() throws {
        // Write the temp config that points to the bundled .far paths
        let grammarBundle: GrammarBundle
        do {
            grammarBundle = try GrammarBundle()
        } catch GrammarBundleError.resourceNotFound(let name) {
            throw NormalizerError.grammarResourceMissing(name)
        } catch GrammarBundleError.configWriteFailed(let detail) {
            throw NormalizerError.configSetupFailed(detail)
        }

        // Create the underlying Sparrowhawk normalizer
        guard let normRef = sh_normalizer_create(grammarBundle.configPath) else {
            throw NormalizerError.initializationFailed
        }
        ref = normRef
    }

    deinit {
        sh_normalizer_free(ref)
    }

    // ── Normalize ─────────────────────────────────────────────────────────────
    /// Normalize a single English sentence or short text span.
    ///
    /// Input should be one sentence. For multi-sentence text, split on sentence
    /// boundaries first and call `normalize` on each (matches how the upstream
    /// `NeMo Normalizer.normalize` works with `split_text_into_sentences=True`).
    ///
    /// On internal failure (grammar path error, Sparrowhawk runtime fault), the
    /// input is returned unchanged so TTS can still proceed.
    ///
    /// - Parameters:
    ///   - text: UTF-8 English text.
    ///   - punctPostProcess: When `true`, re-align spaces around punctuation to
    ///     match the original input (port of NeMo's `post_process_punct`). Use
    ///     for TTS pipelines where the input spacing around punctuation should be
    ///     preserved rather than rewritten by the normalizer.
    /// - Returns: Spoken-form string (e.g. "$20.50" → "twenty dollars fifty cents").
    public func normalize(_ text: String, punctPostProcess: Bool = false) -> String {
        guard !text.isEmpty else { return text }

        lock.lock()
        defer { lock.unlock() }

        var outputPtr: UnsafeMutablePointer<CChar>? = nil
        let success = sh_normalizer_normalize(ref, text, &outputPtr)

        guard success, let ptr = outputPtr else {
            // Graceful degradation: pass text through unchanged
            return text
        }
        defer { sh_string_free(ptr) }
        // Sparrowhawk's postprocessor emits U+00A0 (non-breaking space) between
        // tokens. Replace all with regular spaces before returning.
        // The verbalizer also emits a "sil" token for silence/pause markers (from
        // comma-separated dates etc.); the Python NeMo normalizer post-processes
        // these into commas. Replicate that here.
        let result = String(cString: ptr)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: " sil ", with: ", ")
            .trimmingCharacters(in: .whitespaces)

        if punctPostProcess {
            return Normalizer.postProcessPunct(input: text, normalized: result)
        }
        return result
    }

    // ── postProcessPunct ──────────────────────────────────────────────────────
    // Port of NeMo's post_process_punct() from data_loader_utils.py.
    // Adjusts spaces around each punctuation mark in `normalized` to match the
    // spacing in `input`, using character-level index alignment.
    private static func postProcessPunct(input: String, normalized: String) -> String {
        // ``…`` → "…" replacement mirrors the Python pre-processing step.
        var adjustedInput = input
        if input.contains("``") && !normalized.contains("``") {
            adjustedInput = input.replacingOccurrences(of: "``", with: "\"")
        }
        let inputChars = adjustedInput.map { String($0) }
        var normChars  = normalized.map   { String($0) }

        // Python's string.punctuation, in order.
        let punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"

        for punct in punctuation {
            let ps = String(punct)
            guard inputChars.contains(ps) else { continue }

            let inputCount = inputChars.filter { $0 == ps }.count
            let normCount  = normChars.filter  { $0 == ps }.count
            let equal = (inputCount == normCount)

            var idxIn  = 0
            var idxOut = 0

            outerLoop: while true {
                guard let ni = (idxIn..<inputChars.count).first(where: { inputChars[$0] == ps }) else { break }
                guard let no = (idxOut..<normChars.count).first(where: { normChars[$0]  == ps }) else { break }
                idxIn  = ni
                idxOut = no

                if !equal {
                    let prevMatch = idxOut > 0 && idxIn > 0
                        && normChars[idxOut - 1] == inputChars[idxIn - 1]
                    let nextMatch = idxOut < normChars.count - 1 && idxIn < inputChars.count - 1
                        && normChars[idxOut + 1] == inputChars[idxIn + 1]
                    if !prevMatch && !nextMatch {
                        idxIn += 1
                        continue outerLoop
                    }
                }

                // Adjust space before the punctuation mark.
                if idxIn > 0 && idxOut > 0 {
                    if normChars[idxOut - 1] == " " && inputChars[idxIn - 1] != " " {
                        normChars[idxOut - 1] = ""          // remove unwanted space
                    } else if normChars[idxOut - 1] != " " && inputChars[idxIn - 1] == " " {
                        normChars[idxOut - 1] += " "        // append missing space
                    }
                }

                // Adjust space after the punctuation mark.
                if idxIn < inputChars.count - 1 && idxOut < normChars.count - 1 {
                    if normChars[idxOut + 1] == " " && inputChars[idxIn + 1] != " " {
                        normChars[idxOut + 1] = ""          // remove unwanted space
                    } else if normChars[idxOut + 1] != " " && inputChars[idxIn + 1] == " " {
                        normChars[idxOut] += " "            // append missing space after punct
                    }
                }

                idxOut += 1
                idxIn  += 1
            }
        }

        let joined = normChars.joined()
        // Collapse runs of multiple spaces that can result from "" deletions.
        return joined.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
    }
}
