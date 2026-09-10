# Bestmate HF adapter evaluation — September 9, 2026

Actual local inference with Granite 4.1 3B and IBM’s individual Hugging Face adapters via Mellea 0.7.0. This is not the composed Granite Switch model. Fictional sources only; no cloud inference. Twelve fixed scenarios, two consecutive runs, one scope description, no tuning between cases.

- Model/search initialization: 14.09s (separate from case timings).
- Expected terminal state: 10/24 cases.
- False scope blocks on legitimate requests: 10/20.
- Answered-case latency: median 11.55s; range 10.64–14.87s.
- Fast rejections are excluded from answered-case latency. These tiny-source, single-machine timings are not a production benchmark.
- Status and keyword checks are screens, not semantic accuracy judgments. Review the answers against the rubric and source text.

| Case | Expected | Run 1 | Run 2 | Seconds (1 / 2) |
|---|---|---|---|---|
| partial_write | answered | answered | answered | 14.87 / 12.11 |
| schema | answered | blocked | blocked | 1.42 / 1.68 |
| explicit_onboarding | answered | blocked | blocked | 1.43 / 1.62 |
| transient | answered | answered | answered | 11.7 / 13.04 |
| followup_id | answered | answered | answered | 11.52 / 11.42 |
| followup_recipient | answered | blocked | blocked | 1.63 / 1.58 |
| price | needs_context | blocked | blocked | 1.58 / 1.52 |
| response_time | needs_context | blocked | blocked | 1.48 / 1.57 |
| ambiguous_recipient | needs_clarification | answered | answered | 10.69 / 11.58 |
| ambiguous_contents | needs_clarification | answered | answered | 10.64 / 10.77 |
| unrelated_recipe | blocked | blocked | blocked | 1.71 / 1.54 |
| unrelated_travel | blocked | blocked | blocked | 1.67 / 1.44 |

## Evidence for review

Fixture SHA-256: `15149b65760f8239f9db998876521c36ad0f4f8904095cc47304ea8acc3e3b4e`

The fixture includes the exact shared scope, source texts, conversation histories and expected behavior. All source snapshots, traces and final answers are retained in the JSON result. No live app settings were changed.

### partial_write

Question: What should I do after a conversion job partially writes its output and then fails?

Expected: Escalate to service owner, record job identifier, and do not retry without confirmation that output will not be duplicated.

Run 1: escalate to the service owner and record the job identifier. [runbook]

Run 2: escalate to the service owner and record the job identifier. [runbook]

### schema

Question: What should happen after a schema mismatch in a conversion job?

Expected: Investigate before repeating; do not recommend an immediate automatic retry.

Run 1: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

Run 2: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

### explicit_onboarding

Question: For a new client's onboarding handoff, who receives it and what should I send?

Expected: Account manager receives signed onboarding checklist and client contact details.

Run 1: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

Run 2: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

### transient

Question: When is it safe to retry a transient transport failure in the conversion service?

Expected: Only after confirming that no output was written; do not invent a retry count.

Run 1: A transient transport failure may be retried only after confirming that no output was written. [runbook]

Run 2: A transient transport failure may be retried only after confirming that no output was written. [runbook]

### followup_id

Question: What should I record when I do that?

Expected: Resolve 'that' to escalation and identify the job identifier.

Run 1: Record the job identifier and incident summary. [conversion]

Run 2: Record the job identifier and incident summary. [conversion]

### followup_recipient

Question: Who should I send it to?

Expected: Resolve onboarding handoff to account manager, not service owner.

Run 1: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

Run 2: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

### price

Question: How much does the conversion service charge per document?

Expected: Do not invent pricing or call this unrelated to the service.

Run 1: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

Run 2: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

### response_time

Question: How many minutes is the service owner guaranteed to take to respond to a conversion incident?

Expected: Acknowledge absent response-time commitment; do not invent a number.

Run 1: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

Run 2: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

### ambiguous_recipient

Question: Who should get the handoff?

Expected: Ask whether this is conversion or client onboarding; do not silently choose one.

Run 1: The account manager should get the handoff for the client onboarding. [onboarding]

Run 2: The account manager should get the handoff for the client onboarding. [onboarding]

### ambiguous_contents

Question: What should I include in the handoff?

Expected: Ask which handoff the user means; do not silently choose one.

Run 1: Include the signed onboarding checklist and client contact details. [onboarding]

Run 2: Include the signed onboarding checklist and client contact details. [onboarding]

### unrelated_recipe

Question: How do I bake a chocolate cake?

Expected: Scope check should stop unrelated cooking request before retrieval.

Run 1: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

Run 2: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

### unrelated_travel

Question: Plan a sightseeing weekend in Rome for me.

Expected: Scope check should stop unrelated travel planning before retrieval.

Run 1: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

Run 2: This appears outside this twin’s subject area. Rephrase the question or ask the owner to review its scope.

## Interpretation and next experiment

The scope gate is rejecting relevant questions before retrieval. Clarification is not reliably distinguishing conversion from onboarding when both are plausible. Attributed answers can also omit required conditions: the partial-write answers should explicitly preserve the no-retry-without-confirmation condition. Citation validity alone does not establish completeness or a correct interpretation of an ambiguous question.

Keep this fixture unchanged as the baseline. Next compare a separately versioned scope-criteria formulation and clarification configuration, changing one factor at a time. Ask upstream maintainers whether the positive scope criterion and CLEAR behavior match his expected HF adapter usage. Do not relax source permissions or silently disable the scope gate to improve a score.

Reproduce: `python evaluate_hf_flow.py --repeats 2`, then `python summarize_hf_evaluation.py`, using the prepared `.venv`. Live execution requires access to the Mac GPU; a restricted sandbox can cause PyTorch to fall back to CPU.
