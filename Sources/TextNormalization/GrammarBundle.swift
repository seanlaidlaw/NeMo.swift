// GrammarBundle.swift
//
// Resolves bundled FAR grammar files to absolute paths and writes the
// multi-level Sparrowhawk config structure that Normalizer::Setup() expects.
//
// Sparrowhawk config indirection (required by the C++ RuleSystem::LoadGrammar):
//
//   config.ascii_proto          ← passed to Normalizer::Setup()
//     tokenizer_grammar: "tokenizer.ascii_proto"
//     verbalizer_grammar: "verbalizer.ascii_proto"
//     postprocessor_grammar: "postprocessor.ascii_proto"
//
//   tokenizer.ascii_proto       ← loaded by RuleSystem::LoadGrammar
//     grammar_file: "classify/tokenize_and_classify.far"
//     grammar_name: "TokenizerClassifier"
//     rules { main: "TOKENIZE_AND_CLASSIFY" }
//
//   verbalizer.ascii_proto
//     grammar_file: "verbalize/verbalize.far"
//     grammar_name: "Verbalizer"
//     rules { main: "ALL" redup: "REDUP" }
//
//   postprocessor.ascii_proto
//     grammar_file: "verbalize/post_process.far"
//     grammar_name: "PostProcessor"
//     rules { main: "POSTPROCESSOR" }
//
// All paths in the sub-configs are relative to the temp directory prefix.
// We create symlinks from the temp dir into the bundle's resource directories
// so no large FAR files are copied.

import Foundation

enum GrammarBundleError: Error {
    case resourceNotFound(String)
    case configWriteFailed(String)
}

struct GrammarBundle {
    /// Absolute path to the main config file. Pass to sh_normalizer_create().
    let configPath: String

    init() throws {
        let bundle = Bundle.module

        // ── Locate FAR files in bundle ────────────────────────────────────────
        // Resources are copied with .copy("Resources/en_tn_grammars_cased") placing:
        //   <bundle>/en_tn_grammars_cased/classify/tokenize_and_classify.far
        //   <bundle>/en_tn_grammars_cased/verbalize/{verbalize,post_process}.far
        // (no "Resources/" prefix — placing at bundle root avoids the macOS
        // bundle format detection that makes codesign reject iOS resource bundles)
        //
        // Use url(forResource:withExtension:subdirectory:) for individual files
        // (more reliable than directory lookup, which may return nil for dirs).
        guard let classifyFar = bundle.url(
            forResource: "tokenize_and_classify",
            withExtension: "far",
            subdirectory: "en_tn_grammars_cased/classify"
        ) else {
            throw GrammarBundleError.resourceNotFound(
                "en_tn_grammars_cased/classify/tokenize_and_classify.far — run Scripts/export_grammars.sh"
            )
        }

        guard let verbalizeFar = bundle.url(
            forResource: "verbalize",
            withExtension: "far",
            subdirectory: "en_tn_grammars_cased/verbalize"
        ) else {
            throw GrammarBundleError.resourceNotFound(
                "en_tn_grammars_cased/verbalize/verbalize.far — run Scripts/export_grammars.sh"
            )
        }

        guard let postProcessFar = bundle.url(
            forResource: "post_process",
            withExtension: "far",
            subdirectory: "en_tn_grammars_cased/verbalize"
        ) else {
            throw GrammarBundleError.resourceNotFound(
                "en_tn_grammars_cased/verbalize/post_process.far — run Scripts/export_grammars.sh"
            )
        }

        let classifyDir = classifyFar.deletingLastPathComponent()
        let verbalizeDir = verbalizeFar.deletingLastPathComponent()

        // ── Create temp directory ─────────────────────────────────────────────
        // Sparrowhawk's RuleSystem::LoadGrammar concatenates prefix + grammar_file
        // directly (no '/' inserted), so all paths must be relative to the prefix
        // directory. We place config files here and symlink the FAR directories.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemo_tn_\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)

        // ── Symlink FAR directories into temp dir ─────────────────────────────
        // grammar_file: "classify/tokenize_and_classify.far" resolves to
        // tmpDir/classify/tokenize_and_classify.far via symlink → bundle classify dir.
        let symlinkClassify = tmpDir.appendingPathComponent("classify")
        let symlinkVerbalize = tmpDir.appendingPathComponent("verbalize")
        let fm = FileManager.default
        if !fm.fileExists(atPath: symlinkClassify.path) {
            try fm.createSymbolicLink(at: symlinkClassify, withDestinationURL: classifyDir)
        }
        if !fm.fileExists(atPath: symlinkVerbalize.path) {
            try fm.createSymbolicLink(at: symlinkVerbalize, withDestinationURL: verbalizeDir)
        }

        // ── Write config files ────────────────────────────────────────────────
        func write(_ text: String, to filename: String) throws {
            let url = tmpDir.appendingPathComponent(filename)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw GrammarBundleError.configWriteFailed(
                    "Cannot write \(filename) to \(tmpDir.path): \(error)"
                )
            }
        }

        try write("""
            tokenizer_grammar: "tokenizer.ascii_proto"
            verbalizer_grammar: "verbalizer.ascii_proto"
            postprocessor_grammar: "postprocessor.ascii_proto"
            """, to: "config.ascii_proto")

        try write("""
            grammar_file: "classify/tokenize_and_classify.far"
            grammar_name: "TokenizerClassifier"
            rules { main: "TOKENIZE_AND_CLASSIFY" }
            """, to: "tokenizer.ascii_proto")

        try write("""
            grammar_file: "verbalize/verbalize.far"
            grammar_name: "Verbalizer"
            rules { main: "ALL" redup: "REDUP" }
            """, to: "verbalizer.ascii_proto")

        try write("""
            grammar_file: "verbalize/post_process.far"
            grammar_name: "PostProcessor"
            rules { main: "POSTPROCESSOR" }
            """, to: "postprocessor.ascii_proto")

        configPath = tmpDir.appendingPathComponent("config.ascii_proto").path
    }
}
