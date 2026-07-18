#!/usr/bin/env bash
# export_grammars.sh
#
# Run NeMo's pynini_export.py to compile the Python WFST grammars into
# OpenFst .far archives for English TN (text normalization, written→spoken).
#
# Prerequisites:
#   conda env with nemo_text_processing installed:
#     conda create -n nemo-tn python=3.10
#     conda activate nemo-tn
#     conda install -c conda-forge pynini==2.1.6.post1
#     pip install nemo_text_processing
#
# Usage (from repo root, with conda env activated):
#   bash Scripts/export_grammars.sh /path/to/NeMo-text-processing
#
# Output:
#   Sources/TextNormalization/Resources/en_tn_grammars_cased/
#     classify/tokenize_and_classify.far   (rule: TOKENIZE_AND_CLASSIFY)
#     verbalize/verbalize.far              (rules: ALL, REDUP)
#     verbalize/post_process.far           (rule: POSTPROCESSOR — English only)
#
# Note on post_process.far:
#   The standard Sparrowhawk config omits post-processing. We use the _pp
#   variant (sparrowhawk_configuration_pp.ascii_proto) so that the C++ output
#   matches the Python Normalizer's space/punctuation cleanup — which is what
#   the upstream test fixtures assume.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Positional arg: path to the cloned NeMo-text-processing repo
NEMO_REPO="${1:-}"
if [[ -z "$NEMO_REPO" ]]; then
    # Try sibling directory (Annologue/Packages layout)
    NEMO_REPO="$(dirname "$REPO_ROOT")/NeMo-text-processing"
fi

if [[ ! -f "$NEMO_REPO/tools/text_processing_deployment/pynini_export.py" ]]; then
    echo "ERROR: Cannot find pynini_export.py in $NEMO_REPO"
    echo "Usage: bash Scripts/export_grammars.sh /path/to/NeMo-text-processing"
    exit 1
fi

# Check that pynini is importable
python3 -c "import pynini" 2>/dev/null || {
    echo "ERROR: pynini not importable. Activate the conda env:"
    echo "  conda activate nemo-tn"
    exit 1
}

EXPORT_OUTPUT="$REPO_ROOT/build/far_export"
mkdir -p "$EXPORT_OUTPUT"

DEST="$REPO_ROOT/Sources/TextNormalization/Resources/en_tn_grammars_cased"
mkdir -p "$DEST"

echo "→ Exporting English TN grammars (this takes a few minutes)..."
python3 "$NEMO_REPO/tools/text_processing_deployment/pynini_export.py" \
    --output_dir="$EXPORT_OUTPUT" \
    --grammars=tn_grammars \
    --language=en \
    --input_case=cased \
    --overwrite_cache

# The exporter writes to en_tn_grammars_cased/ inside output_dir
FAR_SRC="$EXPORT_OUTPUT/en_tn_grammars_cased"
if [[ ! -d "$FAR_SRC" ]]; then
    echo "ERROR: expected output dir not found: $FAR_SRC"
    echo "Check the pynini_export.py output above for errors."
    exit 1
fi

# Copy to Resources
cp -r "$FAR_SRC/." "$DEST/"

echo ""
echo "✓ FAR files in $DEST:"
find "$DEST" -name "*.far" | sort
echo ""

# ── Sparrowhawk config files ─────────────────────────────────────────────────
# Pull the .ascii_proto config files from the anand-nv/sparrowhawk fork.
# These are NOT in the NeMo repo; they live under:
#   documentation/grammars/en_toy/sparrowhawk_configuration*.ascii_proto
SPARROWHAWK_REPO_CACHED="$REPO_ROOT/build/sparrowhawk/downloads/sparrowhawk"
CONFIG_DEST="$REPO_ROOT/Sources/TextNormalization/Resources/config"
mkdir -p "$CONFIG_DEST"

if [[ -d "$SPARROWHAWK_REPO_CACHED/documentation" ]]; then
    echo "→ Copying config files from cached Sparrowhawk clone..."
    cp "$SPARROWHAWK_REPO_CACHED"/documentation/grammars/en_toy/*.ascii_proto \
       "$CONFIG_DEST/" 2>/dev/null || true
    cp "$SPARROWHAWK_REPO_CACHED"/src/proto/*.proto \
       "$CONFIG_DEST/" 2>/dev/null || true
else
    echo "→ Cloning Sparrowhawk fork to extract config files..."
    local_sh="$REPO_ROOT/build/sparrowhawk_config_tmp"
    git clone https://github.com/anand-nv/sparrowhawk.git "$local_sh" \
        --branch nemo_tests --depth 1
    cp "$local_sh"/documentation/grammars/en_toy/*.ascii_proto \
       "$CONFIG_DEST/" 2>/dev/null || true
    cp "$local_sh"/src/proto/*.proto \
       "$CONFIG_DEST/" 2>/dev/null || true
    rm -rf "$local_sh"
fi

echo "→ Config files:"
ls "$CONFIG_DEST/" 2>/dev/null || echo "  (none — check Sparrowhawk clone above)"

echo ""
echo "NEXT STEPS:"
echo "  1. Verify the FAR rule names match GrammarBundle.swift expectations:"
echo "     classify/tokenize_and_classify.far → rule: TOKENIZE_AND_CLASSIFY"
echo "     verbalize/verbalize.far            → rules: ALL, REDUP"
echo "     verbalize/post_process.far         → rule: POSTPROCESSOR"
echo "  2. GrammarBundle.swift uses proto fields: tokenizer_grammar,"
echo "     verbalizer_grammar, postprocessor_grammar (NOT verbalizer_pp_grammar)."
echo "  3. Run swift test (or xcodebuild test) to run the spec test suite."
