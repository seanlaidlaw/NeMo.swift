// GrammarBundle.swift
//
// Resolves bundled FAR grammar files + proto config to absolute paths, and
// writes a temporary config file that Sparrowhawk can open at runtime.
//
// Why a temp config? Sparrowhawk's ASCII proto config references the FAR files
// by path. Bundle.module resource paths are unpredictable at runtime (inside
// a nested .bundle on device, a temp staging dir in tests, etc.), so we cannot
// commit absolute paths into the config file at build time. Instead, we resolve
// the actual absolute paths at init and write a fresh config to a temp dir.
//
// TODO (M2): After running export_grammars.sh and inspecting the pulled
//   sparrowhawk_configuration_pp.ascii_proto, update CONFIG_TEMPLATE below
//   to use the exact proto field names. Current names are from the Google
//   Sparrowhawk source and the anand-nv fork; verify they match.

import Foundation

enum GrammarBundleError: Error {
    case resourceNotFound(String)
    case configWriteFailed(String)
}

struct GrammarBundle {
    /// Absolute path to the temp config file. Pass to sh_normalizer_create().
    let configPath: String

    /// Write a temp Sparrowhawk config file with resolved absolute paths.
    /// Throws if any required bundle resource is missing.
    init() throws {
        let bundle = Bundle.module

        // ── Resolve FAR file paths from bundle ───────────────────────────────
        // Resources are copied with .copy("Resources") so they live at:
        //   <bundle>/Resources/en_tn_grammars_cased/{classify,verbalize}/...
        guard let classifyFar = bundle.url(
            forResource: "tokenize_and_classify",
            withExtension: "far",
            subdirectory: "Resources/en_tn_grammars_cased/classify"
        ) else {
            throw GrammarBundleError.resourceNotFound(
                "en_tn_grammars_cased/classify/tokenize_and_classify.far"
            )
        }

        guard let verbalizeFar = bundle.url(
            forResource: "verbalize",
            withExtension: "far",
            subdirectory: "Resources/en_tn_grammars_cased/verbalize"
        ) else {
            throw GrammarBundleError.resourceNotFound(
                "en_tn_grammars_cased/verbalize/verbalize.far"
            )
        }

        guard let postProcessFar = bundle.url(
            forResource: "post_process",
            withExtension: "far",
            subdirectory: "Resources/en_tn_grammars_cased/verbalize"
        ) else {
            throw GrammarBundleError.resourceNotFound(
                "en_tn_grammars_cased/verbalize/post_process.far"
            )
        }

        // ── Write temp config ─────────────────────────────────────────────────
        // TODO (M2): After pulling sparrowhawk_configuration_pp.ascii_proto from
        //   the Sparrowhawk fork, verify the exact field names below. The standard
        //   Sparrowhawk config uses:
        //     tokenizer_grammar, verbalizer_grammar, verbalizer_pp_grammar
        //   But the anand-nv fork may differ. Look at:
        //     Sources/TextNormalization/Resources/config/sparrowhawk_configuration_pp.ascii_proto
        //   after running export_grammars.sh.
        let configText = """
        tokenizer_grammar: "\(classifyFar.path)"
        verbalizer_grammar: "\(verbalizeFar.path)"
        verbalizer_pp_grammar: "\(postProcessFar.path)"
        """

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemo_tn", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)

        let configURL = tmpDir.appendingPathComponent("sparrowhawk_config.ascii_proto")
        do {
            try configText.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            throw GrammarBundleError.configWriteFailed(
                "Cannot write temp config to \(configURL.path): \(error)"
            )
        }

        configPath = configURL.path
    }
}
