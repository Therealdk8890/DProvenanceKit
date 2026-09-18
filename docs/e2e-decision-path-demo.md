# End-to-end decision-path demo

> Runnable twin of the Python [`examples/e2e_decision_path`](https://github.com/Therealdk8890/DProvenanceKitPython/tree/main/examples/e2e_decision_path) demo:
> Instrument → Record → Baseline → Compare → Gate → Attest → Verify.

```sh
swift run E2EDecisionPathDemo
swift run E2EDecisionPathDemo --output-dir /tmp/dpk-e2e --keep
```

The candidate deliberately drops CRITICAL `claimVerified`. The gate must fail at **HIGH**;
the baseline attestation must verify. CI locks the stdout markers
`GATE_RESULT=FAIL`, `GATE_LEVEL=high`, `ATTEST_VERIFY=valid`, `DEMO_OK` via
`E2EDecisionPathDemoTests`.

See [Examples/E2EDecisionPath/README.md](../Examples/E2EDecisionPath/README.md).
