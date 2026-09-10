"""Exercise the live server with fictional data; save a reviewable result."""
import json
import sys
from pathlib import Path
from urllib.request import Request,build_opener,ProxyHandler
opener=build_opener(ProxyHandler({}))
url='http://127.0.0.1:4390'
with opener.open(url+'/api/status') as r:status=json.load(r)
mode=sys.argv[1] if len(sys.argv)>1 else 'ollama-baseline'
question=sys.argv[2] if len(sys.argv)>2 else 'What should I do if a conversion job failed after writing part of its output?'
req=Request(url+'/api/ask',data=json.dumps({'mode':mode,'question':question,'documents':status['sample']}).encode(),headers={'Content-Type':'application/json','X-Pilot-Token':status['token']})
try:
    with opener.open(req,timeout=900) as r:result=json.load(r)
except Exception as e:
    if hasattr(e,'read'):print(e.read().decode())
    raise
out=Path(__file__).parent/'.cache'/('smoke-'+mode+'.json')
out.write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
