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

## Getting started in an Xcode app

### 1. Add the package

Open your project in Xcode, then **File → Add Package Dependencies**. Paste:

```
https://github.com/seanlaidlaw/NeMo.swift
```

Select **Up to Next Major Version** from `0.1.1`. Xcode downloads the
`Sparrowhawk.xcframework.zip` (~76 MB) and caches it in the SPM cache.

In your target's **Build Phases → Link Binary With Libraries**, confirm
`TextNormalization` appears (Xcode usually adds it automatically when you
choose it during package resolution).

### 2. Create one normalizer per app

`Normalizer.init()` parses the `.far` grammar archives — allow 10–100 ms.
Create it once at app startup and store it where your TTS code can reach it:

```swift
import TextNormalization

// e.g. in your AppDelegate, @main struct, or an @Observable TTS service
final class TTSService {
    let normalizer: Normalizer

    init() throws {
        normalizer = try Normalizer()  // ~10–100 ms; do once
    }
}
```

If initialization can fail gracefully, catch `NormalizerError`:

```swift
do {
    let normalizer = try Normalizer()
} catch NormalizerError.grammarResourceMissing(let name) {
    // .far file not bundled — shouldn't happen in a correctly built package
    print("Missing grammar: \(name)")
} catch NormalizerError.initializationFailed {
    print("Sparrowhawk failed to initialize")
}
```

### 3. Normalize text before passing it to a TTS engine

```swift
// Basic usage — written form → spoken form
let spoken = normalizer.normalize("She paid $4.50 for 2 items on Jan 3rd.")
// → "she paid four dollars fifty cents for two items on january third"

// For TTS: use punctPostProcess: true to preserve the original spacing
// around punctuation (e.g. commas, periods) rather than letting the
// normalizer rewrite it.
let ttsReady = normalizer.normalize(
    "The result was 98.6°F, well above 37°C.",
    punctPostProcess: true
)
// → "the result was ninety eight point six degrees fahrenheit, well above thirty seven degrees celsius"
```

`normalize(_:)` is **thread-safe** and serialized internally, so you can call
it from any actor or dispatch queue without additional locking.

### 4. Split multi-sentence text first

The normalizer expects one sentence at a time. Pass multi-sentence text
sentence-by-sentence:

```swift
let sentences = text.components(separatedBy: ". ")
let normalized = sentences.map { normalizer.normalize($0, punctPostProcess: true) }
let result = normalized.joined(separator: ". ")
```

For production use, prefer a proper sentence splitter (e.g. `NLTokenizer`
with `.sentence` unit) over splitting on `". "`:

```swift
import NaturalLanguage

func normalizeParagraph(_ text: String, normalizer: Normalizer) -> String {
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.string = text
    var result: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        let sentence = String(text[range])
        result.append(normalizer.normalize(sentence, punctPostProcess: true))
        return true
    }
    return result.joined(separator: " ")
}
```

### Quick reference

| Call | Effect |
|---|---|
| `try Normalizer()` | Load grammars; do once |
| `normalizer.normalize(text)` | Normalize one sentence |
| `normalizer.normalize(text, punctPostProcess: true)` | Normalize + preserve punctuation spacing |

---

## TODO

### Drop Intel simulator slice

The `ios-arm64_x86_64-simulator` fat binary contains an x86_64 slice for Intel
Mac simulators (~195 MB of the xcframework). Apple Silicon Macs run the arm64
simulator natively; Intel support is only needed for CI on Intel Mac runners or
developers on older hardware. Dropping x86_64 from `build_sparrowhawk_ios.sh`
(remove the `x86_64 iphonesimulator` slice and the `lipo` merge step) would
shrink the xcframework from ~613 MB to ~400 MB on disk and from ~76 MB to
~50 MB zipped.

### Separate grammar-compilation from runtime

The xcframework currently bundles Thrax in full because Sparrowhawk links
against it at build time. Thrax is a **grammar compiler** — its job is turning
pynini/WFST source into `.far` archives. We compiled the grammars offline with
`export_grammars.sh`; at runtime `normalize()` only reads those pre-built
archives via OpenFst. Thrax's compiler objects (`loader.o` 9.6 MB,
`compiler-stdarc.o` 6.7 MB, `compiler-log.o` 5.8 MB, ...) are entirely dead
code in a shipping app.

The fix would be to introduce a build flag — e.g.
`-DSPARROWHAWK_RUNTIME_ONLY` — that makes Sparrowhawk's `configure.ac` skip
linking against Thrax when building for deployment. A second, Thrax-enabled
build would remain available for anyone who needs to recompile grammars from
source. This would eliminate ~20 MB per arch (~60 MB total) from the xcframework
and remove the largest single dead-code contributor from every linked app.

---

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
