# Live Hugging Face notebook-flow test — September 9, 2026

Executed on this Apple Silicon Mac with Granite 4.1 3B and individual IBM HF adapters through Mellea. This did not execute the composed Granite Switch checkpoint or use vLLM. Only fictional documents were used, with offline inference after public adapter downloads.

| Scenario | Seconds | Result |
|---|---:|---|
| Relevant partial-write question | 1.84 | Incorrectly blocked by semantic scope check |
| Follow-up: what should I record? | 7.54 | Correct answer with citation: job identifier |
| Price absent from sources | 3.43 | Correctly requested more evidence |
| Ambiguous handoff with two possible recipients | 9.01 | Chose conversion handoff without asking clarification |

Individual calls also returned valid Guardian scores, query rewrite, answerability, generation and citations. The ambiguous standalone question “Should I do it again?” returned CLEAR. The relevant scope check passed with one description in the individual test but failed with a different, broader description in the full run. These results demonstrate compatibility, not reliable semantic gating or general accuracy. Times are single-run warm stage/flow measurements on tiny sources, not representative production latency.

The citation adapter returned offsets that did not match original strings. The pipeline now accepts a uniquely matching verbatim quotation when normalized offsets differ; unknown, ambiguous or uncovered attributions still withhold the answer. Regression tests cover that behavior.

Next investigation: benchmark Guardian criteria against a fixed set of in-scope/out-of-scope questions, and clarification against multiple ambiguous and explicit questions. Keep deterministic source grants independent of model relevance. Do not replace the existing app default based on this small sample.

Reproduce: `.venv/bin/python prepare.py --full-flow`, then `.venv/bin/python test_hf_flow_live.py`. Detailed outputs are in `hf-notebook-flow-live.json`.
