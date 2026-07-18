#!/usr/bin/env bash
# release.sh — cut a tagged release of NeMoTextNormalizationSwift
#
# Usage:
#   Scripts/release.sh                  # bump patch (default)
#   Scripts/release.sh --patch          # bump patch
#   Scripts/release.sh --minor          # bump minor, reset patch
#   Scripts/release.sh --major          # bump major, reset minor + patch
#   Scripts/release.sh 1.2.3            # explicit version (no 'v' prefix)
#
# What it does (see RELEASING.md for the full narrative):
#   1. Derives the next version from the latest git tag (default: bump patch)
#   2. Zips Frameworks/Sparrowhawk.xcframework → Sparrowhawk.xcframework.zip
#   3. Computes SHA-256 via `swift package compute-checksum`
#   4. Writes the versioned asset URL + checksum into Package.swift
#   5. Commits Package.swift as "release: vX.Y.Z", tags, and pushes
#   6. Creates a GitHub Release and uploads the zip as the release asset
#   7. Deletes the local zip
#
# Prerequisites: gh CLI authenticated, clean working tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── Parse argument ────────────────────────────────────────────────────────────
BUMP="${1:---patch}"

# ── Derive next version from latest tag ──────────────────────────────────────
LATEST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")"
LATEST="${LATEST_TAG#v}"   # strip leading 'v'

IFS='.' read -r MAJOR MINOR PATCH <<< "$LATEST"
MAJOR="${MAJOR:-0}"; MINOR="${MINOR:-0}"; PATCH="${PATCH:-0}"

case "$BUMP" in
    --major)
        MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    --minor)
        MINOR=$((MINOR + 1)); PATCH=0 ;;
    --patch)
        PATCH=$((PATCH + 1)) ;;
    [0-9]*)
        # Explicit version like "1.2.3"
        IFS='.' read -r MAJOR MINOR PATCH <<< "$BUMP"
        ;;
    *)
        echo "Usage: $0 [--major|--minor|--patch|<X.Y.Z>]" >&2; exit 1 ;;
esac

VERSION="${MAJOR}.${MINOR}.${PATCH}"
TAG="v${VERSION}"

echo "→ Preparing release ${TAG}  (previous: ${LATEST_TAG})"

# ── Guardrails ────────────────────────────────────────────────────────────────
if git rev-parse "$TAG" &>/dev/null 2>&1; then
    echo "Error: tag $TAG already exists — bump the version or delete the tag first." >&2
    exit 1
fi

# Allow Package.swift to be dirty (we're about to modify it); fail on anything else.
DIRTY="$(git status --porcelain | grep -Ev '(^[ M]M Package\.swift| ^\?\?)'  || true)"
if [[ -n "$DIRTY" ]]; then
    echo "Error: working tree is dirty (non-Package.swift changes). Commit or stash first:" >&2
    echo "$DIRTY" >&2
    exit 1
fi

# ── Verify gh is available + authenticated ────────────────────────────────────
if ! command -v gh &>/dev/null; then
    echo "Error: 'gh' CLI not found. Install it (brew install gh) and run 'gh auth login'." >&2
    exit 1
fi
if ! gh auth status &>/dev/null; then
    echo "Error: 'gh' is not authenticated. Run 'gh auth login'." >&2
    exit 1
fi

# ── Derive GitHub slug from the configured remote ────────────────────────────
SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
URL="https://github.com/${SLUG}/releases/download/${TAG}/Sparrowhawk.xcframework.zip"
echo "  asset URL  : ${URL}"

# ── Ensure xcframework exists ─────────────────────────────────────────────────
XCFW="Frameworks/Sparrowhawk.xcframework"
if [[ ! -d "$XCFW" ]]; then
    echo ""
    echo "  Frameworks/Sparrowhawk.xcframework not found."
    echo "  Running Scripts/build_sparrowhawk_ios.sh (~30 min)…"
    echo ""
    bash Scripts/build_sparrowhawk_ios.sh
fi

# ── Zip xcframework ──────────────────────────────────────────────────────────
ZIP="Sparrowhawk.xcframework.zip"
echo "  Zipping ${XCFW}…"
(cd Frameworks && zip -r -y -q "../${ZIP}" Sparrowhawk.xcframework)
echo "  zip size   : $(du -sh "$ZIP" | cut -f1)"

# ── Compute SPM checksum ─────────────────────────────────────────────────────
echo "  Computing checksum (swift package compute-checksum)…"
CHECKSUM="$(swift package compute-checksum "$ZIP")"
echo "  checksum   : ${CHECKSUM}"

# ── Update Package.swift ─────────────────────────────────────────────────────
echo "  Updating Package.swift binaryTarget…"
python3 Scripts/_update_binary_target.py "$URL" "$CHECKSUM"

# ── Commit, tag, push ────────────────────────────────────────────────────────
echo "  Committing + tagging ${TAG}…"
git add Package.swift
git commit -m "release: ${TAG}"
git tag "$TAG"
git push origin HEAD "$TAG"

# ── Create GitHub Release + upload asset ────────────────────────────────────
echo "  Creating GitHub release ${TAG}…"
gh release create "$TAG" "$ZIP" \
    --title "$TAG" \
    --notes "## Sparrowhawk xcframework for NeMoTextNormalizationSwift ${TAG}

Pre-built static xcframework bundling OpenFst, Thrax, protobuf, re2, and Sparrowhawk.

**Built from**
- Sparrowhawk: [anand-nv/sparrowhawk@nemo_tests](https://github.com/anand-nv/sparrowhawk/tree/nemo_tests)
- OpenFst 1.8.3, Thrax 1.3.4
- protobuf 2.5.0, re2 2022-02-01

**Slices**
- \`ios-arm64\` — device
- \`ios-arm64_x86_64-simulator\` — simulator (fat: arm64 + x86_64)

**iOS deployment target**: 16.0

**SPM checksum**: \`${CHECKSUM}\`"

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -f "$ZIP"

echo ""
echo "✓ Released ${TAG}"
echo "  URL      : ${URL}"
echo "  checksum : ${CHECKSUM}"
echo ""
echo "SPM consumers: .package(url: \"https://github.com/${SLUG}\", from: \"${VERSION}\")"
