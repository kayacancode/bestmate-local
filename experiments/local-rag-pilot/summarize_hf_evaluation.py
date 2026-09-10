"""Summarize completed evaluations; status/keyword checks are not human accuracy scores."""
import json,statistics
from pathlib import Path
ROOT=Path(__file__).resolve().parent
p=ROOT/'results/hf-flow-evaluation.json';data=json.loads(p.read_text());rows=data['cases']
fixture=json.loads((ROOT/'hf_flow_cases.json').read_text())
assert len(rows)==len(fixture['cases'])*data['repeats'],'Evaluation is incomplete'
answered=[c for c in rows if c.get('result',{}).get('status')=='answered']
legitimate=[c for c in rows if c['category']!='unrelated']
false_blocks=[c for c in legitimate if c.get('result',{}).get('status')=='blocked']
lines=['# Bestmate HF adapter evaluation — September 9, 2026','',
       'Actual local inference with Granite 4.1 3B and IBM’s individual Hugging Face adapters via Mellea 0.7.0. This is not the composed Granite Switch model. Fictional sources only; no cloud inference. Twelve fixed scenarios, two consecutive runs, one scope description, no tuning between cases.','',
       f"- Model/search initialization: {data['load_seconds']:.2f}s (separate from case timings).",
       f"- Expected terminal state: {sum(c['status_pass'] for c in rows)}/{len(rows)} cases.",
       f"- False scope blocks on legitimate requests: {len(false_blocks)}/{len(legitimate)}.",
       f"- Answered-case latency: median {statistics.median(c['seconds'] for c in answered):.2f}s; range {min(c['seconds'] for c in answered):.2f}–{max(c['seconds'] for c in answered):.2f}s.",
       '- Fast rejections are excluded from answered-case latency. These tiny-source, single-machine timings are not a production benchmark.',
       '- Status and keyword checks are screens, not semantic accuracy judgments. Review the answers against the rubric and source text.','',
       '| Case | Expected | Run 1 | Run 2 | Seconds (1 / 2) |','|---|---|---|---|---|']
for case in fixture['cases']:
    runs=[c for c in rows if c['id']==case['id']]
    lines.append('| '+case['id']+' | '+', '.join(case['expected'])+' | '+' | '.join(c.get('result',{}).get('status','error') for c in runs)+' | '+' / '.join(str(c['seconds']) for c in runs)+' |')
lines+=['','## Evidence for review','',f"Fixture SHA-256: `{data['fixture_sha256']}`",'',
        'The fixture includes the exact shared scope, source texts, conversation histories and expected behavior. All source snapshots, traces and final answers are retained in the JSON result. No live app settings were changed.','']
for case in fixture['cases']:
    runs=[c for c in rows if c['id']==case['id']]
    lines += ['### '+case['id'],'','Question: '+case['question'],'','Expected: '+case['rubric'],'']
    for c in runs:lines += [f"Run {c['repeat']}: "+c.get('result',{}).get('answer',c.get('error','')),'']
lines += ['## Interpretation and next experiment','',
          'The scope gate is rejecting relevant questions before retrieval. Clarification is not reliably distinguishing conversion from onboarding when both are plausible. Attributed answers can also omit required conditions: the partial-write answers should explicitly preserve the no-retry-without-confirmation condition. Citation validity alone does not establish completeness or a correct interpretation of an ambiguous question.','',
          'Keep this fixture unchanged as the baseline. Next compare a separately versioned scope-criteria formulation and clarification configuration, changing one factor at a time. Ask upstream maintainers whether the positive scope criterion and CLEAR behavior match his expected HF adapter usage. Do not relax source permissions or silently disable the scope gate to improve a score.','',
          'Reproduce: `python evaluate_hf_flow.py --repeats 2`, then `python summarize_hf_evaluation.py`, using the prepared `.venv`. Live execution requires access to the Mac GPU; a restricted sandbox can cause PyTorch to fall back to CPU.']
(ROOT/'results/hf-flow-evaluation.md').write_text('\n'.join(lines)+'\n')
print('Saved report with',len(rows),'cases')
