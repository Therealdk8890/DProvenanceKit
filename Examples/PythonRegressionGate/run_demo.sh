#!/bin/sh
# End-to-end check of the Python regression gate quickstart.
# Records a baseline, confirms an unchanged run passes, then confirms a run that
# skips the CRITICAL step fails the gate. Exits non-zero if either expectation breaks.
#
# Requires: python -m pip install dprovenancekit   (0.10.0 or later)
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/dpk-gate-example.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
cp "$here/agent.py" "$work/"
cd "$work"

echo "== 1. Record a known-good run and pin it as the baseline"
python agent.py
dpk record

echo "== 2. Unchanged agent: the gate should PASS"
python agent.py
dpk gate

echo "== 3. Agent skips its CRITICAL verify step: the gate should FAIL"
DPK_SIMULATE_REGRESSION=1 python agent.py
if dpk gate; then
  echo "UNEXPECTED: the gate passed a run that skipped verify_account_status" >&2
  exit 1
fi

echo "OK: baseline passed and the skipped-step regression was blocked."
