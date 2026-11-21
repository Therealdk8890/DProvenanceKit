# Python regression gate in 60 seconds

This example shows the core DProvenanceKit idea on any OS, with Python and no
model or API key: record a known-good agent run, then fail when a later run
skips a step you marked CRITICAL, even though the final answer is unchanged.

```bash
python -m pip install dprovenancekit
sh run_demo.sh
```

What happens:

1. `python agent.py` records a run to `.dprovenance/traces.sqlite`.
2. `dpk record` pins it as the baseline (`.dprovenance/baseline.sqlite`).
3. The same agent runs again and `dpk gate` prints `Regression gate: PASS`.
4. With `DPK_SIMULATE_REGRESSION=1` the agent skips `verify_account_status`,
   still answers `approved`, and `dpk gate` prints
   `REGRESSION / CRITICAL step removed` and exits 1.

The script runs in a temporary directory and exits non-zero if the gate does not
pass the good run or does not block the regressed one.

## Use it on your own agent

- Decorate your agent's steps with `@traced`, and mark the ones that must never
  silently disappear with `priority=TracePriority.CRITICAL`.
- Wrap one agent invocation in `traced_run(context_id=...)`.
- Run once, `dpk record`, commit `.dprovenance/baseline.sqlite`.
- Add [github-workflow.example.yml](github-workflow.example.yml) to
  `.github/workflows/` so every pull request runs `dpk gate`.

For a sticky pull-request comment with the verdict, see the
[DProvenanceKit regression gate action](https://github.com/marketplace/actions/dprovenancekit-regression-gate).
Framework adapters (LangChain/LangGraph, OpenAI Agents, LlamaIndex, CrewAI) and
OpenTelemetry trace ingestion are documented in the
[Python SDK](https://github.com/Therealdk8890/DProvenanceKitPython).

## Scope

The gate compares the steps your code instruments. A passing gate does not prove
the agent's answer is correct, and a missing event means it was not recorded,
not that it never happened.
