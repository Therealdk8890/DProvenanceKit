#!/usr/bin/env bash
# Re-sync the vendored Trace Specification v1 vectors from the canonical Python repo,
# then show what changed. The Python repo is the source of truth (the reference oracle);
# this directory keeps a vendored copy so the Swift harness stays self-contained.
#
#   ConformanceHarness/sync-vectors.sh [path-to-python-conformance-vectors]
#   DPROV_PY_VECTORS=/path/to/vectors ConformanceHarness/sync-vectors.sh
set -euo pipefail
SRC="${1:-${DPROV_PY_VECTORS:-$HOME/DProvenanceKitPython/conformance/vectors}}"
DEST="$(cd "$(dirname "$0")" && pwd)/vectors"
if [ ! -d "$SRC" ]; then
    echo "canonical vectors not found: $SRC" >&2
    echo "pass the path as an argument or set DPROV_PY_VECTORS." >&2
    exit 1
fi
cp "$SRC"/*.json "$DEST"/
echo "synced vectors from: $SRC"
git -C "$DEST" status --short -- . 2>/dev/null || true
