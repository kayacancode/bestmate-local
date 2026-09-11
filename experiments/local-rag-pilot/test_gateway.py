import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from gateway import GatewayBackend, KeywordSearch, validate_gateway
from pipeline import Document, Pipeline, CheckUnavailable

class GatewayTests(unittest.TestCase):
    def test_url_validation(self):
        for url in ['http://example.com/v1', 'https://user:pass@example.com/v1', 'https://example.com/v1?key=x', 'file:///tmp/model']:
            with self.assertRaises(ValueError): validate_gateway({'url':url,'model':'test'})
        self.assertEqual(validate_gateway({'url':'https://example.com/prefix/v1/','model':'test'})['url'],'https://example.com/prefix/v1')

    def test_retrieval_returns_only_supplied_evidence(self):
        docs=[Document('allowed','Runbook','Transport failures may be retried. '*250)]
        results=KeywordSearch().search('transport failures',docs)
        self.assertTrue(results)
        self.assertTrue(all(x.id=='allowed' and len(x.text.split())<=180 for x in results))
        self.assertEqual(KeywordSearch().search('unrelated astronomy',docs),[])

    def test_endpoint_contract_and_pipeline(self):
        requests=[]
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append((self.path,self.headers.get('Authorization'),body))
                if self.path.startswith('/redirect/'):
                    self.send_response(302); self.send_header('Location','/v1/chat/completions'); self.end_headers(); return
                if self.path.startswith('/denied/'):
                    self.send_response(401); self.end_headers(); self.wfile.write(b'private diagnostic test-only'); return
                prompt=body['messages'][-1]['content']
                content='{"answerable":true}' if '"answerable"' in prompt else '{"supported":true,"issues":[]}' if '"supported"' in prompt else 'Record the job identifier. [allowed]'
                data=json.dumps({'choices':[{'message':{'content':content}}]}).encode()
                self.send_response(200);self.end_headers();self.wfile.write(data)
            def log_message(self,*args): pass
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            backend=GatewayBackend({'url':f'http://127.0.0.1:{server.server_port}/v1','model':'organization/model','key':'test-only'})
            result=Pipeline(KeywordSearch(),backend).ask('What job identifier should I record?',[Document('allowed','Runbook','Record the job identifier when escalating failures.')])
            self.assertEqual(result['status'],'answered')
            self.assertEqual(len(requests),3)
            from runtime import WarmRuntime
            runtime=WarmRuntime(timeout=15)
            try:
                result=runtime.ask({'mode':'openai-compatible','gateway':backend.config,'question':'What job identifier should I record?',
                    'documents':[{'id':'allowed','title':'Runbook','text':'Record the job identifier when escalating failures.'}]})
                self.assertEqual(result['status'],'answered')
            finally:runtime.close()

            for path,auth,body in requests:
                self.assertEqual(path,'/v1/chat/completions');self.assertEqual(auth,'Bearer test-only')
                self.assertEqual(body['model'],'organization/model');self.assertFalse(body['stream'])
            count=len(requests)
            for prefix,code in [('redirect',302),('denied',401)]:
                other=GatewayBackend({'url':f'http://127.0.0.1:{server.server_port}/{prefix}','model':'test','key':'test-only'})
                with self.assertRaises(ValueError) as caught: other.text('test')
                self.assertIn(str(code),str(caught.exception))
                self.assertNotIn('test-only',str(caught.exception))
            self.assertEqual(len(requests),count+2)  # Redirect was not followed.
            backend.text=lambda *a,**kw:'not JSON'
            with self.assertRaises(CheckUnavailable): backend.check('q','a',[])
        finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__': unittest.main()
