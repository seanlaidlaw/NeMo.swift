#!/usr/bin/env bash
# build_sparrowhawk_ios.sh
#
# Cross-compile the full Sparrowhawk native stack for iOS and package it as
# Frameworks/Sparrowhawk.xcframework (M1/M3 deliverable).
#
# Source versions (pinned to match NeMo-text-processing Dockerfile):
#   re2:         2022-02-01
#   protobuf:    2.5.0
#   OpenFst:     1.8.3
#   Thrax:       1.3.4
#   Sparrowhawk: anand-nv/sparrowhawk@nemo_tests
#
# The xcframework contains three slices:
#   ios-arm64               (device)
#   ios-arm64-simulator     (Apple Silicon simulator)
#   ios-x86_64-simulator    (Intel simulator, for CI on Intel Macs)
#
# Prerequisites (macOS host):
#   brew install cmake autoconf automake libtool pkg-config wget
#
# Usage:
#   bash Scripts/build_sparrowhawk_ios.sh
#   bash Scripts/build_sparrowhawk_ios.sh --skip-download   # reuse cached sources
#
# Output:
#   Frameworks/Sparrowhawk.xcframework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Versions ────────────────────────────────────────────────────────────────
RE2_TAG="2022-02-01"
PROTOBUF_VERSION="2.5.0"
OPENFST_VERSION="1.8.3"
THRAX_VERSION="1.3.4"
SPARROWHAWK_BRANCH="nemo_tests"
SPARROWHAWK_REPO="https://github.com/anand-nv/sparrowhawk.git"

IOS_DEPLOYMENT_TARGET="16.0"

# ── Directories ─────────────────────────────────────────────────────────────
BUILD_DIR="$REPO_ROOT/build/sparrowhawk"
DOWNLOADS_DIR="$BUILD_DIR/downloads"
SOURCES_DIR="$BUILD_DIR/sources"     # extracted source trees
SLICES_DIR="$BUILD_DIR/slices"       # per-slice installs
XCFW_STAGING="$BUILD_DIR/xcfw_staging"
OUTPUT_DIR="$REPO_ROOT/Frameworks"

mkdir -p "$DOWNLOADS_DIR" "$SOURCES_DIR" "$SLICES_DIR" "$XCFW_STAGING" "$OUTPUT_DIR"

# ── Argument parsing ─────────────────────────────────────────────────────────
SKIP_DOWNLOAD=0
for arg in "$@"; do
    case $arg in
        --skip-download) SKIP_DOWNLOAD=1 ;;
    esac
done

# ── Prerequisite check ───────────────────────────────────────────────────────
check_prerequisites() {
    local missing=()
    for cmd in cmake autoconf automake libtool glibtool git curl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    # cmake + autotools are required; glibtool is the Homebrew GNU libtool name
    if ! command -v glibtool >/dev/null 2>&1 && ! command -v libtoolize >/dev/null 2>&1; then
        missing+=("libtool (brew install libtool)")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing prerequisites: ${missing[*]}"
        echo "  brew install cmake autoconf automake libtool pkg-config"
        exit 1
    fi
    xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || {
        echo "ERROR: iOS SDK not found. Install Xcode + accept the license."
        exit 1
    }
    echo "✓ Prerequisites OK"
}

# ── Source downloads ─────────────────────────────────────────────────────────
download_sources() {
    if [[ $SKIP_DOWNLOAD -eq 1 ]]; then echo "→ Skipping download (--skip-download)"; return; fi

    # re2 (CMake-based)
    if [[ ! -d "$DOWNLOADS_DIR/re2" ]]; then
        echo "→ Cloning re2 $RE2_TAG..."
        git clone https://github.com/google/re2.git "$DOWNLOADS_DIR/re2" \
            --depth 1 --branch "$RE2_TAG"
    fi

    # protobuf 2.5.0 (autotools; protoc built for host, libprotobuf cross-compiled)
    local pb_tgz="$DOWNLOADS_DIR/protobuf-$PROTOBUF_VERSION.tar.gz"
    if [[ ! -f "$pb_tgz" ]]; then
        echo "→ Downloading protobuf $PROTOBUF_VERSION..."
        curl -fSL \
            "https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOBUF_VERSION/protobuf-$PROTOBUF_VERSION.tar.gz" \
            -o "$pb_tgz"
    fi

    # OpenFst 1.8.3 (autotools; FAR extension required)
    local fst_tgz="$DOWNLOADS_DIR/openfst-$OPENFST_VERSION.tar.gz"
    if [[ ! -f "$fst_tgz" ]]; then
        echo "→ Downloading OpenFst $OPENFST_VERSION..."
        curl -fSL \
            "http://www.openfst.org/twiki/pub/FST/FstDownload/openfst-$OPENFST_VERSION.tar.gz" \
            -o "$fst_tgz" || {
            # Fallback mirror
            curl -fSL \
                "https://github.com/kylebgorman/openfst/archive/refs/tags/$OPENFST_VERSION.tar.gz" \
                -o "$fst_tgz"
        }
    fi

    # Thrax 1.3.4 (autotools; GrmManager runtime)
    local thrax_tgz="$DOWNLOADS_DIR/thrax-$THRAX_VERSION.tar.gz"
    if [[ ! -f "$thrax_tgz" ]]; then
        echo "→ Downloading Thrax $THRAX_VERSION..."
        curl -fSL \
            "http://www.opengrm.org/twiki/pub/GRM/ThraxDownload/thrax-$THRAX_VERSION.tar.gz" \
            -o "$thrax_tgz"
    fi

    # Sparrowhawk (anand-nv fork, nemo_tests branch)
    if [[ ! -d "$DOWNLOADS_DIR/sparrowhawk" ]]; then
        echo "→ Cloning Sparrowhawk ($SPARROWHAWK_BRANCH)..."
        git clone "$SPARROWHAWK_REPO" "$DOWNLOADS_DIR/sparrowhawk" \
            --branch "$SPARROWHAWK_BRANCH" --depth 1
    fi

    echo "✓ All sources available"
}

# ── Patch protobuf 2.5.0 for arm64 (Apple Silicon host + iOS target) ─────────
# protobuf 2.5.0 (2013) has no __aarch64__ case in platform_macros.h, which
# causes a hard #error on Apple Silicon. Fix: alias arm64/Apple → ARCH_X64,
# which routes to atomicops_internals_macosx.h — that file uses OSAtomic*
# functions that are arch-agnostic (they work on arm64, just deprecated).
patch_protobuf_for_arm64() {
    local src_dir="$1"
    local platform_macros="$src_dir/src/google/protobuf/stubs/platform_macros.h"
    [[ -f "$platform_macros" ]] || { echo "WARNING: platform_macros.h not found"; return; }
    grep -q "aarch64" "$platform_macros" && return   # already patched

    echo "  → Patching platform_macros.h for arm64 Apple..."
    python3 - "$platform_macros" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
# Insert before the catch-all #else/#error so arm64 Apple maps to X64;
# atomicops_internals_macosx.h (reached via ARCH_X64 + __APPLE__) uses
# OSAtomic* functions which exist and work on arm64.
patch = (
    '#elif defined(__aarch64__) && defined(__APPLE__)\n'
    '// arm64 Apple (macOS/iOS): route to the macOS atomic ops path which\n'
    '// uses OSAtomic functions — arch-agnostic, available on arm64.\n'
    '#define GOOGLE_PROTOBUF_ARCH_X64 1\n'
    '#define GOOGLE_PROTOBUF_ARCH_64_BIT 1\n'
)
marker = '#else\n#error Host architecture was not detected as supported by protobuf'
if marker in content:
    content = content.replace(marker, patch + marker)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Patched {path}")
else:
    print(f"  WARNING: patch marker not found in {path} — check the file")
PYEOF
}

# ── Update autotools config scripts ─────────────────────────────────────────
# protobuf 2.5.0, OpenFst 1.8.3, Thrax 1.3.4 ship 2013-era config.sub/config.guess
# that reject 'arm64' and 'ios' in target triples. Replace with the modern versions
# from Homebrew's automake package (installed as a prerequisite).
update_autotools_config_scripts() {
    local src_dir="$1"
    # 'automake --print-libdir' is the canonical way to locate config.sub
    # regardless of Homebrew prefix (~/.homebrew, /opt/homebrew, /usr/local, etc.)
    local automake_libdir
    automake_libdir="$(automake --print-libdir 2>/dev/null)" || {
        echo "  WARNING: automake --print-libdir failed — arm64 cross-compile may fail"
        return 0
    }
    if [[ ! -f "$automake_libdir/config.sub" ]]; then
        echo "  WARNING: $automake_libdir/config.sub not found"
        return 0
    fi
    cp "$automake_libdir/config.sub" "$src_dir/config.sub" && chmod +x "$src_dir/config.sub"
    [[ -f "$automake_libdir/config.guess" ]] && \
        cp "$automake_libdir/config.guess" "$src_dir/config.guess" && \
        chmod +x "$src_dir/config.guess"
    echo "  Updated config.sub/config.guess from $(basename "$automake_libdir")"
}

# ── Patch Thrax 1.3.4 for OpenFst 1.8.3 + modern Clang ──────────────────────
# OpenFst 1.8.3 removed / renamed things Thrax 1.3.4 expects:
#   int32/uint8 typedefs, fst/log.h (LOG/CHECK), fst/lock.h (MutexLock),
#   fst/types.h (gone), fst::StringSplit (removed), fst::make_unique (→ std::),
#   FLAGS_xxx globals renamed to FST_FLAGS_xxx.
# Strategy: inject a comprehensive shim into thrax/compat/compat.h (which is
# transitively included by almost every Thrax .cc file), and create a stub
# fst/types.h.
patch_thrax_for_openfst183() {
    local thrax_src="$1"
    local fst_include="$2"   # path to the openfst install include dir

    # 1. Stub fst/types.h (thrax/algo/cdrewrite.h and thrax/algo/stringcompile.h
    #    include it; it was removed in OpenFst 1.8.x). The old fst/types.h provided
    #    Google-style integer typedefs; restore them here so files that only include
    #    fst/types.h (not thrax/compat/compat.h) also get int64 etc.
    if [[ ! -f "$fst_include/fst/types.h" ]]; then
        cat > "$fst_include/fst/types.h" <<'EOF'
// fst/types.h stub — compatibility with Thrax 1.3.4 (removed in OpenFst 1.8.3)
#pragma once
#include <cstdint>
typedef int8_t   int8;
typedef int16_t  int16;
typedef int32_t  int32;
typedef int64_t  int64;
typedef uint8_t  uint8;
typedef uint16_t uint16;
typedef uint32_t uint32;
typedef uint64_t uint64;
EOF
        echo "  Created stub fst/types.h (with Google-style integer typedefs)"
    fi

    # 1b. thrax/symbols.h uses int64 but only includes <string> and <fst/fstlib.h>
    #     (fstlib.h doesn't include fst/types.h). Inject the types.h include.
    local symbols_h="$thrax_src/src/include/thrax/symbols.h"
    if [[ -f "$symbols_h" ]] && ! grep -q "fst/types.h" "$symbols_h"; then
        sed -i.bak 's|#include <string>|#include <string>\n#include <fst/types.h>  \/\/ int64 typedef (OpenFst 1.8.3 compat)|' "$symbols_h"
        echo "  Patched symbols.h: added fst/types.h include for int64"
    fi

    # 2. Patch thrax/compat/compat.h with comprehensive compat shim
    local compat_h="$thrax_src/src/include/thrax/compat/compat.h"
    [[ -f "$compat_h" ]] || { echo "  WARNING: $compat_h not found"; return; }
    grep -q "THRAX_FST183_COMPAT_SHIM" "$compat_h" && {
        echo "  thrax compat.h already patched"
        return
    }

    python3 - "$compat_h" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

marker = '#define THRAX_COMPAT_COMPAT_H_'
shim = r"""
// ═══ THRAX_FST183_COMPAT_SHIM ════════════════════════════════════════════════
// Bridges Thrax 1.3.4 expectations to OpenFst 1.8.3 + modern Clang.
// ─────────────────────────────────────────────────────────────────────────────
// 1. Includes
#include <cstdint>
#include <memory>      // std::make_unique
#include <sstream>     // std::istringstream
#include <string>
#include <string_view> // for StringSplit(str, string_view) overload
#include <vector>
#include <fst/log.h>   // LOG, CHECK, VLOG macros
#include <fst/lock.h>  // fst::Mutex, fst::MutexLock

// 2. Google-style integer typedefs (removed from fst/compat.h in OpenFst 1.8.x)
typedef int8_t    int8;
typedef int16_t   int16;
typedef int32_t   int32;
typedef int64_t   int64;
typedef uint8_t   uint8;
typedef uint16_t  uint16;
typedef uint32_t  uint32;
typedef uint64_t  uint64;

// 3. fst::StringSplit — removed in OpenFst 1.8.x; provide minimal replacements.
//    Two overloads: char delimiter (e.g. StringSplit(s, ' ')) and
//    string_view delimiter (e.g. StringSplit(s, "/")).
namespace fst {
inline std::vector<std::string> StringSplit(const std::string &str, char delim) {
  std::vector<std::string> out;
  if (str.empty()) return out;
  std::istringstream ss(str);
  std::string token;
  while (std::getline(ss, token, delim)) out.push_back(token);
  return out;
}
inline std::vector<std::string> StringSplit(const std::string &str,
                                            std::string_view sep) {
  std::vector<std::string> out;
  if (str.empty()) return out;
  if (sep.empty()) { out.push_back(str); return out; }
  size_t start = 0;
  while (true) {
    size_t pos = str.find(sep, start);
    if (pos == std::string::npos) { out.push_back(str.substr(start)); break; }
    out.push_back(str.substr(start, pos - start));
    start = pos + sep.size();
  }
  return out;
}
// Thrax 1.3.4 uses fst::make_unique; it moved to std:: in OpenFst 1.8.x
using std::make_unique;
}  // namespace fst

// 4. Thrax 1.3.4 uses FLAGS_xxx; OpenFst 1.8.3 renamed them to FST_FLAGS_xxx.
//    DECLARE_bool(name) now emits "extern bool FST_FLAGS_name" (via fst/flags.h).
//    We add specific preprocessor aliases for each Thrax flag so that FLAGS_xxx
//    in Thrax code transparently refers to the FST_FLAGS_xxx storage.
//    We do NOT redefine DECLARE_bool/DEFINE_bool globally — that would break
//    OpenFst headers that already use FST_FLAGS_xxx in their code.
#define FLAGS_always_export       FST_FLAGS_always_export
#define FLAGS_indir               FST_FLAGS_indir
#define FLAGS_line_numbers_in_ast FST_FLAGS_line_numbers_in_ast
#define FLAGS_optimize_all_fsts   FST_FLAGS_optimize_all_fsts
#define FLAGS_outdir              FST_FLAGS_outdir
#define FLAGS_print_ast           FST_FLAGS_print_ast
#define FLAGS_print_rules         FST_FLAGS_print_rules
#define FLAGS_save_symbols        FST_FLAGS_save_symbols
// ═══ END THRAX_FST183_COMPAT_SHIM ════════════════════════════════════════════
"""

if marker in content:
    content = content.replace(marker, marker + shim, 1)
    with open(path, 'w') as f:
        f.write(content)
    print(f"  Patched {path} with OpenFst 1.8.3 compat shim")
else:
    print(f"  WARNING: guard marker not found in {path}")
PYEOF
}

# ── Patch Thrax 1.3.4 for OpenFst 1.8.3 API changes ─────────────────────────
# OpenFst 1.8.3 made several breaking API changes that affect Thrax 1.3.4:
#   1. PdtComposeFilter became a scoped enum; EXPAND_FILTER → PdtComposeFilter::EXPAND
#   2. MakeArcMapFst() factory removed; use ArcMapFst<A,B,C>(fst, mapper) directly
#   3. REGISTER_LOGARC_FUNCTION triggers LogArc instantiation which fails the new
#      IsPath<LogWeight> static_assert in ShortestPath/Prune. Since Sparrowhawk
#      runtime only uses StdArc, suppress LogArc registrations.
patch_thrax_api_changes() {
    local thrax_src="$1"

    # A. Replace ::fst::EXPAND_FILTER with ::fst::PdtComposeFilter::EXPAND
    local grm_mgr="$thrax_src/src/include/thrax/abstract-grm-manager.h"
    if [[ -f "$grm_mgr" ]] && grep -q "::fst::EXPAND_FILTER" "$grm_mgr"; then
        sed -i.bak 's/::fst::EXPAND_FILTER/::fst::PdtComposeFilter::EXPAND/g' "$grm_mgr"
        echo "  Patched abstract-grm-manager.h: EXPAND_FILTER → PdtComposeFilter::EXPAND"
    fi

    # B. cross.h: replace MakeArcMapFst factory calls (inside namespace fst)
    local cross_h="$thrax_src/src/include/thrax/algo/cross.h"
    if [[ -f "$cross_h" ]] && grep -q "MakeArcMapFst" "$cross_h"; then
        python3 - "$cross_h" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
content = content.replace(
    'Compose(RmEpsilonFst<Arc>(MakeArcMapFst(ifst1, oeps)),\n          RmEpsilonFst<Arc>(MakeArcMapFst(ifst2, ieps)), ofst, opts);',
    'Compose(RmEpsilonFst<Arc>(ArcMapFst<Arc, Arc, OutputEpsilonMapper<Arc>>(ifst1, oeps)),\n          RmEpsilonFst<Arc>(ArcMapFst<Arc, Arc, InputEpsilonMapper<Arc>>(ifst2, ieps)), ofst, opts);'
)
with open(path, 'w') as f:
    f.write(content)
print(f"  Patched {path}: MakeArcMapFst → ArcMapFst constructor")
PYEOF
    fi

    # C. cdrewrite.h: replace MakeArcMapFst(ufilter, imapper) (inside namespace fst)
    local cdrewrite_h="$thrax_src/src/include/thrax/algo/cdrewrite.h"
    if [[ -f "$cdrewrite_h" ]] && grep -q "MakeArcMapFst" "$cdrewrite_h"; then
        sed -i.bak \
            's/Reverse(MakeArcMapFst(ufilter, imapper), \&ufilter)/Reverse(ArcMapFst<StdArc, StdArc, IdentityArcMapper<StdArc>>(ufilter, imapper), \&ufilter)/g' \
            "$cdrewrite_h"
        echo "  Patched cdrewrite.h: MakeArcMapFst → ArcMapFst constructor"
    fi

    # D. rmweight.h: replace MakeArcMapFst (inside namespace thrax::function)
    local rmweight_h="$thrax_src/src/include/thrax/rmweight.h"
    if [[ -f "$rmweight_h" ]] && grep -q "MakeArcMapFst" "$rmweight_h"; then
        sed -i.bak \
            's/return MakeArcMapFst(fst, ::fst::RmWeightMapper<Arc>()).Copy()/return ::fst::ArcMapFst<Arc, Arc, ::fst::RmWeightMapper<Arc>>(fst, ::fst::RmWeightMapper<Arc>()).Copy()/g' \
            "$rmweight_h"
        echo "  Patched rmweight.h: MakeArcMapFst → ArcMapFst constructor"
    fi

    # E0. thrax/compat/utils.h and thrax/algo/stringcompile.h use fst::StringSplit,
    #     fst::make_unique, and LOG(FATAL) which came from old fst/compat.h (now removed).
    #     Add <thrax/compat/compat.h> include to pull in our shim.
    local compat_utils_h="$thrax_src/src/include/thrax/compat/utils.h"
    if [[ -f "$compat_utils_h" ]] && ! grep -q "thrax/compat/compat.h" "$compat_utils_h"; then
        sed -i.bak 's|#include <fst/compat.h>|#include <fst/compat.h>\n#include <thrax/compat/compat.h>  // StringSplit, make_unique, LOG (OpenFst 1.8.3 compat)|' "$compat_utils_h"
        echo "  Patched thrax/compat/utils.h: added thrax/compat/compat.h include"
    fi

    local stringcompile_h="$thrax_src/src/include/thrax/algo/stringcompile.h"
    if [[ -f "$stringcompile_h" ]] && ! grep -q "thrax/compat/compat.h" "$stringcompile_h"; then
        sed -i.bak 's|#include <fst/types.h>|#include <thrax/compat/compat.h>  // StringSplit, LOG (OpenFst 1.8.3 compat)\n#include <fst/types.h>|' "$stringcompile_h"
        echo "  Patched thrax/algo/stringcompile.h: added thrax/compat/compat.h include"
    fi

    # E. function.h: suppress LogArc/Log64Arc registrations to avoid instantiating
    #    Thrax function templates with LogArc, which triggers the IsPath<LogWeight>
    #    static_assert failures in OpenFst 1.8.3's ShortestPath/Prune.
    #    The Sparrowhawk runtime only applies pre-compiled StdArc .far files.
    local function_h="$thrax_src/src/include/thrax/function.h"
    if [[ -f "$function_h" ]] && ! grep -q "THRAX_LOGARC_SUPPRESSED" "$function_h"; then
        python3 - "$function_h" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Suppress REGISTER_LOGARC_FUNCTION registration (keeps the macro but makes it a no-op)
content = content.replace(
    '#define REGISTER_LOGARC_FUNCTION(function) \\\n  kLogArcRegistry.Register(#function, new function)',
    '#define REGISTER_LOGARC_FUNCTION(function) /* THRAX_LOGARC_SUPPRESSED: LogArc disabled for iOS */'
)
content = content.replace(
    '#define REGISTER_LOG64ARC_FUNCTION(function) \\\n  kLogArcRegistry.Register(#function, new function)',
    '#define REGISTER_LOG64ARC_FUNCTION(function) /* THRAX_LOGARC_SUPPRESSED: Log64Arc disabled for iOS */'
)
# Redefine REGISTER_GRM_FUNCTION to only register StdArc — this prevents
# template instantiation of concrete function classes with LogArc, which would
# trigger ShortestPath<LogWeight> and hit the IsPath static_assert.
old_grm = (
    '#define REGISTER_GRM_FUNCTION(name) \\\n'
    '  typedef name<fst::StdArc> StdArc ## name; \\\n'
    '  REGISTER_STDARC_FUNCTION(StdArc ## name); \\\n'
    '  typedef name<fst::LogArc> LogArc ## name; \\\n'
    '  REGISTER_LOGARC_FUNCTION(LogArc ## name); \\\n'
    '  typedef name<fst::LogArc> Log64Arc ## name; \\\n'
    '  REGISTER_LOGARC_FUNCTION(Log64Arc ## name)'
)
new_grm = (
    '#define REGISTER_GRM_FUNCTION(name) \\\n'
    '  typedef name<fst::StdArc> StdArc ## name; \\\n'
    '  REGISTER_STDARC_FUNCTION(StdArc ## name) /* LogArc/Log64Arc suppressed for iOS */'
)
if old_grm in content:
    content = content.replace(old_grm, new_grm)
    print(f"  Patched REGISTER_GRM_FUNCTION: StdArc-only for iOS")
else:
    print(f"  WARNING: REGISTER_GRM_FUNCTION pattern not found in {path}")

with open(path, 'w') as f:
    f.write(content)
print(f"  Patched {path}: LogArc registrations suppressed")
PYEOF
    fi
}

# ── Patch OpenFst 1.8.3 source bugs ─────────────────────────────────────────
# 1. bi-table.h line ~333: copy constructor accesses 'table.s_' but the private
#    member was renamed to 'selector_'. Fix: use 'table.selector_'.
# 2. configure: float-equality check hard-fails when cross_compiling=yes.
patch_openfst_source() {
    local src_dir="$1"
    local bi_table="$src_dir/src/include/fst/bi-table.h"
    if [[ -f "$bi_table" ]] && grep -q "selector_(table.s_)" "$bi_table"; then
        sed -i.bak 's/selector_(table\.s_)/selector_(table.selector_)/g' "$bi_table"
        echo "  Patched bi-table.h: s_ → selector_ in copy constructor"
    fi
}

# ── Patch OpenFst configure for cross-compile ────────────────────────────────
# OpenFst 1.8.3's configure has a float-equality sanity check that explicitly
# hard-fails when cross_compiling=yes (no cache-variable escape hatch).
# On arm64 Apple platforms, IEEE 754 float equality IS reflexive, so we replace
# the error branch with a success-assumption echo.
patch_openfst_for_cross_compile() {
    local src_dir="$1"
    local configure="$src_dir/configure"
    [[ -f "$configure" ]] || { echo "  WARNING: configure not found in $src_dir"; return; }
    grep -q "cannot run test program while cross compiling" "$configure" || return 0

    python3 - "$configure" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

# Find the cross-compile guard block for the float-equality check.
# Pattern: line with 'if test "$cross_compiling" = yes'
# followed within ~10 lines by 'cannot run test program while cross compiling'
# ends at the first 'else $as_nop' after the error block.
i = 0
patched = False
while i < len(lines):
    if 'if test "$cross_compiling" = yes' in lines[i]:
        # Peek ahead for the float-equality error signature
        window = ''.join(lines[i:min(i+10, len(lines))])
        if 'cannot run test program while cross compiling' in window:
            # Find the closing 'else $as_nop'
            j = i + 1
            while j < len(lines) and 'else $as_nop' not in lines[j]:
                j += 1
            # Replace lines i..j (inclusive of the 'else $as_nop' line) with
            # a no-op assumption and the 'else $as_nop' sentinel.
            new = [
                'if test "$cross_compiling" = yes\n',
                'then :\n',
                '  echo "Checking for float equality... (cross-compiling: assuming yes for arm64 Apple)"\n',
                lines[j],   # preserve 'else $as_nop'
            ]
            lines[i:j+1] = new
            patched = True
            break
    i += 1

if patched:
    with open(path, 'w') as f:
        f.writelines(lines)
    print("  Patched OpenFst configure: cross-compile float-equality check → assume yes")
else:
    print("  WARNING: float-equality cross-compile block not found in configure")
PYEOF
}

# ── Build host protoc ────────────────────────────────────────────────────────
# protoc must run on the build machine (macOS) to compile .proto → .pb.{h,cc}.
# Only libprotobuf itself is then cross-compiled for iOS.
build_host_protoc() {
    local host_install="$BUILD_DIR/host_protobuf"
    if [[ -f "$host_install/bin/protoc" ]]; then
        echo "→ host protoc already built, skipping"
        return
    fi
    echo "=== Building host protoc (macOS native) ==="

    # Extract into $SOURCES_DIR. Also clean host_install in case a previous
    # failed run left partial state there (buggy fallback put sources in it).
    local src_dir="$SOURCES_DIR/host_protobuf"
    rm -rf "$src_dir" "$host_install"
    mkdir -p "$SOURCES_DIR"
    tar xzf "$DOWNLOADS_DIR/protobuf-$PROTOBUF_VERSION.tar.gz" -C "$SOURCES_DIR"
    mv "$SOURCES_DIR/protobuf-$PROTOBUF_VERSION" "$src_dir"

    patch_protobuf_for_arm64 "$src_dir"

    mkdir -p "$host_install"
    cd "$src_dir"
    ./configure --prefix="$host_install" \
        --disable-shared --enable-static \
        --with-pic
    make -j"$(sysctl -n hw.ncpu)"
    make install
    echo "✓ host protoc: $host_install/bin/protoc"
}

# Pre-generate protobuf sources for Sparrowhawk (run on host, result used by
# all cross-compiled slices so we don't need a cross-compiled protoc).
generate_sparrowhawk_protos() {
    local protoc="$BUILD_DIR/host_protobuf/bin/protoc"
    local sh_src="$DOWNLOADS_DIR/sparrowhawk"
    local proto_out="$BUILD_DIR/sparrowhawk_proto_gen"

    if [[ -d "$proto_out" && -n "$(ls -A "$proto_out" 2>/dev/null)" ]]; then
        echo "→ Sparrowhawk proto stubs already generated, skipping"
        return
    fi

    echo "→ Generating Sparrowhawk proto stubs with host protoc..."
    mkdir -p "$proto_out"

    # Find proto files in the Sparrowhawk source tree
    find "$sh_src/src/proto" -name "*.proto" 2>/dev/null | while read -r proto; do
        "$protoc" \
            --proto_path="$sh_src/src/proto" \
            --cpp_out="$proto_out" \
            "$proto"
    done

    # Also run autoreconf on the Sparrowhawk source so configure is available
    (cd "$sh_src" && autoreconf -if 2>/dev/null || true)

    echo "✓ Proto stubs in $proto_out"
}

# ── Patch Sparrowhawk protobuf_serializer.cc for double-quote escaping ────────
# The original code wraps string field values in proto text format quotes but
# does NOT escape any '"' characters inside the value.  Input tokens that
# contain a literal double-quote (e.g. 6" pipe, "He's 50") produce malformed
# proto text that Sparrowhawk's parser rejects.
# Fix: run a lambda over each string value and replace '"' with '\"'.
patch_sparrowhawk_serializer() {
    local src_dir="$1"
    local target="$src_dir/src/lib/protobuf_serializer.cc"
    [[ -f "$target" ]] || { echo "  WARNING: protobuf_serializer.cc not found in $src_dir"; return; }
    grep -q "escape_dquotes" "$target" && return 0   # already patched

    python3 - "$target" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

old = (
    '    if (field->type() == FieldDescriptor::TYPE_STRING) {\n'
    '      // Special handling for string fields, where we don\'t escape internal\n'
    '      // quotes with backslashes. This can\'t be disabled in TextFormat::Printer.\n'
    '      if (index == -1) {\n'
    '        value = "\\"" + reflection_->GetString(*message_, field) + "\\"";\n'
    '      } else {\n'
    '        value = "\\"" +\n'
    '            reflection_->GetRepeatedString(*message_, field, index) + "\\"";\n'
    '      }\n'
    '    }'
)

new = (
    '    if (field->type() == FieldDescriptor::TYPE_STRING) {\n'
    '      // Escape internal double quotes so proto text format parsing succeeds\n'
    '      // for input tokens that contain \'"\' (e.g. quoted text like "He\'s 50").\n'
    '      auto escape_dquotes = [](const std::string& s) {\n'
    '        std::string r; r.reserve(s.size() + 4);\n'
    '        for (char c : s) { if (c == \'"\') { r += \'\\\\\'; r += \'"\'; } else r += c; }\n'
    '        return r;\n'
    '      };\n'
    '      if (index == -1) {\n'
    '        value = "\\"" + escape_dquotes(reflection_->GetString(*message_, field)) + "\\"";\n'
    '      } else {\n'
    '        value = "\\"" + escape_dquotes(reflection_->GetRepeatedString(*message_, field, index)) + "\\"";\n'
    '      }\n'
    '    }'
)

if old not in content:
    print("  WARNING: expected pattern not found in protobuf_serializer.cc — skipping patch")
    sys.exit(0)

content = content.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(content)
print("  Patched protobuf_serializer.cc: escape internal double quotes in string fields")
PYEOF
}

# ── Patch Sparrowhawk protobuf_parser.cc for unescaped double-quote in token names ──
# The NeMo Thrax grammar outputs proto text format directly from FST arc labels
# without escaping '"' inside token name strings.  The parser's
# ParseQuotedFieldValue() stops at the FIRST '"' it sees, which is wrong when
# the token text starts with '"' (e.g. "He's 50 → `name: ""He's"`).
# Fix: use a read-only ArcIterator to peek ahead (skipping epsilon arcs) without
# modifying state_, last_state_, or token_name_.  The NeMo grammar omits the
# space before the next field name in some cases (e.g. "two"quantity:), so a
# simple structural-char check is not enough: we scan [a-z_]+: to detect a
# proto field name following the closing '"'.
patch_sparrowhawk_parser() {
    local src_dir="$1"
    local target="$src_dir/src/lib/protobuf_parser.cc"
    [[ -f "$target" ]] || { echo "  WARNING: protobuf_parser.cc not found in $src_dir"; return; }
    grep -q "field_name_started" "$target" && return 0   # already patched

    python3 - "$target" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

old = (
    '    } else if (olabel_ == \'"\' && !last_backslash) {\n'
    '      return true;  // Unescaped quote finishes the field.\n'
    '    } else if (olabel_) {\n'
    '      value->push_back(olabel_);\n'
    '      last_backslash = false;\n'
    '    }\n'
    '  }'
)

new = (
    '    } else if (olabel_ == \'"\' && !last_backslash) {\n'
    '      // Peek ahead using a read-only ArcIterator to decide if this \'"\' is a\n'
    '      // field-value terminator or an unescaped \'"\' inside a token name.\n'
    '      // NeMo Thrax grammars do not escape \'"\' in name strings, and may also\n'
    '      // omit the space before the next field name (e.g. "two"quantity:).\n'
    '      // Heuristic: scan ahead through lowercase/underscore chars; if the\n'
    '      // first non-epsilon char sequence matches [a-z_]+: it is a proto field\n'
    '      // name → terminator. Structural chars (\' \', \'}\', \'\\n\', EOF) → also a\n'
    '      // terminator. Anything else → internal quote.\n'
    '      StateId peek_state = state_;\n'
    '      bool is_terminator = true;\n'
    '      bool field_name_started = false;\n'
    '      while (true) {\n'
    '        ArcIterator peek(*fst_, peek_state);\n'
    '        if (peek.Done()) { break; }  // EOF after \'"\' → terminator\n'
    '        const int peek_label = peek.Value().olabel;\n'
    '        if (peek_label == 0) {\n'
    '          peek_state = peek.Value().nextstate;  // skip epsilon, keep peeking\n'
    '          continue;\n'
    '        }\n'
    '        if (peek_label == \' \' || peek_label == \'}\' || peek_label == \'\\n\') {\n'
    '          is_terminator = true;   // structural → terminator\n'
    '          break;\n'
    '        }\n'
    '        if ((peek_label >= \'a\' && peek_label <= \'z\') || peek_label == \'_\') {\n'
    '          field_name_started = true;\n'
    '          peek_state = peek.Value().nextstate;  // scan through field name chars\n'
    '          continue;\n'
    '        }\n'
    '        if (peek_label == \':\' && field_name_started) {\n'
    '          is_terminator = true;   // [a-z_]+: pattern → proto field name → terminator\n'
    '          break;\n'
    '        }\n'
    '        // Digit, uppercase, \'"\', \':\' without prior alpha, or any other char\n'
    '        // → this \'"\' is part of the field value (internal quote).\n'
    '        is_terminator = false;\n'
    '        break;\n'
    '      }\n'
    '      if (is_terminator) return true;\n'
    '      // This \'"\' is part of the field value.\n'
    '      value->push_back(\'"\');\n'
    '      last_backslash = false;\n'
    '    } else if (olabel_) {\n'
    '      value->push_back(olabel_);\n'
    '      last_backslash = false;\n'
    '    }\n'
    '  }'
)

if old not in content:
    print("  WARNING: expected pattern not found in protobuf_parser.cc — skipping patch")
    sys.exit(0)

content = content.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(content)
print("  Patched protobuf_parser.cc: field-name-aware ArcIterator lookahead for unescaped '\"'")
PYEOF
}

# ── Per-slice build ──────────────────────────────────────────────────────────
# build_slice ARCH SDK_NAME
#   ARCH:     arm64 | x86_64
#   SDK_NAME: iphoneos | iphonesimulator
build_slice() {
    local ARCH="$1"
    local SDK_NAME="$2"
    local SLICE_TAG="${SDK_NAME}-${ARCH}"   # e.g. iphonesimulator-arm64

    local SDK_PATH
    SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"

    # Simulator vs device LLVM triple (used in CFLAGS -target)
    local TRIPLE
    if [[ "$SDK_NAME" == "iphonesimulator" ]]; then
        TRIPLE="${ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
    else
        TRIPLE="${ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}"
    fi

    # Autotools --host: must DIFFER from the macOS build machine triple so
    # configure knows this is a cross-compile and won't try to execute test
    # binaries. Use the GCC-canonical triple (old config.sub rejects the LLVM
    # 'arm64' CPU name and 'ios' OS; 'aarch64-apple-darwin' is accepted and
    # is distinguishable from the build machine's 'aarch64-apple-darwin<ver>').
    local AUTOTOOLS_HOST
    if [[ "$ARCH" == "x86_64" ]]; then
        AUTOTOOLS_HOST="x86_64-apple-darwin"
    else
        AUTOTOOLS_HOST="aarch64-apple-darwin"
    fi

    # Common cross-compile env variables (autotools picks these up)
    local CFLAGS_BASE="-arch $ARCH -isysroot $SDK_PATH -target $TRIPLE"
    local CXXFLAGS_BASE="$CFLAGS_BASE -std=c++17 -stdlib=libc++"
    local LDFLAGS_BASE="-arch $ARCH -isysroot $SDK_PATH"

    local CC_CMD
    local CXX_CMD
    CC_CMD="$(xcrun --sdk "$SDK_NAME" --find clang)"
    CXX_CMD="$(xcrun --sdk "$SDK_NAME" --find clang++)"

    local AR_CMD RANLIB_CMD
    AR_CMD="$(xcrun --sdk "$SDK_NAME" --find ar)"
    RANLIB_CMD="$(xcrun --sdk "$SDK_NAME" --find ranlib)"

    local SLICE_INSTALL="$SLICES_DIR/$SLICE_TAG"
    mkdir -p "$SLICE_INSTALL"

    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  Building slice: $SLICE_TAG  triple=$TRIPLE"
    echo "════════════════════════════════════════════════════════"

    # Helper: fresh source copy to avoid cross-slice pollution
    fresh_source() {
        local pkg="$1"
        local src_tgz="$DOWNLOADS_DIR/$pkg"
        local dest="$SOURCES_DIR/$SLICE_TAG/$pkg"
        rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        if [[ "$src_tgz" == *.tar.gz ]]; then
            tar xzf "$src_tgz" -C "$SOURCES_DIR/$SLICE_TAG/"
            # Rename the extracted dir (has version suffix) to just the pkg name
            local extracted
            extracted="$(tar tzf "$src_tgz" | head -1 | cut -f1 -d"/")"
            mv "$SOURCES_DIR/$SLICE_TAG/$extracted" "$dest"
        fi
        echo "$dest"
    }

    # ── re2 ─────────────────────────────────────────────────────────────────
    local re2_install="$SLICE_INSTALL/re2"
    if [[ ! -f "$re2_install/lib/libre2.a" ]]; then
        echo "--- re2 ---"
        local re2_build="$SOURCES_DIR/$SLICE_TAG/re2_build"
        rm -rf "$re2_build"
        mkdir -p "$re2_build"

        cmake "$DOWNLOADS_DIR/re2" -B "$re2_build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$re2_install" \
            -DBUILD_SHARED_LIBS=OFF \
            -DRE2_BUILD_TESTING=OFF \
            -DCMAKE_SYSTEM_NAME=iOS \
            -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
            -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
            -DCMAKE_C_COMPILER="$CC_CMD" \
            -DCMAKE_CXX_COMPILER="$CXX_CMD" \
            -DCMAKE_CXX_FLAGS="-stdlib=libc++" \
            -DCMAKE_CXX_STANDARD=17 \
            -DCMAKE_CXX_STANDARD_REQUIRED=ON \
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
            -DCMAKE_POSITION_INDEPENDENT_CODE=ON

        cmake --build "$re2_build" -j"$(sysctl -n hw.ncpu)"
        cmake --install "$re2_build"
        echo "✓ re2 → $re2_install"
    else
        echo "✓ re2 already built for $SLICE_TAG"
    fi

    # ── protobuf libprotobuf (cross-compiled; protoc already on host) ────────
    local pb_install="$SLICE_INSTALL/protobuf"
    if [[ ! -f "$pb_install/lib/libprotobuf.a" ]]; then
        echo "--- libprotobuf $PROTOBUF_VERSION ---"
        local pb_src
        pb_src="$(fresh_source "protobuf-$PROTOBUF_VERSION.tar.gz")"
        patch_protobuf_for_arm64 "$pb_src"
        update_autotools_config_scripts "$pb_src"

        cd "$pb_src"
        CC="$CC_CMD" CXX="$CXX_CMD" \
        AR="$AR_CMD" RANLIB="$RANLIB_CMD" \
        CFLAGS="$CFLAGS_BASE" CXXFLAGS="$CXXFLAGS_BASE" \
        LDFLAGS="$LDFLAGS_BASE" \
        ./configure \
            --host="$AUTOTOOLS_HOST" \
            --prefix="$pb_install" \
            --disable-shared --enable-static \
            --with-pic \
            --disable-debug \
            ac_cv_func_memcmp_working=yes

        # Build only the runtime library, not protoc (that's on the host)
        make -j"$(sysctl -n hw.ncpu)" -C src libprotobuf.la
        make install-libLTLIBRARIES -C src DESTDIR="" || {
            # Fallback: manually install the .a
            mkdir -p "$pb_install/lib"
            find src -name "libprotobuf.a" -exec cp {} "$pb_install/lib/" \;
        }
        # Always install headers (make install-libLTLIBRARIES only installs the .a)
        mkdir -p "$pb_install/include"
        cp -r src/google "$pb_install/include/"
        echo "✓ libprotobuf → $pb_install"
    else
        echo "✓ libprotobuf already built for $SLICE_TAG"
    fi

    # ── OpenFst ─────────────────────────────────────────────────────────────
    local fst_install="$SLICE_INSTALL/openfst"
    if [[ ! -f "$fst_install/lib/libfst.a" ]]; then
        echo "--- OpenFst $OPENFST_VERSION ---"
        local fst_src
        fst_src="$(fresh_source "openfst-$OPENFST_VERSION.tar.gz")"
        update_autotools_config_scripts "$fst_src"
        patch_openfst_source "$fst_src"
        patch_openfst_for_cross_compile "$fst_src"

        cd "$fst_src"
        # --enable-grm enables all OpenGrm dependencies: far + pdt + mpdt.
        # Thrax requires fst/extensions/pdt/pdt.h (from --enable-pdt, implied by --enable-grm).
        # Disable extensions that use dlopen (forbidden on iOS) or require binaries.
        # Keep: far, pdt, mpdt (via --enable-grm), special, compact-fsts, const-fsts, lookahead-fsts.
        # Disable: script (uses dlopen/registry), bin (CLI tools), python, ngram-fsts.
        CC="$CC_CMD" CXX="$CXX_CMD" \
        AR="$AR_CMD" RANLIB="$RANLIB_CMD" \
        CFLAGS="$CFLAGS_BASE" CXXFLAGS="$CXXFLAGS_BASE" \
        LDFLAGS="$LDFLAGS_BASE" \
        ./configure \
            --host="$AUTOTOOLS_HOST" \
            --prefix="$fst_install" \
            --disable-shared --enable-static \
            --enable-grm \
            --enable-special=yes \
            --enable-compact-fsts=yes \
            --enable-const-fsts=yes \
            --enable-lookahead-fsts=yes \
            --enable-ngram-fsts=no \
            --enable-python=no \
            --disable-bin \
            ac_cv_func_fork_works=no \
            ac_cv_func_vfork_works=no

        make -j"$(sysctl -n hw.ncpu)"
        make install
        echo "✓ OpenFst → $fst_install"
    else
        echo "✓ OpenFst already built for $SLICE_TAG"
    fi

    # ── Thrax ────────────────────────────────────────────────────────────────
    local thrax_install="$SLICE_INSTALL/thrax"
    if [[ ! -f "$thrax_install/lib/libthrax.a" ]]; then
        echo "--- Thrax $THRAX_VERSION ---"
        local thrax_src
        thrax_src="$(fresh_source "thrax-$THRAX_VERSION.tar.gz")"
        update_autotools_config_scripts "$thrax_src"
        patch_thrax_for_openfst183 "$thrax_src" "$fst_install/include"
        patch_thrax_api_changes "$thrax_src"

        cd "$thrax_src"
        CC="$CC_CMD" CXX="$CXX_CMD" \
        AR="$AR_CMD" RANLIB="$RANLIB_CMD" \
        CFLAGS="$CFLAGS_BASE -I$fst_install/include" \
        CXXFLAGS="$CXXFLAGS_BASE -I$fst_install/include" \
        LDFLAGS="$LDFLAGS_BASE -L$fst_install/lib" \
        ./configure \
            --host="$AUTOTOOLS_HOST" \
            --prefix="$thrax_install" \
            --disable-shared --enable-static \
            --with-openfst-includes="$fst_install/include" \
            --with-openfst-libs="$fst_install/lib" \
            --disable-bin

        make -j"$(sysctl -n hw.ncpu)"
        make install
        echo "✓ Thrax → $thrax_install"
    else
        echo "✓ Thrax already built for $SLICE_TAG"
    fi

    # ── Sparrowhawk library ─────────────────────────────────────────────────
    # Only the library (libnormalizer, libsparrowhawk) — not normalizer_main binary.
    local sh_install="$SLICE_INSTALL/sparrowhawk"
    if [[ ! -f "$sh_install/lib/libsparrowhawk.a" ]] && \
       [[ ! -f "$sh_install/lib/libnormalizer.a" ]]; then
        echo "--- Sparrowhawk ---"
        local sh_src="$SOURCES_DIR/$SLICE_TAG/sparrowhawk"
        rm -rf "$sh_src"
        cp -r "$DOWNLOADS_DIR/sparrowhawk" "$sh_src"

        # Run autoreconf if configure is not present (guard avoids set -e failure
        # from the && short-circuit when configure already exists)
        if [[ ! -f "$sh_src/configure" ]]; then
            (cd "$sh_src" && autoreconf -if)
        fi

        # Patch configure: configure.ac hardcodes CXXFLAGS+=" -std=c++11" which
        # overrides our -std=c++17, breaking OpenFst 1.8.3 headers that need C++17
        # features (std::remove_extent_t, std::shared_mutex).
        if grep -q "std=c++11" "$sh_src/configure"; then
            sed -i.bak 's/-std=c++11/-std=c++17/g' "$sh_src/configure"
            echo "  Patched Sparrowhawk configure: c++11 → c++17"
        fi

        # Patch protobuf_serializer.cc: escape internal double quotes in string
        # field values so proto text format remains well-formed for inputs like
        # 6" pipe or "He's 50".
        patch_sparrowhawk_serializer "$sh_src"
        # Fix parser to handle unescaped '"' in token name strings from NeMo grammar
        patch_sparrowhawk_parser "$sh_src"

        # Copy pre-generated proto stubs so protoc is not needed at build time
        local proto_gen="$BUILD_DIR/sparrowhawk_proto_gen"
        if [[ -d "$proto_gen" ]]; then
            cp "$proto_gen"/*.pb.{h,cc} "$sh_src/src/proto/" 2>/dev/null || true
        fi

        mkdir -p "$sh_install"
        cd "$sh_src"
        CC="$CC_CMD" CXX="$CXX_CMD" \
        AR="$AR_CMD" RANLIB="$RANLIB_CMD" \
        CFLAGS="$CFLAGS_BASE \
            -I$fst_install/include \
            -I$thrax_install/include \
            -I$pb_install/include \
            -I$re2_install/include" \
        CXXFLAGS="$CXXFLAGS_BASE \
            -I$fst_install/include \
            -I$thrax_install/include \
            -I$pb_install/include \
            -I$re2_install/include" \
        LDFLAGS="$LDFLAGS_BASE \
            -L$fst_install/lib \
            -L$thrax_install/lib \
            -L$pb_install/lib \
            -L$re2_install/lib" \
        ./configure \
            --host="$AUTOTOOLS_HOST" \
            --prefix="$sh_install" \
            --disable-shared --enable-static \
            --with-openfst-includes="$fst_install/include" \
            --with-openfst-libs="$fst_install/lib" \
            --with-opengrm-thrax-includes="$thrax_install/include" \
            --with-opengrm-thrax-libs="$thrax_install/lib" \
            ac_cv_func_fork_works=no \
            ac_cv_func_vfork_works=no

        # Build only the library targets, skip normalizer_main (has main())
        make -j"$(sysctl -n hw.ncpu)" -C src lib || make -j"$(sysctl -n hw.ncpu)"
        # Try 'make install', but fall back to manual lib collection if
        # the binary link step fails due to unavailable iOS linker symbols
        make install 2>/dev/null || {
            mkdir -p "$sh_install/lib" "$sh_install/include"
            find src -name "*.a" -exec cp {} "$sh_install/lib/" \;
            find src -name "*.h" | while read -r h; do
                local rel
                rel="${h#src/}"
                mkdir -p "$sh_install/include/$(dirname "$rel")"
                cp "$h" "$sh_install/include/$rel"
            done
        }
        echo "✓ Sparrowhawk → $sh_install"
    else
        echo "✓ Sparrowhawk already built for $SLICE_TAG"
    fi

    # ── Merge all .a into one combined lib for this slice ───────────────────
    local merged_lib="$SLICE_INSTALL/libSparrowhawk.a"
    if [[ ! -f "$merged_lib" ]]; then
        echo "--- Merging static libs for $SLICE_TAG ---"
        # Collect every .a from all deps
        local all_libs=()
        while IFS= read -r -d '' lib; do
            all_libs+=("$lib")
        done < <(find \
            "$re2_install/lib" \
            "$pb_install/lib" \
            "$fst_install/lib" \
            "$thrax_install/lib" \
            "$sh_install/lib" \
            -name "*.a" -print0 2>/dev/null)

        # macOS libtool -static merges .a files (Apple libtool, not GNU)
        /usr/bin/libtool -static -o "$merged_lib" "${all_libs[@]}"
        echo "✓ Merged → $merged_lib"
        # Show size
        ls -lh "$merged_lib"
    else
        echo "✓ Merged lib already exists for $SLICE_TAG"
    fi

    # ── Collect headers ──────────────────────────────────────────────────────
    local headers_dir="$SLICE_INSTALL/Headers"
    if [[ ! -d "$headers_dir" ]]; then
        echo "--- Collecting headers for $SLICE_TAG ---"
        mkdir -p "$headers_dir"
        # Copy all public headers from each dep (preserve namespace subdirs)
        for dep_install in "$re2_install" "$pb_install" "$fst_install" \
                           "$thrax_install" "$sh_install"; do
            if [[ -d "$dep_install/include" ]]; then
                cp -r "$dep_install/include/." "$headers_dir/"
            fi
        done
        echo "✓ Headers collected"
    fi
}

# ── xcframework packaging ────────────────────────────────────────────────────
package_xcframework() {
    local output_xcfw="$OUTPUT_DIR/Sparrowhawk.xcframework"
    echo ""
    echo "=== Packaging xcframework ==="

    # Simulator: lipo arm64 + x86_64 into a fat lib
    local sim_arm64_lib="$SLICES_DIR/iphonesimulator-arm64/libSparrowhawk.a"
    local sim_x86_lib="$SLICES_DIR/iphonesimulator-x86_64/libSparrowhawk.a"
    local sim_fat_dir="$XCFW_STAGING/iphonesimulator-arm64_x86_64"
    mkdir -p "$sim_fat_dir"

    if [[ -f "$sim_arm64_lib" && -f "$sim_x86_lib" ]]; then
        lipo -create "$sim_arm64_lib" "$sim_x86_lib" \
            -output "$sim_fat_dir/libSparrowhawk.a"
        echo "✓ Simulator fat lib (arm64 + x86_64)"
    elif [[ -f "$sim_arm64_lib" ]]; then
        cp "$sim_arm64_lib" "$sim_fat_dir/libSparrowhawk.a"
        echo "✓ Simulator lib (arm64 only)"
    else
        echo "ERROR: No simulator lib found. Did the simulator build fail?"
        exit 1
    fi

    # Headers are the same for all slices; use the arm64-sim set
    local headers_src="$SLICES_DIR/iphonesimulator-arm64/Headers"

    # Device lib
    local device_dir="$XCFW_STAGING/iphoneos-arm64"
    mkdir -p "$device_dir"
    cp "$SLICES_DIR/iphoneos-arm64/libSparrowhawk.a" "$device_dir/libSparrowhawk.a"

    # Build xcframework
    rm -rf "$output_xcfw"
    xcodebuild -create-xcframework \
        -library "$device_dir/libSparrowhawk.a" \
        -headers "$headers_src" \
        -library "$sim_fat_dir/libSparrowhawk.a" \
        -headers "$headers_src" \
        -output "$output_xcfw"

    echo ""
    echo "✓ Sparrowhawk.xcframework → $output_xcfw"
    ls -lh "$output_xcfw"

    # ── Fix protobuf header mismatch ────────────────────────────────────────
    # The Sparrowhawk fork ships pre-committed .pb.h files in src/include/
    # generated by a newer protoc (3.x). make install copies those into the
    # xcframework headers. They reference port_def.inc and other 3.x features
    # that don't exist in protobuf 2.5.0. Replace them with the 2.5.0-generated
    # stubs we produced via build_host_protoc + generate_sparrowhawk_protos.
    local proto_gen="$BUILD_DIR/sparrowhawk_proto_gen"
    echo "--- Patching xcframework .pb.h files (2.5.0 compat) ---"
    for slice in ios-arm64 ios-arm64_x86_64-simulator; do
        for subdir in "sparrowhawk" "include/sparrowhawk"; do
            local dest="$output_xcfw/$slice/Headers/$subdir"
            [[ -d "$dest" ]] || continue
            for pbh in "$proto_gen"/*.pb.h; do
                cp "$pbh" "$dest/$(basename "$pbh")"
            done
        done
    done
    echo "✓ .pb.h files replaced with protobuf 2.5.0 generated versions"

    # fst/compat.h in OpenFst 1.8.3 no longer includes fst/types.h (which had
    # Google-style int32/int64 typedefs). sparrowhawk/regexp.h uses int32 directly.
    # When Swift imports CSparrowhawk, each header may be compiled in isolation,
    # so we must ensure compat.h pulls in the typedefs unconditionally.
    echo "--- Patching fst/compat.h to include fst/types.h ---"
    for slice in ios-arm64 ios-arm64_x86_64-simulator; do
        local compat="$output_xcfw/$slice/Headers/fst/compat.h"
        if [[ -f "$compat" ]] && ! grep -q "types.h" "$compat"; then
            echo "#include <fst/types.h>  // Google-style int32/int64 typedefs" >> "$compat"
        fi
    done
    echo "✓ fst/compat.h patched"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    check_prerequisites
    download_sources
    build_host_protoc
    generate_sparrowhawk_protos

    # Build all three slices (can comment out x86_64 if only Apple Silicon needed)
    build_slice arm64  iphoneos
    build_slice arm64  iphonesimulator
    build_slice x86_64 iphonesimulator

    package_xcframework

    echo ""
    echo "╔═══════════════════════════════════════════════════╗"
    echo "║  Sparrowhawk.xcframework built successfully!      ║"
    echo "║  Next: uncomment binaryTarget in Package.swift    ║"
    echo "╚═══════════════════════════════════════════════════╝"
}

main "$@"
