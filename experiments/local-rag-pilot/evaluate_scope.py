"""Scope-only diagnostic. Fixed development fixture + separately listed holdouts.
Never changes source permissions or the acceptance threshold.
"""
import os,json,time,signal,hashlib,argparse
from pathlib import Path
ROOT=Path(__file__).resolve().parent
os.environ['HF_HOME']=os.environ.get('BESTMATE_HF_CACHE',str(ROOT/'.cache/huggingface'))
for k in ['HF_HUB_OFFLINE','TRANSFORMERS_OFFLINE','HF_HUB_DISABLE_TELEMETRY','HF_DEACTIVATE_ASYNC_LOAD']:os.environ[k]='1'
os.environ['TOKENIZERS_PARALLELISM']='false'
DEFINITION=('Document conversion service and client onboarding operations concern processing input documents, validating schemas, writing output, troubleshooting failed jobs, deciding whether retries are safe, and handing work to the responsible service owner or account manager. '
'Questions about this service’s capabilities, costs, incident response, job records, or onboarding requirements belong to this domain even if the available documents do not contain the answer. '
'Questions about an unspecified handoff or follow-up references to these operations also belong to the domain. Unrelated uses of the words conversion, account or service do not by themselves belong to this domain.')
HOLDOUT=[
 {'id':'holdout_duplicate','question':'The converter saved half the file. Can I run the job again?','relevant':True},
 {'id':'holdout_regions','question':'Which regions can our document conversion service run in?','relevant':True},
 {'id':'holdout_contact','question':'Who receives the new client’s signed onboarding paperwork?','relevant':True},
 {'id':'holdout_followup','question':'What if some output already exists?','history':[{'role':'user','content':'Can I retry the failed document conversion?'},{'role':'assistant','content':'First establish whether the job wrote output.'}],'relevant':True},
 {'id':'holdout_temperature','question':'How do I convert 90 degrees Fahrenheit to Celsius?','relevant':False},
 {'id':'holdout_bank','question':'Which bank account should I open for better savings interest?','relevant':False},
 {'id':'holdout_car','question':'How often should I service my car?','relevant':False},
 {'id':'holdout_garden','question':'What flowers should I plant in a shady garden?','relevant':False}
]
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--variants',nargs='+',default=['baseline','scope_only','definition','context_schema']);parser.add_argument('--out',default='scope-diagnostic.json');args=parser.parse_args()
 import torch
 if not torch.backends.mps.is_available():raise RuntimeError('Mac GPU unavailable. Run outside restricted sandbox; refusing silent CPU fallback.')
 from backends import GraniteAdapters
 from granite_switch_backend import SwitchIntrinsics
 from mellea.stdlib.components.intrinsic.guardian import guardian_check
 from mellea.stdlib.components.chat import Message
 fixture=json.loads((ROOT/'hf_flow_cases.json').read_text())
 baseline='The request relates to the following workspace purpose or source subjects, including follow-up questions about them: '+fixture['scope']
 variants={'baseline':(baseline,'user_prompt'),'scope_only':(fixture['scope'],'user_prompt'),'definition':(DEFINITION,'user_prompt'),'context_schema':(baseline,"Interpret the last user's message in the context of the preceding conversation. If its subject meets the criteria, return 'yes'; otherwise return 'no'.")}
 variants['off_topic'] = ('Off-topic content is a request about a subject outside this domain: '+DEFINITION, 'user_prompt')
 variants['topic_list'] = ('The user asks about document conversion jobs, retrying failures, schema mismatches, service pricing, response times, onboarding clients, or handing off work.', 'user_prompt')
 cases=[{**c,'relevant':c['category']!='unrelated','split':'development'} for c in fixture['cases']]+[{**c,'split':'holdout'} for c in HOLDOUT]
 report={'threshold':.5,'device':'mps','variants':variants,'cases':cases,'results':[],'notice':'Exploratory prompt comparison, not calibrated confidence. Holdouts were fixed before this run. Source permissions unchanged.'}
 out=ROOT/'results'/args.out
 def timeout(*_):raise TimeoutError('Guardian call exceeded 120 seconds')
 signal.signal(signal.SIGALRM,timeout)
 print('Loading HF model',flush=True);begin=time.monotonic();local=GraniteAdapters();ops=SwitchIntrinsics.__new__(SwitchIntrinsics);ops.backend=local.backend;report['load_seconds']=round(time.monotonic()-begin,2)
 for name in args.variants:
  criteria,schema=variants[name]
  for case in cases:
   print('START',name,case['id'],flush=True);begin=time.monotonic();signal.alarm(120)
   row={'variant':name,'id':case['id'],'split':case['split'],'expected_relevant':case['relevant']}
   try:
    ctx=ops.context(case.get('history',[])).add(Message('user',case['question']))
    score=guardian_check(ctx,local.backend,criteria,scoring_schema=schema)
    relevant = score < .5 if name == 'off_topic' else score >= .5
    row.update(score=score,relevant=relevant,correct=relevant==case['relevant'],score_meaning='off_topic' if name=='off_topic' else 'in_scope')
   except Exception as e:row.update(error=type(e).__name__+': '+str(e)[:500],correct=False)
   finally:signal.alarm(0)
   row['seconds']=round(time.monotonic()-begin,2);report['results'].append(row);out.write_text(json.dumps(report,indent=2));print(json.dumps(row),flush=True)
 print('DONE',out,flush=True)
if __name__=='__main__':main()
