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

    // The C handle to the Sparrowhawk normalizer. Thread-safe after init:
    // sh_normalizer_normalize is documented as const (read-only).
    private let ref: SHNormalizerRef

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
    /// - Parameter text: UTF-8 English text.
    /// - Returns: Spoken-form string (e.g. "$20.50" → "twenty dollars fifty cents").
    public func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var outputPtr: UnsafeMutablePointer<CChar>? = nil
        let success = sh_normalizer_normalize(ref, text, &outputPtr)

        guard success, let ptr = outputPtr else {
            // Graceful degradation: pass text through unchanged
            return text
        }
        defer { sh_string_free(ptr) }
        return String(cString: ptr)
    }
}
