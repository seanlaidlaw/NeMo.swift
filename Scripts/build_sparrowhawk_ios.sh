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

    local src_dir="$SOURCES_DIR/host_protobuf"
    rm -rf "$src_dir"
    tar xzf "$DOWNLOADS_DIR/protobuf-$PROTOBUF_VERSION.tar.gz" -C "$SOURCES_DIR"
    mv "$SOURCES_DIR/protobuf-$PROTOBUF_VERSION" "$src_dir"

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

    # Simulator vs device LLVM triple
    local TRIPLE
    if [[ "$SDK_NAME" == "iphonesimulator" ]]; then
        TRIPLE="${ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
    else
        TRIPLE="${ARCH}-apple-ios${IOS_DEPLOYMENT_TARGET}"
    fi

    # Common cross-compile env variables (autotools picks these up)
    local CFLAGS_BASE="-arch $ARCH -isysroot $SDK_PATH -target $TRIPLE -fembed-bitcode-marker"
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
            -DCMAKE_C_FLAGS="$CFLAGS_BASE" \
            -DCMAKE_CXX_FLAGS="$CXXFLAGS_BASE" \
            -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS_BASE" \
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

        cd "$pb_src"
        CC="$CC_CMD" CXX="$CXX_CMD" \
        AR="$AR_CMD" RANLIB="$RANLIB_CMD" \
        CFLAGS="$CFLAGS_BASE" CXXFLAGS="$CXXFLAGS_BASE" \
        LDFLAGS="$LDFLAGS_BASE" \
        ./configure \
            --host=arm-apple-darwin \
            --prefix="$pb_install" \
            --disable-shared --enable-static \
            --with-pic \
            --disable-debug \
            ac_cv_func_memcmp_working=yes

        # Build only the runtime library, not protoc (that's on the host)
        make -j"$(sysctl -n hw.ncpu)" -C src libprotobuf.la
        make install-libLTLIBRARIES -C src DESTDIR="" || {
            # Fallback: manually install the .a
            mkdir -p "$pb_install/lib" "$pb_install/include"
            find src -name "libprotobuf.a" -exec cp {} "$pb_install/lib/" \;
            cp -r src/google "$pb_install/include/"
        }
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

        cd "$fst_src"
        # Disable extensions that use dlopen (forbidden on iOS) or require binaries.
        # Keep: far (FAR archive I/O — required by Thrax/Sparrowhawk)
        # Keep: special (special FST types used by Thrax grammars)
        # Disable: script (uses dlopen/registry), bin (CLI tools), python
        CC="$CC_CMD" CXX="$CXX_CMD" \
        AR="$AR_CMD" RANLIB="$RANLIB_CMD" \
        CFLAGS="$CFLAGS_BASE" CXXFLAGS="$CXXFLAGS_BASE" \
        LDFLAGS="$LDFLAGS_BASE" \
        ./configure \
            --host=arm-apple-darwin \
            --prefix="$fst_install" \
            --disable-shared --enable-static \
            --enable-far=yes \
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

        cd "$thrax_src"
        CC="$CC_CMD" CXX="$CXX_CMD" \
        AR="$AR_CMD" RANLIB="$RANLIB_CMD" \
        CFLAGS="$CFLAGS_BASE -I$fst_install/include" \
        CXXFLAGS="$CXXFLAGS_BASE -I$fst_install/include" \
        LDFLAGS="$LDFLAGS_BASE -L$fst_install/lib" \
        ./configure \
            --host=arm-apple-darwin \
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

        # Run autoreconf if configure is not present
        (cd "$sh_src" && [[ ! -f configure ]] && autoreconf -if)

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
            --host=arm-apple-darwin \
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
