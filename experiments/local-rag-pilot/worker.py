"""Reusable model process. Each question has a new chat context; sources stay in RAM."""
import os
os.environ['HF_DEACTIVATE_ASYNC_LOAD']='1'
from pathlib import Path
ROOT=Path(__file__).resolve().parent
os.environ['HF_HOME']=str(ROOT/'.cache/huggingface')
os.environ['HF_HUB_OFFLINE']='1'
os.environ['TRANSFORMERS_OFFLINE']='1'
os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
os.environ['TOKENIZERS_PARALLELISM']='false'
os.environ['DO_NOT_TRACK']='1'


def serve(conn,mode):
    import faulthandler
    import traceback
    faulthandler.enable()
    try:
        from pipeline import LocalSearch,Pipeline,validate_documents
        from backends import GraniteAdapters,OllamaBaseline
        conn.send({'type':'stage','stage':'Preparing endpoint pipeline' if mode == 'openai-compatible' else 'Loading model and local search'})
        if mode == 'openai-compatible':
            backend = engine = None
        elif mode == 'granite-switch':
            from granite_switch_backend import GraniteSwitchPipeline
            backend = None
            engine = GraniteSwitchPipeline(LocalSearch())
        else:
            backend=GraniteAdapters() if mode=='granite-hf-adapters' else OllamaBaseline()
            engine=Pipeline(LocalSearch(),backend)
        conn.send({'type':'ready'})
        while True:
            job=conn.recv()
            if mode == 'openai-compatible':
                from gateway import GatewayBackend, KeywordSearch
                backend=GatewayBackend(job.get('gateway'))
                engine=Pipeline(KeywordSearch(),backend)
            if backend is not None: backend.answer_style=job.get('answer_style','standard')
            faulthandler.dump_traceback_later(180)
            try:
                if job.get('task')=='subjects':
                    from backends import suggest_subjects
                    import json
                    conn.send({'type':'stage','stage':'subject suggestions'})
                    try:
                        if backend is None: raise ValueError('Switch subjects are not implemented.')
                        labels=suggest_subjects(backend,validate_documents(job['documents']))
                        result={'status':'answered','answer':json.dumps(labels),'sources':[]}
                    except (ValueError,TypeError):
                        result={'status':'needs_context','answer':'Subject suggestions could not be generated. You can save without them.','sources':[]}
                    conn.send({'type':'result','result':result})
                    continue
                result=engine.ask(job['question'],validate_documents(job['documents'],
                                  max_documents=60 if job.get('workspace_context') else 30,
                                  max_characters=300000 if job.get('workspace_context') else 200000),
                                  progress=lambda stage:conn.send({'type':'stage','stage':stage.replace('_',' ')}),
                                  **({'history':job.get('history',[]),'scope':job.get('scope','')} if mode=='granite-switch' else {}))
                conn.send({'type':'result','result':result})
            finally:
                faulthandler.cancel_dump_traceback_later()
                if mode == 'openai-compatible':
                    backend = engine = None
                    job.pop('gateway',None)
    except EOFError:pass
    except Exception as e:
        traceback.print_exc()
        conn.send({'type':'error','error':f'{type(e).__name__}: Local model failed. No fallback used.'})
    finally:conn.close()
