#!/usr/bin/env bash
# Fail if README / docs version claims drift from Version.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT/Sources/DProvenanceKit/Version.swift"
README="$ROOT/README.md"
MATRIX="$ROOT/docs/VERSION_SURFACE.md"

swift_ver="$(sed -n 's/.*public static let current = "\([^"]*\)".*/\1/p' "$VERSION_FILE" | head -1)"
if [[ -z "$swift_ver" ]]; then
  echo "error: could not parse DProvenanceKitVersion.current from $VERSION_FILE" >&2
  exit 1
fi

readme_from="$(grep -oE 'from: "[0-9]+\.[0-9]+\.[0-9]+"' "$README" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [[ -z "$readme_from" ]]; then
  echo "error: could not find SPM from: \"X.Y.Z\" pin in README.md" >&2
  exit 1
fi

if [[ "$readme_from" != "$swift_ver" ]]; then
  echo "error: README install pin ($readme_from) != Version.swift ($swift_ver)" >&2
  exit 1
fi

if ! grep -q "$swift_ver" "$MATRIX"; then
  echo "error: docs/VERSION_SURFACE.md does not mention Swift $swift_ver" >&2
  exit 1
fi

# Attestation matrix honesty: Python column must not say "Not yet" for attestation.
if grep -E 'Trace attestation.*\|.*\|.*Not yet' "$README" >/dev/null; then
  echo "error: README attestation matrix still says Python is Not yet — update to MVP yes (0.7.0+)" >&2
  exit 1
fi

echo "version surface ok: Swift $swift_ver; README pin matches; attestation matrix not 'Not yet' for Python"
