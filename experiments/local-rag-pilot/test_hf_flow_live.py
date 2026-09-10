"""Opt-in live adapter experiment; uses fictional material only.
Run directly, not unittest discovery. Writes stage timings and outcomes to results/.
"""
import os
import json
import time
from pathlib import Path
ROOT=Path(__file__).resolve().parent
os.environ['HF_HOME']=str(ROOT/'.cache/huggingface')
os.environ['HF_HUB_OFFLINE']='1'
os.environ['TRANSFORMERS_OFFLINE']='1'
os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
os.environ['TOKENIZERS_PARALLELISM']='false'
os.environ['HF_DEACTIVATE_ASYNC_LOAD']='1'


def run():
    import signal
    from backends import GraniteAdapters
    from granite_switch_backend import SwitchIntrinsics,GraniteSwitchPipeline
    from pipeline import Document,LocalSearch
    records=[]
    output=ROOT/'results/hf-notebook-flow-live.json'
    output.parent.mkdir(exist_ok=True)
    def save(): output.write_text(json.dumps(records,indent=2))
    def timeout(*args): raise TimeoutError('Adapter exceeded 180 seconds.')
    signal.signal(signal.SIGALRM,timeout)
    started=time.monotonic()
    print('Loading Granite 4.1 3B on Apple Silicon',flush=True)
    local=GraniteAdapters()
    print('Model loaded in',round(time.monotonic()-started,2),'seconds',flush=True)
    ops=SwitchIntrinsics.__new__(SwitchIntrinsics)
    ops.backend=local.backend
    docs=[Document(id='handoff',title='Fictional conversion service runbook',text='The conversion service converts documents and writes output to storage. If a job fails after a partial write, escalate to the service owner. Do not retry until the owner confirms that another attempt will not duplicate output. Record the job identifier when escalating. The runbook does not specify pricing or a universal retry count.')]
    ctx=ops.context([])
    question='What should I do if a conversion job fails after writing some output?'
    calls=[
      ('guardian_harm',lambda:ops.guardian(question,ctx,'harm')),
      ('guardian_scope',lambda:ops.guardian(question,ctx,'The message concerns operating or troubleshooting a document conversion service.')),
      ('rewrite',lambda:ops.rewrite(question,ctx)),
      ('answerability',lambda:ops.answerable(question,docs,ctx)),
      ('clarification_clear',lambda:ops.clarify(question,docs,ctx)),
      ('clarification_ambiguous',lambda:ops.clarify('Should I do it again?',docs,ctx)),
      ('generation',lambda:ops.generate(question,docs,ctx)),
    ]
    answer=None
    for name,fn in calls:
        print('START',name,flush=True); begin=time.monotonic(); signal.alarm(180)
        try:
            value=fn(); row={'stage':name,'seconds':round(time.monotonic()-begin,2),'result':value}
            if name=='generation': answer=value
        except Exception as e: row={'stage':name,'seconds':round(time.monotonic()-begin,2),'error':type(e).__name__+': '+str(e)[:700]}
        finally: signal.alarm(0)
        records.append(row); save(); print(json.dumps(row),flush=True)
    if answer:
        print('START citations',flush=True); begin=time.monotonic(); signal.alarm(180)
        try: row={'stage':'citations','seconds':0,'result':ops.citations(answer,question,docs,ctx)}
        except Exception as e: row={'stage':'citations','error':type(e).__name__+': '+str(e)[:700]}
        finally:signal.alarm(0)
        row['seconds']=round(time.monotonic()-begin,2);records.append(row);save();print(json.dumps(row),flush=True)
    history=[{'role':'user','content':question},{'role':'assistant','content':'Escalate the partial write to the service owner before retrying.'}]
    print('START followup_rewrite',flush=True);begin=time.monotonic();signal.alarm(180)
    try: row={'stage':'followup_rewrite','result':ops.rewrite('What should I record when I do that?',ops.context(history))}
    except Exception as e:row={'stage':'followup_rewrite','error':type(e).__name__+': '+str(e)[:700]}
    finally:signal.alarm(0)
    row['seconds']=round(time.monotonic()-begin,2);records.append(row);save();print(json.dumps(row),flush=True)

    search=LocalSearch()
    engine=GraniteSwitchPipeline(search,ops)
    engine.mode="granite-hf-notebook-flow"
    second=Document(id='second',title='Fictional onboarding handoff',text='The onboarding handoff goes to the account manager. Send the signed checklist. The conversion handoff goes to the service owner with the job identifier.')
    scenarios=[('full_answer',question,docs,[]),
               ('full_followup','What should I record when I do that?',docs,history),
               ('full_missing_evidence','How much does each conversion cost?',docs,[]),
               ('full_ambiguous','Who should get the handoff?',docs+[second],[])]
    for name,q,corpus,turns in scenarios:
        print('START',name,flush=True);begin=time.monotonic();signal.alarm(180)
        try:
            result=engine.ask(q,corpus,history=turns,scope='Operating a conversion service and handing work to its owner or onboarding account manager.',progress=lambda stage:print('FLOW',name,stage,flush=True))
            row={'stage':name,'result':result}
        except Exception as e:row={'stage':name,'error':type(e).__name__+': '+str(e)[:700]}
        finally:signal.alarm(0)
        row['seconds']=round(time.monotonic()-begin,2);records.append(row);save();print(json.dumps(row),flush=True)

if __name__=='__main__':run()
