"""A tiny account-check agent instrumented with DProvenanceKit (Python).

Run it normally to record a good run. Set DPK_SIMULATE_REGRESSION=1 to make the
agent "forget" its CRITICAL verification step, the kind of silent change a model,
prompt, or refactor can introduce while the final answer still looks right.

No model, API key, or network access is used; replace the function bodies with
your own agent's steps.
"""
import os

from dprovenancekit import TracePriority, record_event, traced, traced_run


@traced(capture_args=False, capture_result=False)
def retrieve_account_context():
    return {"account_id": "demo-001", "status": "active"}


@traced(priority=TracePriority.CRITICAL, capture_args=False, capture_result=False)
def verify_account_status(account):
    return account["status"] == "active"


@traced(capture_args=False, capture_result=False)
def decide_account_action(is_active):
    return "approved" if is_active else "manual_review"


def main() -> None:
    skip_verify = os.environ.get("DPK_SIMULATE_REGRESSION") == "1"
    with traced_run(context_id="account-check") as run:
        account = retrieve_account_context()
        if skip_verify:
            is_active = account["status"] == "active"  # verification silently skipped
        else:
            is_active = verify_account_status(account)
        decision = decide_account_action(is_active)
        record_event("decision_made", {"decision": decision})

    print("Decision: {}  (run {})".format(decision, run.run_id))


if __name__ == "__main__":
    main()
