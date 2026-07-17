// CSparrowhawk.h
//
// Pure-C API over the Sparrowhawk C++ normalizer.
// Called from Swift (Swift cannot import C++ directly) via the CSparrowhawk target.
//
// Thread-safety: sh_normalizer_create / sh_normalizer_free are NOT thread-safe.
// Call them once from a single thread. sh_normalizer_normalize IS thread-safe
// once the normalizer is created (the underlying Sparrowhawk Normalizer is const
// after Initialize). Serialize multiple concurrent normalizations via the
// TextNormalization.Normalizer Swift wrapper which enforces this.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>

/// Opaque handle to a sparrowhawk::Normalizer instance.
typedef void* SHNormalizerRef;

/// Create and initialize a Sparrowhawk normalizer from an ASCII proto config file.
///
/// @param config_path  Absolute path to the sparrowhawk_configuration_pp.ascii_proto
///                     file. All grammar paths inside it must also be absolute.
/// @return             An opaque normalizer handle, or NULL if initialization failed.
///                     Call sh_normalizer_free() when done.
SHNormalizerRef sh_normalizer_create(const char* config_path);

/// Normalize a single input string (one sentence / utterance).
///
/// @param normalizer   Handle returned by sh_normalizer_create().
/// @param input        UTF-8 input text.
/// @param output       On success, *output is set to a newly-allocated C string
///                     containing the normalized text. Caller must free it with
///                     sh_string_free().
/// @return             true on success, false on failure (*output is unchanged).
bool sh_normalizer_normalize(SHNormalizerRef normalizer,
                             const char* input,
                             char** output);

/// Free a normalizer handle returned by sh_normalizer_create().
void sh_normalizer_free(SHNormalizerRef normalizer);

/// Free a string returned in *output by sh_normalizer_normalize().
void sh_string_free(char* str);

#ifdef __cplusplus
}  // extern "C"
#endif
