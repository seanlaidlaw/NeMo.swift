// CSparrowhawk.mm
//
// ObjC++ implementation of the C API defined in CSparrowhawk.h.
// Wraps speech::sparrowhawk::Normalizer (anand-nv fork, branch nemo_tests).
//
// Sparrowhawk API (from normalizer.h):
//   Normalizer()                               — default constructor
//   bool Setup(const string& config_filename,
//              const string& pathname_prefix)  — loads dir/config_filename, parses
//                                               the proto and all grammars
//   bool Normalize(const string& input,
//                  string* output) const        — const, thread-safe after Setup
//
// Header search path comes from the Sparrowhawk.xcframework binary target.

#include "CSparrowhawk.h"

#include "sparrowhawk/normalizer.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <stdexcept>
#include <string>

// Register VectorFst<StdArc> and ConstFst<StdArc> with OpenFst's type registry
// so that Fst::Read() can deserialize the .far grammar archives at runtime.
//
// The tricky part: SPM compiles CSparrowhawk.mm with -fvisibility=hidden, so
// any template instantiation here (including GenericRegister::GetRegister)
// gets hidden linkage and becomes a private local singleton — separate from the
// xcframework's globally-linked singleton that Fst::Read() queries.
//
// Fix: declare GenericRegister<...> and FstRegister<StdArc> as extern template
// so that CSparrowhawk.o emits NO local GetRegister() function. Every call to
// GetRegister() then links to the xcframework's global T symbol (0x139754),
// which owns the one registry that Fst::Read() also consults.
#include <fst/vector-fst.h>
#include <fst/const-fst.h>
#include <fst/register.h>

// Suppress local instantiation of GenericRegister and FstRegister<StdArc>.
// The xcframework exports these as T (global) symbols; referencing them via
// extern template ensures the linker resolves all calls to those globals.
extern template class fst::GenericRegister<
    std::string,
    fst::FstRegisterEntry<fst::StdArc>,
    fst::FstRegister<fst::StdArc>>;
extern template class fst::FstRegister<fst::StdArc>;

namespace {
    // Constructors call FstRegister<StdArc>::GetRegister() — now resolved to
    // the xcframework's global singleton — then SetEntry("vector"/"const", …).
    static const fst::FstRegisterer<fst::VectorFst<fst::StdArc>> kVectorFstReg;
    static const fst::FstRegisterer<fst::ConstFst<fst::StdArc>>  kConstFstReg;
}

namespace sh = speech::sparrowhawk;

struct SHNormalizerState {
    sh::Normalizer* normalizer;
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
        // Split full path into directory (with trailing '/') + filename.
        // Setup(filename, dir) calls LoadGrammar(sub_config, dir) which
        // concatenates dir + sub_config directly (no '/' added), so dir MUST
        // end with '/'.  Setup itself adds its own '/' between dir and filename.
        std::string path(config_path);
        auto slash = path.rfind('/');
        std::string dir      = (slash == std::string::npos) ? "./" : path.substr(0, slash + 1);
        std::string filename = (slash == std::string::npos) ? path : path.substr(slash + 1);

        state->normalizer = new sh::Normalizer();
        if (!state->normalizer->Setup(filename, dir)) {
            fprintf(stderr, "CSparrowhawk: Normalizer::Setup failed for: %s\n", config_path);
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
