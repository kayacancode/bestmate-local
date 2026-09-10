# Guardian scope diagnostic — September 9, 2026

Investigated the scope rejections from the fixed HF evaluation. The installed Mellea 0.7.0 code maps `target_role="user"` to its `user_prompt` scoring schema; this is not an accidental assistant-role check. Tests used the same cached Granite 4.1 3B and individual Guardian adapter on MPS. No source permissions or thresholds changed.

Four formulations were compared on the original 12 questions plus eight additional questions fixed before the run. Two follow-up formulations reused those same questions; the additional questions are therefore diagnostic coverage, not a pristine final validation set. Each formulation was run once. All exact criteria, histories, numeric scores and timings are retained in the JSON artifacts.

| Formulation | Correct decisions | False blocks / 14 relevant | False allows / 6 unrelated |
|---|---:|---:|---:|
| baseline | 13/20 | 7/14 | 0/6 |
| scope_only | 11/20 | 9/14 | 0/6 |
| definition | 13/20 | 7/14 | 0/6 |
| context_schema | 13/20 | 7/14 | 0/6 |
| off_topic | 13/20 | 1/14 | 6/6 |
| topic_list | 11/20 | 9/14 | 0/6 |

## Decision

No tested formulation is a reliable improvement. Keep the existing positive scope gate and 0.5 threshold unchanged. Inverting the criterion to off-topic admits all unrelated examples and must not be promoted merely because it reduces false blocks. A longer domain definition fixes some items while failing others. Removing the preamble and using a topic list are worse overall.

The original configuration gives the pricing question an in-scope score of about 0.068 and the explicit onboarding question about 0.407. Both are relevant, even when their answer is absent from sources. Scores are model outputs, not calibrated confidence.

Added response diagnostics: `guardian_scores` contains validated numeric check outputs; blocked results include `blocked_by` (`guardian_harm` or `guardian_scope`). Existing status values, threshold, retrieval boundaries and access grants remain unchanged. Deterministic tests cover these diagnostic fields. The native UI does not yet render the new score fields.

## Question for upstream maintainers

Are the positive custom-scope criterion, `user_prompt` scoring schema and 0.5 cutoff the intended configuration for `guardian-core` on Granite 4.1 3B through LocalHFBackend? Is there a reference criteria/scoring example or adapter configuration we should compare before attempting calibration? The scope definitions and scores here make the issue reproducible.

## Reproduce

Prepare the full-flow adapters, then run `.venv/bin/python evaluate_scope.py`. The follow-up run is `.venv/bin/python evaluate_scope.py --variants off_topic topic_list --out scope-diagnostic-followup.json`. A non-default cache may be selected with `BESTMATE_HF_CACHE`; no personal cache path is stored in the reports. The script refuses silent CPU fallback.

- [Initial comparison](scope-diagnostic.json)
- [Follow-up comparison](scope-diagnostic-followup.json)
