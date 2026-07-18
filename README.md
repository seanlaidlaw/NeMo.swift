# NeMo.swift

Swift package for English text normalization (written → spoken form) for TTS pipelines.
Wraps NVIDIA NeMo's WFST grammars via the [Sparrowhawk](https://github.com/anand-nv/sparrowhawk/tree/nemo_tests)
runtime — the same grammars that power NeMo's `nemo_text_processing` Python library — compiled
to on-device OpenFst archives and packaged as a native iOS/macOS Swift package.

## Quick start

```swift
import TextNormalization

// Create once and reuse — init parses .far grammar archives (10–100 ms).
let normalizer = try Normalizer()

normalizer.normalize("The cost is $20.50 per item.")
// → "the cost is twenty dollars fifty cents per item"

normalizer.normalize("Call us at 1-800-555-0123.")
// → "call us at one eight hundred five five five zero one two three"

normalizer.normalize("She scored 9/10 on the test.")
// → "she scored nine tenths on the test"

// punctPostProcess: re-aligns spaces around punctuation to match the original input.
// Recommended for TTS pipelines where the input spacing should be preserved.
normalizer.normalize("Hello, world!", punctPostProcess: true)
// → "hello, world!"
```

## Installation

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/seanlaidlaw/NeMo.swift", from: "0.1.1"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "TextNormalization", package: "NeMo.swift"),
        ]
    ),
]
```

SPM downloads `Sparrowhawk.xcframework.zip` (~76 MB) from the GitHub release on first
resolve and caches it locally. Subsequent builds are instant.

### Xcode

**File → Add Package Dependencies** → paste
`https://github.com/seanlaidlaw/NeMo.swift` → select "Up to Next Major Version" from `0.1.1`.

## What it normalizes

The following semiotic classes are handled by the NeMo English TN WFST grammars:

| Class | Example input | Example output |
|---|---|---|
| Cardinal | `12,345` | `twelve thousand three hundred forty five` |
| Ordinal | `5th` | `fifth` |
| Decimal | `3.14` | `three point one four` |
| Fraction | `3/4` | `three quarters` |
| Money | `$20.50` | `twenty dollars fifty cents` |
| Measure | `5km` | `five kilometers` |
| Date | `January 5, 2012` | `january fifth twenty twelve` |
| Time | `4:30 p.m.` | `four thirty p m` |
| Telephone | `1-800-555-0123` | `one eight hundred five five five zero one two three` |
| Electronic | `user@example.com` | `user at example dot com` |
| Roman | `XIV` | `fourteen` |
| Serial/Range | `A01`, `10-20` | `a zero one`, `ten to twenty` |
| Whitelist | `Dr.`, `UN`, `NASA` | `doctor`, `united nations`, `n a s a` |
| Punctuation | `"hello"` | `hello` |
| Word | `AT&T`, `C++` | `a t and t`, `c plus plus` |

## Platform support

| Platform | Architecture | Status |
|---|---|---|
| iOS 16+ device | arm64 | ✓ |
| iOS 16+ simulator | arm64 (Apple Silicon) | ✓ |
| iOS 16+ simulator | x86_64 (Intel) | ✓ |
| macOS 15+ | arm64 / x86_64 (Rosetta) | ✓ (tests only; no macOS-native slice) |

## ⚠ Known limitations and trade-offs

### Binary size

The xcframework is large because it statically bundles the full WFST machinery:
OpenFst 1.8.3, Thrax 1.3.4, protobuf 2.5.0, re2, and Sparrowhawk — compiled separately
for each target architecture.

| What | Size |
|---|---|
| `Sparrowhawk.xcframework.zip` (SPM download) | ~76 MB |
| Expanded xcframework on disk (SPM cache) | ~613 MB |
| `.far` grammar files added to your app bundle | ~9 MB |
| Code actually linked into your app binary\* | ~4 MB |

\* Measured via linkmap on a test binary that exercises all 20 semiotic classes.
The linker pulls 75 of 213 `.o` files from the 195 MB device static lib; dead-stripping
removes another ~1.8 MB of unreferenced symbols. A production app that uses only a few
semiotic classes will link even less.

**In practice:** the main cost to your users is the ~9 MB always-present `.far` bundle
resources, not the 613 MB xcframework (which lives in the SPM cache, not in your app).

### English only, cased input

The grammars are compiled for English with cased input. Lowercase-only input will miss
many semiotic classes (e.g. `$20` will fail to normalize if the surrounding text is
all-lowercase). Pass text in its natural mixed-case form.

### One sentence at a time

`normalize(_:)` expects a single sentence. For multi-sentence text, split on sentence
boundaries first and call `normalize` on each segment. This matches the behavior of
NeMo's upstream `Normalizer.normalize(split_text_into_sentences=True)`.

### Expensive initialization

Parsing the `.far` grammar archives takes roughly 10–100 ms. **Create one `Normalizer`
instance per app and reuse it.** Constructing a new instance per-request will cause
noticeable latency.

### Known grammar failures (7 cases)

These inputs produce wrong output in the current grammar version. They are annotated
`withKnownIssue` in the test suite, not treated as regressions:

| Input | Expected | Actual | Issue |
|---|---|---|---|
| `"$5 , $3"` (in a sentence) | preserves ` ,` | drops space before `,` | Pattern not handled |
| `"$0.5/hr"` | `"…per hour"` | unit not normalized | `/hr` grammar missing |
| `"Sam II"` | `"sam the second"` | passes through unchanged | Ambiguous context |
| `"Chapter IV"` | `"chapter four"` | passes through | Ambiguous context |
| `"PART XL"` | `"part forty"` | passes through | Ambiguous context |
| `"1-413-te-b-1-5"` | serial form | phone-like match | Mixed serial/telephone |
| `"114...48"` | `"one hundred fourteen…forty eight"` | extra space before `...` | Ellipsis rule |

### Building from source is painful

The xcframework bundles C++ libraries from 2013–2022. Compiling them for iOS requires
patching protobuf for Apple Silicon, replacing stale autoconf scripts, and working around
OpenFst and Thrax API changes made since their last releases. `build_sparrowhawk_ios.sh`
automates all of this, but the build takes ~30 minutes and requires Homebrew autotools,
CMake, and Xcode. Only maintainers cutting new releases need to run it.

### v0.1.0 shipped with a broken device slice

The iOS device (`arm64`) slice in v0.1.0 was accidentally truncated to a 2-object archive
during manual debugging — device builds would fail to link. This was fixed in **v0.1.1**.
Use v0.1.1 or later.

## Building from source and releasing

See [RELEASING.md](RELEASING.md) for the full release workflow (one command: `Scripts/release.sh`).

To rebuild the native stack from scratch:

```bash
# ~30 min; requires macOS with Homebrew autotools + CMake + Xcode
bash Scripts/build_sparrowhawk_ios.sh

# Recompile .far grammars from NeMo pynini source
# (requires: conda activate nemo-tn  — python 3.10, pynini==2.1.6.post1)
bash Scripts/export_grammars.sh [/path/to/NeMo-text-processing]
```

## Attribution

This package combines the following open-source projects:

| Project | Version | License |
|---|---|---|
| [NeMo-text-processing](https://github.com/NVIDIA/NeMo-text-processing) (grammars) | — | Apache 2.0 |
| [Sparrowhawk](https://github.com/anand-nv/sparrowhawk/tree/nemo_tests) (anand-nv fork) | nemo_tests branch | Apache 2.0 |
| [OpenFst](https://www.openfst.org) | 1.8.3 | Apache 2.0 |
| [Thrax](https://www.opengrm.org/twiki/bin/view/GRM/Thrax) | 1.3.4 | Apache 2.0 |
| [protobuf](https://github.com/protocolbuffers/protobuf) | 2.5.0 | BSD 3-Clause |
| [re2](https://github.com/google/re2) | 2022-02-01 | BSD 3-Clause |

The Sparrowhawk fork (`anand-nv/sparrowhawk@nemo_tests`) contains NeMo-specific additions
to the original Google Sparrowhawk runtime. The original Sparrowhawk project is Apache 2.0.
