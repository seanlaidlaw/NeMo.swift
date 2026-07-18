# Releasing NeMoTextNormalizationSwift

## Overview

The Sparrowhawk xcframework (~400 MB) is too large for git. It is distributed as a
**GitHub release asset** and fetched by SPM via `binaryTarget(url:checksum:)` in
`Package.swift`. Every git tag corresponds to exactly one release asset; the
`Package.swift` committed at tag `vX.Y.Z` contains the URL and SHA-256 checksum for
the asset built at that version.

**Tags are the single source of truth for the version.** There is no separate VERSION
file. `Scripts/release.sh` derives the next version from the latest tag automatically.

## Prerequisites

- `gh` CLI installed and authenticated (`brew install gh && gh auth login`)
- `Frameworks/Sparrowhawk.xcframework` present locally (run
  `Scripts/build_sparrowhawk_ios.sh` if not — takes ~30 min)
- Clean working tree (no uncommitted changes other than `Package.swift`)

## Cutting a release

```bash
Scripts/release.sh               # bump patch version (default)
Scripts/release.sh --patch       # same as default
Scripts/release.sh --minor       # bump minor, reset patch to 0
Scripts/release.sh --major       # bump major, reset minor + patch to 0
Scripts/release.sh 1.2.3         # set an explicit version
```

The script will:

1. Derive the next version from the latest git tag (or `0.0.0` if none exist).
2. Confirm `Frameworks/Sparrowhawk.xcframework` exists (or rebuild it).
3. Zip `Frameworks/Sparrowhawk.xcframework` → `Sparrowhawk.xcframework.zip`.
4. Compute the SHA-256 checksum via `swift package compute-checksum`.
5. Write the new versioned asset URL + checksum into `Package.swift`'s
   `binaryTarget` (the `// managed-by-release:` marker comments are the edit anchors).
6. Commit `Package.swift` as `release: vX.Y.Z`, create the git tag, push both.
7. Create a GitHub Release for the tag and upload the zip as the release asset.
8. Delete the local zip.

### How SPM auto-resolves the latest tag

An SPM consumer that declares:

```swift
.package(url: "https://github.com/seanlaidlaw/NeMo.swift", from: "0.1.0")
```

will automatically resolve to the **highest git tag ≥ 0.1.0** that is
semver-compatible (i.e. same major version). Because `release.sh` keeps the
`Package.swift` at each tag self-consistent (its URL + checksum point at the asset
for *that exact tag*), SPM can always fetch the correct binary for whatever tag it
resolves to.

## Rebuilding the xcframework from scratch

```bash
# Build all three slices and assemble the xcframework:
bash Scripts/build_sparrowhawk_ios.sh

# (Optional) verify the simulator build works before tagging:
SIM=72CE18E3-E134-44D5-AD8C-740FA5551B5A
xcodebuild test \
  -scheme NeMoTextNormalizationSwift \
  -destination "platform=iOS Simulator,id=$SIM"
# Expected: 20 suites passed, 7 known issues, 0 unexpected failures.

# Then cut a new release:
Scripts/release.sh --patch
```

## ⚠ Device slice warning

The `ios-arm64` device slice in the current xcframework is unusually small (~99 KB).
Verify device builds before tagging any non-prerelease version:

```bash
xcodebuild build \
  -scheme NeMoTextNormalizationSwift \
  -destination 'generic/platform=iOS'
```

If it fails, the iphoneos-arm64 slice was not built correctly by
`build_sparrowhawk_ios.sh` and needs investigation before shipping to devices.
