# End-to-end decision-path demo

One-shot walkthrough of the DProvenanceKit product loop with **real library APIs**:

```
Instrument → Record → Baseline → Compare → Gate → Attest → Verify
```

The demo records a clean baseline path, pins it (attestable JSON + `baseline.sqlite`), then
records a candidate that **drops the CRITICAL `claimVerified` step**. Alignment/gate reports
severity **HIGH** and the demo prints `GATE_RESULT=FAIL`. Separately, the baseline run is
signed with a software P-256 key (`DPK-BINARY-V1`) and verified.

**Honest scope:** tamper-evident record of an *instrumented* decision path, a CI gate on
path regression, and a software attestation of that record. This does **not** prove that the
decision was sound, compliant, or correct — only that the recorded path is comparable and
(when attested) integrity-checkable.

Python counterpart:  
[Therealdk8890/DProvenanceKitPython `examples/e2e_decision_path`](https://github.com/Therealdk8890/DProvenanceKitPython/tree/main/examples/e2e_decision_path).

## Fixtures

| File | Role |
|------|------|
| `fixtures/baseline_path.json` | Clean path: retrieve → **verify** → decide |
| `fixtures/candidate_regressed.json` | Same path with CRITICAL verify removed |

(Fixture JSON is documentary; the runnable demo embeds the same steps in Swift.)

## Run (one shot)

From the repository root:

```bash
swift run E2EDecisionPathDemo
```

Keep artifacts on disk:

```bash
swift run E2EDecisionPathDemo --output-dir /tmp/dpk-e2e --keep
```

## Expected outcome

- Gate: `regressionRisk.level == high`, demo prints `GATE_RESULT=FAIL` / `GATE_LEVEL=high`
- Attest+verify on baseline: demo prints `ATTEST_VERIFY=valid`
- Overall demo exit 0 when that story holds (`DEMO_OK`)

## What this is not

- Not ClaimProofKit / commercial packaging
- Not a proof of sound reasoning
- Not a production matcher rewrite — it calls the existing align/gate/attest APIs
