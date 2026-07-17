// CSparrowhawk.mm
//
// ObjC++ implementation of the C API defined in CSparrowhawk.h.
// Wraps sparrowhawk::Normalizer with per-call thread-safety (the Sparrowhawk
// Normalizer is const after Initialize; we only need a mutex on creation/destruction).
//
// IMPORTANT — Header paths:
// These #include paths assume the Sparrowhawk.xcframework's Headers/ directory
// is on the header search path (set via the xcframework binary target in Package.swift).
// If header paths differ in the actual anand-nv fork, update them here.
//
// TODO (M1 spike): Once the Sparrowhawk fork is cloned and headers are inspected,
//   1. Verify the exact namespace: speech::sparrowhawk or just sparrowhawk
//   2. Verify the config proto class name and its protobuf include path
//   3. Verify the Normalizer constructor signature (SentenceSplitter* or nullptr)
//   4. Verify the Initialize() method signature
//   5. Update the proto field names in GrammarBundle.swift to match the .proto file

#include "CSparrowhawk.h"

// ── Sparrowhawk headers ──────────────────────────────────────────────────────
// These headers come from the xcframework's bundled Headers/ dir.
// Paths reflect the expected anand-nv/sparrowhawk source layout.
#include "sparrowhawk/normalizer.h"
#include "sparrowhawk/sparrowhawk_configuration.pb.h"

// ── Protobuf text format (for parsing ASCII proto config) ────────────────────
#include <google/protobuf/text_format.h>

// ── Standard library ─────────────────────────────────────────────────────────
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>

// ── Namespace alias ──────────────────────────────────────────────────────────
// Adjust if the anand-nv fork uses a different namespace.
namespace sh = speech::sparrowhawk;

// ── Internal state ───────────────────────────────────────────────────────────
struct SHNormalizerState {
    sh::Normalizer* normalizer;
    // sh::Normalizer::Normalize is const so multiple callers can share one
    // instance without locking — but we hold the mutex during init/deinit.
    std::mutex init_mutex;

    SHNormalizerState() : normalizer(nullptr) {}
    ~SHNormalizerState() { delete normalizer; normalizer = nullptr; }
};

// ── Public API ───────────────────────────────────────────────────────────────

SHNormalizerRef sh_normalizer_create(const char* config_path) {
    if (!config_path) return nullptr;

    auto* state = new SHNormalizerState();
    std::lock_guard<std::mutex> lock(state->init_mutex);

    try {
        // Read the ASCII proto config file
        std::ifstream f(config_path);
        if (!f.is_open()) {
            fprintf(stderr, "CSparrowhawk: cannot open config: %s\n", config_path);
            delete state;
            return nullptr;
        }
        std::ostringstream ss;
        ss << f.rdbuf();
        std::string config_text = ss.str();

        // Parse into the proto message
        // TODO (M1): Verify the exact proto message type from the fork's
        //   src/proto/sparrowhawk_configuration.proto.
        //   Common options:
        //     speech::utils::SparrowhawkConfiguration
        //     speech::sparrowhawk::SparrowhawkConfiguration
        speech::utils::SparrowhawkConfiguration config;
        if (!google::protobuf::TextFormat::ParseFromString(config_text, &config)) {
            fprintf(stderr, "CSparrowhawk: failed to parse config proto: %s\n", config_path);
            delete state;
            return nullptr;
        }

        // Create the Sparrowhawk Normalizer.
        // Passing nullptr for SentenceSplitter means no sentence-boundary splitting;
        // we handle chunking at the Swift level (per sentence/utterance).
        // TODO (M1): Verify constructor signature. If SentenceSplitter is required,
        //   construct a default one here.
        state->normalizer = new sh::Normalizer(nullptr);
        if (!state->normalizer->Initialize(config)) {
            fprintf(stderr, "CSparrowhawk: Normalizer::Initialize failed\n");
            delete state;
            return nullptr;
        }

        return static_cast<SHNormalizerRef>(state);
    } catch (const std::exception& e) {
        fprintf(stderr, "CSparrowhawk: exception during init: %s\n", e.what());
        delete state;
        return nullptr;
    }
}

bool sh_normalizer_normalize(SHNormalizerRef normalizer_ref,
                             const char* input,
                             char** output) {
    if (!normalizer_ref || !input || !output) return false;

    auto* state = static_cast<SHNormalizerState*>(normalizer_ref);
    if (!state->normalizer) return false;

    try {
        std::string result;
        if (!state->normalizer->Normalize(std::string(input), &result)) {
            // Sparrowhawk returns false + passes input through on failure;
            // fall back to the original text.
            result = std::string(input);
        }
        *output = strdup(result.c_str());
        return true;
    } catch (const std::exception& e) {
        fprintf(stderr, "CSparrowhawk: exception during normalize: %s\n", e.what());
        return false;
    }
}

void sh_normalizer_free(SHNormalizerRef normalizer_ref) {
    if (!normalizer_ref) return;
    delete static_cast<SHNormalizerState*>(normalizer_ref);
}

void sh_string_free(char* str) {
    free(str);
}
