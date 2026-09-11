"""Loopback-only experimental service. No hosted model fallback or document persistence."""
import os
from pathlib import Path
ROOT=Path(__file__).resolve().parent
os.environ['HF_HOME']=str(ROOT/'.cache/huggingface')
os.environ['HF_HUB_OFFLINE']='1'
os.environ['TRANSFORMERS_OFFLINE']='1'
os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
os.environ['TOKENIZERS_PARALLELISM']='false'
os.environ['DO_NOT_TRACK']='1'
import argparse
import json
import secrets
import threading
import time
import atexit
from runtime import WarmRuntime
import sys
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.request import build_opener,ProxyHandler
from pipeline import validate_documents

TOKEN=secrets.token_urlsafe(32)
LOCK=threading.Lock()
PROGRESS={"request_id":None,"events":[]}
RUNTIME=WarmRuntime()
atexit.register(RUNTIME.close)
SAMPLE=[{'id':'runbook','title':'Service runbook · fictional','text':'Transient transport failures may be retried after confirming that no output was written. Schema mismatches require investigation before repeating the job. A failure after a partial write must be escalated to the service owner because another attempt can duplicate work. The runbook does not specify a universal retry count.'},
        {'id':'architecture','title':'Conversion architecture · fictional','text':'The conversion service validates the input schema, converts the document, and writes output to storage. Each job has a unique job identifier. Record this identifier when escalating failures.'},
        {'id':'judgment','title':'Example owner judgment · fictional','text':'For this sample document conversion project only, the owner would ask the developer to check for partial writes before deciding on a retry. If repeatability is uncertain, ask the owner. This fictional decision does not authorize a deployment.'}]

def readiness():
    manifest=ROOT/'.cache/models.json'
    files=json.loads(manifest.read_text()) if manifest.exists() else {}
    local=False
    try:
        opener=build_opener(ProxyHandler({}))
        with opener.open('http://127.0.0.1:11434/api/tags',timeout=2) as r:
            local=any(m['name']=='llama3.1:latest' and not m.get('remote_host') for m in json.load(r)['models'])
    except Exception: pass
    from granite_switch_backend import probe
    switch_ready, switch_message = probe()
    return {'switch_ready':switch_ready,'switch_message':switch_message,'embedding_ready':'sentence-transformers/all-MiniLM-L6-v2' in files,
            'ollama_ready':local,'adapters_cached':all(k in files for k in ['ibm-granite/granite-4.1-3b','ibm-granite/granitelib-rag-r1.0']),
            'models':{k:v['revision'] for k,v in files.items()},'worker_stage':RUNTIME.stage,'worker_mode':RUNTIME.mode}


class Handler(BaseHTTPRequestHandler):
    def allowed_host(self): return self.headers.get('Host')==f'127.0.0.1:{self.server.server_port}'
    def send(self,status,data,mime='application/json'):
        payload=json.dumps(data).encode() if mime=='application/json' else data
        self.send_response(status)
        self.send_header('Content-Type',mime)
        self.send_header('Content-Length',str(len(payload)))
        self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        self.wfile.write(payload)
    def do_GET(self):
        if not self.allowed_host(): return self.send(403,{'error':'Use the 127.0.0.1 URL printed by the server.'})
        if self.path=='/api/progress':
            origin=self.headers.get('Origin')
            if self.headers.get('X-Pilot-Token')!=TOKEN or (origin and origin!=f'http://127.0.0.1:{self.server.server_port}'):
                return self.send(403,{'error':'Local authorization required.'})
            snapshot=PROGRESS
            return self.send(200,{'events':snapshot['events'] if self.headers.get('X-Request-ID')==snapshot['request_id'] else []})
        if self.path=='/api/status': return self.send(200,{**readiness(),'token':TOKEN,'sample':SAMPLE,'workspace_api':True,'progress_api':True})
        routes={'/':('index.html','text/html; charset=utf-8'),'/app.js':('app.js','text/javascript; charset=utf-8'),'/style.css':('style.css','text/css; charset=utf-8')}
        if self.path not in routes:return self.send(404,{'error':'Not found'})
        name,mime=routes[self.path]
        self.send(200,(ROOT/name).read_bytes(),mime)
    def do_POST(self):
        origin=self.headers.get('Origin')
        if not self.allowed_host() or self.headers.get('X-Pilot-Token')!=TOKEN or (origin and origin!=f'http://127.0.0.1:{self.server.server_port}'):
            return self.send(403,{'error':'Request must originate from the local pilot page.'})
        if self.path not in ('/api/ask','/api/workspace/ask','/api/workspace/subjects','/api/model/check','/api/unload'): return self.send(404,{'error':'Not found'})
        try: size=int(self.headers.get('Content-Length','0'))
        except ValueError:return self.send(400,{'error':'Invalid body size'})
        if size<=0 or size>1000000:return self.send(413,{'error':'Body too large or empty'})
        if not LOCK.acquire(blocking=False):return self.send(409,{'error':'Another local request is running. Please wait.'})
        try:
            data=json.loads(self.rfile.read(size))
            if not isinstance(data,dict):raise ValueError('Expected a JSON object.')
            if self.path=='/api/model/check':
                from gateway import GatewayBackend
                GatewayBackend(data.get('gateway')).text('Reply with OK. This is a connection test; no workspace documents are included.')
                return self.send(200,{'ready':True})
            if self.path=='/api/unload':
                RUNTIME.close()
                return self.send(200,{'released':True})
            if data.get('answer_style','standard') not in ('brief','standard'):raise ValueError('Choose brief or standard answers.')
            data['workspace_context']=self.path in ('/api/workspace/ask','/api/workspace/subjects')
            data['task']='subjects' if self.path=='/api/workspace/subjects' else 'ask'
            docs=validate_documents(data.get('documents'),max_documents=60 if data['workspace_context'] else 30,
                                    max_characters=300000 if data['workspace_context'] else 200000)
            question=data.get('question')
            if not isinstance(question,str) or not question.strip() or len(question)>2000:raise ValueError('Enter a question under 2,000 characters.')
            mode=data.get('mode')
            if mode not in ('ollama-baseline','granite-hf-adapters','granite-switch','openai-compatible'):raise ValueError('Select a supported backend.')
            if mode=='openai-compatible':
                from gateway import validate_gateway
                data['gateway']=validate_gateway(data.get('gateway'))
            if mode=='ollama-baseline' and not readiness()['ollama_ready']:raise ValueError('Start Ollama with the installed llama3.1:latest model. No cloud fallback is used.')
            if mode == 'granite-switch':
                from granite_switch_backend import validate_history, probe
                validate_history(data.get('history', []))
                ready, message = probe()
                if not ready: raise ValueError(message)
            request_id=self.headers.get('X-Request-ID','')[:100]
            started=time.monotonic()
            def report(stage):
                global PROGRESS
                event={'stage':stage,'seconds':round(time.monotonic()-started,2)}
                previous=PROGRESS['events'] if PROGRESS['request_id']==request_id else []
                PROGRESS={'request_id':request_id,'events':(previous+[event])[-24:]}
            global PROGRESS
            PROGRESS={'request_id':request_id,'events':[]}
            self.send(200,RUNTIME.ask(data,progress=report))
        except TimeoutError:
            last=PROGRESS['events'][-1]['stage'] if PROGRESS['events'] else 'preparing the request'
            if data.get('mode') == 'granite-switch':
                return self.send(504,{'error':f'The Granite Switch request exceeded four minutes and the adapter worker was stopped. Last step: {last}. The GPU server remains running. No fallback was used.'})
            if data.get('mode') == 'openai-compatible':
                return self.send(504,{'error':f'The model endpoint pipeline exceeded four minutes. Last step: {last}. No fallback was used.'})
            self.send(504,{'error':f'The model exceeded four minutes and was unloaded. Last reported step: {last}. You can retry with a narrower question. No fallback was used.'})
        except (ValueError,KeyError,TypeError) as e:self.send(400,{'error':str(e)})
        except Exception as e:
            import traceback
            traceback.print_exc()
            self.send(503,{'error':f'{type(e).__name__}: Local pipeline unavailable. No fallback was used. See the terminal for details.'})
        finally:LOCK.release()
    def log_message(self,fmt,*args):pass

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=4390);args=p.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    print(f'Bestmate local RAG pilot: http://127.0.0.1:{args.port}',flush=True)
    server.serve_forever()
