# NeMoTextNormalizationSwift — Agent Guide

Engineering context for agents working on this package. Read this before touching
any build, integration, or release work.

## Architecture (4 layers)

```
Sparrowhawk xcframework          ← pre-built static libs (C++)
    ↓
CSparrowhawk (ObjC++ shim)       ← Sources/CSparrowhawk/CSparrowhawk.mm
    ↓
TextNormalization (Swift facade) ← Sources/TextNormalization/
    + .far grammar resources     ← Sources/TextNormalization/Resources/en_tn_grammars_cased/
```

1. **`Sparrowhawk` binaryTarget** — xcframework containing merged static libs: OpenFst 1.8.3,
   Thrax 1.3.4, protobuf 2.5.0, re2 2022-02-01, Sparrowhawk (`anand-nv/sparrowhawk@nemo_tests`).
   Two slices: `ios-arm64` (device, 195 MB) + `ios-arm64_x86_64-simulator` (fat, ~400 MB).
   613 MB on disk, 76 MB zipped. **NOT in git** — see "Binary distribution" below.

2. **`CSparrowhawk`** — ObjC++ (`CSparrowhawk.mm`) exposing a thin C API
   (`sh_normalizer_create`, `sh_normalizer_normalize`, `sh_normalizer_free`, `sh_string_free`)
   over `speech::sparrowhawk::Normalizer`. The FST type-registry `extern template` block is
   **load-bearing** (see its dedicated section below).

3. **`TextNormalization`** — Swift facade (`Normalizer.swift`) that wraps the C API behind an
   `NSLock`, plus `GrammarBundle.swift` which writes a multi-level temp-dir config structure
   at init time.

4. **`.far` grammars** — ~9 MB committed in-repo:
   - `en_tn_grammars_cased/classify/tokenize_and_classify.far`
   - `en_tn_grammars_cased/verbalize/verbalize.far`
   - `en_tn_grammars_cased/verbalize/post_process.far`

## Build & Test

```bash
# Discover a concrete simulator UDID (bare name is ambiguous)
SIM=$(xcrun simctl list devices available | grep -E 'iPhone [0-9]' \
      | grep -oE '\([0-9A-F-]{36}\)' | head -1 | tr -d '()')
# or hard-code: SIM="72CE18E3-E134-44D5-AD8C-740FA5551B5A"

# Build
xcodebuild -scheme NeMoTextNormalizationSwift \
  -destination "platform=iOS Simulator,id=$SIM" build

# Test (expected: 20 suites passed, 7 known issues, 0 unexpected failures)
xcodebuild test -scheme NeMoTextNormalizationSwift \
  -destination "platform=iOS Simulator,id=$SIM"

# Verify device slice integrity BEFORE any release
ar -t Frameworks/Sparrowhawk.xcframework/ios-arm64/libSparrowhawk.a | wc -l
# → must print 213. Anything less means the archive was accidentally truncated.
```

Tests run on the **simulator and macOS host** — there are no on-device test runs.

## Binary Distribution

`Frameworks/Sparrowhawk.xcframework` is **gitignored**. It is distributed as a
**GitHub release asset** (`Sparrowhawk.xcframework.zip`) and fetched by SPM via
`binaryTarget(url:checksum:)` in `Package.swift`.

- Each git tag is self-consistent: the `Package.swift` committed at tag `vX.Y.Z`
  has the url and checksum for the asset built at that exact version.
- An SPM consumer with `.package(url:…, from: "x.y.z")` auto-resolves to the highest
  compatible tag. This works because every tag is self-consistent.
- Release automation: `Scripts/release.sh [--patch|--minor|--major|<X.Y.Z>]`.
  It zips, checksums, rewrites `Package.swift` via `Scripts/_update_binary_target.py`,
  commits, tags, pushes, and uploads the GitHub Release asset in one shot.
- The `// managed-by-release: url` and `// managed-by-release: checksum` marker
  comments in `Package.swift` are the edit anchors for `_update_binary_target.py`.
  **Never hand-edit the url/checksum lines** — the release script owns them.

See `RELEASING.md` for the full release workflow.

To rebuild the xcframework locally (takes ~30 min):

```bash
bash Scripts/build_sparrowhawk_ios.sh
```

## ⚠ NEVER Manipulate the xcframework with `ar`/`lipo`

This is the most expensive lesson from the initial development. **Do not use `ar`,
`lipo`, `ranlib`, or `libtool` to manually modify any `.a` inside the xcframework.**

**What went wrong in v0.1.0:** During debugging, manual `ar d`/`ar q` surgery was
performed to replace a single `protobuf_parser.o` in the device slice. The operation
accidentally created a brand-new 2-object archive (index + protobuf_parser.o) instead
of replacing the object within the existing 213-object archive. The xcframework shipped
with a 99 KB device lib (should be 195 MB) — the device slice was completely broken.

**The fix required:** extract the patched `protobuf_parser.o` from the broken lib,
take the full build slice from `build/sparrowhawk/slices/iphoneos-arm64/libSparrowhawk.a`
(which was untouched), graft the patched object in, and re-release as v0.1.1.

**The rule:** if any object inside the xcframework needs changing, rebuild the entire
affected slice via `build_sparrowhawk_ios.sh` and re-assemble the xcframework. The
build slices at `build/sparrowhawk/slices/` are the authoritative source; the xcframework
is a packaging artifact assembled from them, not an in-place-editable archive.

**Verify before any release:**

```bash
ar -t Frameworks/Sparrowhawk.xcframework/ios-arm64/libSparrowhawk.a | wc -l
# → 213
ar -t <(lipo Frameworks/Sparrowhawk.xcframework/ios-arm64_x86_64-simulator/libSparrowhawk.a \
        -thin arm64 -output /dev/stdout 2>/dev/null) | wc -l
# → 213
```

## FST Type-Registry / `-fvisibility=hidden` Invariant

`CSparrowhawk.mm` contains this block — **do not remove it:**

```cpp
extern template class fst::GenericRegister<
    std::string,
    fst::FstRegisterEntry<fst::StdArc>,
    fst::FstRegister<fst::StdArc>>;
extern template class fst::FstRegister<fst::StdArc>;

// ...
static const fst::FstRegisterer<fst::VectorFst<fst::StdArc>> kVectorFstReg;
static const fst::FstRegisterer<fst::ConstFst<fst::StdArc>>  kConstFstReg;
```

**Why it's load-bearing:** SPM compiles `CSparrowhawk.mm` with `-fvisibility=hidden`.
Any template instantiation in that translation unit (including `GenericRegister::GetRegister`)
gets hidden linkage and becomes a private local singleton — separate from the xcframework's
globally-linked singleton that `Fst::Read()` uses to deserialise `.far` archives. The
`extern template` declarations suppress the local instantiation, so every call to
`GetRegister()` resolves to the xcframework's global symbol. Without this, `Fst::Read()`
silently fails to find the registered FST types and the normalizer produces no output.

## GrammarBundle Config Indirection

Sparrowhawk's `RuleSystem::LoadGrammar` concatenates `prefix + grammar_file` with **no
`/` inserted**. Therefore `GrammarBundle.swift`:

1. Creates a per-process temp directory (suffix: PID).
2. Creates **symlinks** inside it pointing to the bundle's `classify/` and `verbalize/`
   directories (no large file copying).
3. Passes `Setup(filename, dir)` where `dir` ends with `/`.
4. Writes four `.ascii_proto` config files into the temp dir:
   - `config.ascii_proto` (top-level, passed to `sh_normalizer_create`)
   - `tokenizer.ascii_proto`, `verbalizer.ascii_proto`, `postprocessor.ascii_proto`

**Bundle root placement:** the grammar resources are copied to the bundle **root** (not
`Resources/`). Using a `Resources/` subdirectory causes codesign to detect the bundle as
macOS-format and reject it on iOS builds. The `Package.swift` `.copy("Resources/en_tn_grammars_cased")`
rule deliberately omits the `Resources/` prefix in the copy destination.

The `Bundle.module.url(forResource:withExtension:subdirectory:)` calls in `GrammarBundle`
resolve to `<bundle>/en_tn_grammars_cased/{classify,verbalize}/…`.

## Output Post-Processing

`normalize()` applies three transformations to the raw Sparrowhawk output:

1. `U+00A0` (non-breaking space) → regular space — Sparrowhawk emits these between tokens.
2. `" sil "` → `", "` — the verbalizer emits a `sil` pause token for comma-separated
   dates etc.; the Python NeMo normalizer turns these into commas.
3. `.trimmingCharacters(in: .whitespaces)` — leading/trailing whitespace.

**`postProcessPunct`** is **opt-in** (default `false`). Pass `normalize(text, punctPostProcess: true)`
for TTS pipelines where input spacing around punctuation should be preserved. It is a Swift
port of NeMo's `post_process_punct()` from `data_loader_utils.py` — character-level space
alignment between the original input and the normalized output.

## Thread Safety & Lifecycle

- `Normalizer` is `@unchecked Sendable`.
- All `normalize()` calls are serialised by an `NSLock` because Sparrowhawk's internal FST
  registry and `std::cerr` logging are not concurrency-safe.
- `init()` is **expensive** (parses `.far` archives — typically 10–100 ms). **Create one
  instance per app and reuse it.** Never create a new `Normalizer` per-request.
- English only. Input must be cased (lowercase input causes grammars to miss semiotic classes).
- **One sentence at a time.** Multi-sentence text should be split before calling `normalize`.
  (Matches how upstream `NeMo Normalizer.normalize` works with `split_text_into_sentences=True`.)

## Tests

20 `@Suite`s, one per fixture file in
`Tests/TextNormalizationTests/Resources/data_text_normalization/`.
Data format: `input~expected` (tilde-separated).

**The 7 `withKnownIssue` cases are grammar limitations, not regressions.** Do NOT treat
them as bugs to fix:

| Suite | Input | Issue |
|---|---|---|
| Money | `"The price for each canned salmon is $5 , each bottle of peanut butter is $3"` | Grammar drops space before `,` in `$5 , $3` pattern |
| Money | `"$0.5/hr is the total cost."` | `/hr` not normalised to "per hour" |
| Roman | `"Sam II"`, `"Chapter IV"`, `"PART XL"` | Context-dependent resolution; grammar can't tell ordinal from name |
| Serial | `"1-413-te-b-1-5"` | Mixed serial with 3-digit phone segment |
| Punctuation | `"114...48"` | Grammar adds extra space before `...` |

**Fixture files are not auto-populated.** `SpecRunnerTests.swift` references a
`Scripts/copy_test_fixtures.sh` that does not exist. Populate
`Tests/TextNormalizationTests/Resources/data_text_normalization/` manually from the
NeMo-text-processing repo. When a fixture file is absent, `loadCases()` returns `[]`
and the suite is silently skipped (not a compile error).

Tests run on **simulator and macOS host**. There is no on-device test target.

## Releasing

```bash
Scripts/release.sh               # bump patch (default)
Scripts/release.sh --minor
Scripts/release.sh 1.2.3
```

Requires: `gh` CLI authenticated, `Frameworks/Sparrowhawk.xcframework` present and
verified (213 objects per slice), clean working tree (Package.swift dirty is OK).

The script edits `Package.swift`'s `// managed-by-release:` marker lines automatically.
Never hand-edit the `url:` or `checksum:` values in the `binaryTarget` block.

See `RELEASING.md` for the full flow.

## Rebuilding from Scratch

```bash
# 1. Build the native Sparrowhawk stack (~30 min, requires autotools + CMake + Homebrew)
bash Scripts/build_sparrowhawk_ios.sh

# 2. Recompile the .far grammar archives (requires nemo-tn conda env)
#    conda activate nemo-tn  (python 3.10, pynini==2.1.6.post1, nemo_text_processing)
bash Scripts/export_grammars.sh [path/to/NeMo-text-processing]
```

**What `build_sparrowhawk_ios.sh` patches (each patch class is required):**

- `patch_protobuf_for_arm64` — adds `__aarch64__ && __APPLE__` case to protobuf 2.5.0's
  `platform_macros.h`; the 2013 code otherwise `#error`s on Apple Silicon.
- `update_autotools_config_scripts` — replaces stale 2013-era `config.sub`/`config.guess`
  with Homebrew automake copies so `arm64`/`ios` target triples are accepted.
- `patch_thrax_for_openfst183` — fixes Thrax 1.3.4 for OpenFst 1.8.3 + modern Clang
  (missing `fst/types.h`, removed `fst::StringSplit`, `fst::make_unique` → `std::`).
- `patch_thrax_api_changes` — fixes OpenFst 1.8.3 API breaks (scoped `PdtComposeFilter`
  enum, removed `MakeArcMapFst`, LogArc `IsPath<LogWeight>` static_assert failures).
- `patch_openfst_source` — fixes `bi-table.h` copy ctor referencing renamed member `s_` → `selector_`.
- `patch_openfst_for_cross_compile` — rewrites OpenFst's float-equality configure check
  that hard-fails under `cross_compiling=yes` (iOS cross-build always triggers this).
- `patch_sparrowhawk_serializer` — escapes literal `"` in string values in
  `protobuf_serializer.cc` (inputs like `6" pipe` produced malformed proto text).
- `patch_sparrowhawk_parser` — fixes `protobuf_parser.cc` handling of unescaped
  double-quotes at the start of token text (field-name-aware peek with ArcIterator).

After running the build script, verify both slices before releasing:

```bash
ar -t Frameworks/Sparrowhawk.xcframework/ios-arm64/libSparrowhawk.a | wc -l
# → 213
```

## SourceKit False Positives

SourceKit regularly reports "Cannot find type 'Book' in scope", "No such module
'CSparrowhawk'", etc. These are false positives from SourceKit's incomplete project
context. **Always confirm with a real `xcodebuild` build before treating any error as real.**
