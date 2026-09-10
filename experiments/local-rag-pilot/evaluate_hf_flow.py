"""Frozen fictional HF adapter evaluation. No user sources or external inference."""
import os,json,time,signal,hashlib,platform,argparse
from pathlib import Path
ROOT=Path(__file__).resolve().parent
for key,value in {'HF_HOME':str(ROOT/'.cache/huggingface'),'HF_HUB_OFFLINE':'1','TRANSFORMERS_OFFLINE':'1','HF_HUB_DISABLE_TELEMETRY':'1','TOKENIZERS_PARALLELISM':'false','HF_DEACTIVATE_ASYNC_LOAD':'1'}.items():os.environ[key]=value

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--repeats',type=int,default=2);args=parser.parse_args()
    from backends import GraniteAdapters
    from granite_switch_backend import SwitchIntrinsics,GraniteSwitchPipeline
    from pipeline import LocalSearch,Document
    fixture_path=ROOT/'hf_flow_cases.json';fixture=json.loads(fixture_path.read_text())
    out=ROOT/'results/hf-flow-evaluation.json'
    report={'fixture_sha256':hashlib.sha256(fixture_path.read_bytes()).hexdigest(),'backend':'Granite 4.1 3B + individual HF adapters (not composed Switch)','platform':platform.machine(),'scope':fixture['scope'],'repeats':args.repeats,'cases':[]}
    print('Loading offline HF model',flush=True);start=time.monotonic()
    local=GraniteAdapters();ops=SwitchIntrinsics.__new__(SwitchIntrinsics);ops.backend=local.backend
    engine=GraniteSwitchPipeline(LocalSearch(),ops);engine.mode='granite-hf-notebook-flow'
    report['load_seconds']=round(time.monotonic()-start,2)
    def timeout(*_):raise TimeoutError('Case exceeded 180 seconds')
    signal.signal(signal.SIGALRM,timeout)
    for repeat in range(args.repeats):
        for case in fixture['cases']:
            print('START',repeat+1,case['id'],flush=True);start=time.monotonic();signal.alarm(180)
            entry={'id':case['id'],'category':case['category'],'repeat':repeat+1,'question':case['question'],'expected':case['expected'],'rubric':case['rubric']}
            try:
                result=engine.ask(case['question'],[Document(**d) for d in fixture['documents']],history=case.get('history',[]),scope=fixture['scope'])
                text=result.get('answer','').lower()
                entry.update(result=result,status_pass=result['status'] in case['expected'],keyword_screen=all(any(x in text for x in group) for group in case.get('keywords',[])))
            except Exception as error:entry.update(error=type(error).__name__+': '+str(error)[:1000],status_pass=False,keyword_screen=False)
            finally:signal.alarm(0)
            entry['seconds']=round(time.monotonic()-start,2);report['cases'].append(entry)
            out.write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in entry.items() if k not in ['result','rubric']}),flush=True)
    print('Saved',out,flush=True)

if __name__=='__main__':main()
