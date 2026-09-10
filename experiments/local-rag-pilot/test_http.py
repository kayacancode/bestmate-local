import io
import json
import subprocess
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import server


class HTTPTests(unittest.TestCase):
    def request(self, origin='http://127.0.0.1:4390', token=server.TOKEN):
        h=server.Handler.__new__(server.Handler)
        body=json.dumps({'mode':'granite-hf-adapters','question':'Can I retry?','documents':server.SAMPLE}).encode()
        h.server=SimpleNamespace(server_port=4390)
        h.path='/api/ask'
        h.headers={'Host':'127.0.0.1:4390','Origin':origin,'X-Pilot-Token':token,'Content-Length':str(len(body))}
        h.rfile=io.BytesIO(body)
        h.results=[]
        h.send=lambda status,data:h.results.append((status,data))
        return h

    def test_progress_is_authorized_and_scoped_to_request(self):
        with patch.object(server, 'PROGRESS', {'request_id':'mine','events':[{'stage':'retrieval','seconds':1.2}]}):
            for token, request_id, expected, count in [(server.TOKEN,'mine',200,1),(server.TOKEN,'other',200,0),('', 'mine',403,0)]:
                h=self.request(token=token); h.path='/api/progress'
                h.headers['X-Request-ID']=request_id
                h.do_GET()
                status, body=h.results[0]
                self.assertEqual(status,expected)
                self.assertEqual(len(body.get('events',[])),count)

    def test_progress_reports_real_runtime_callback(self):
        h=self.request(); h.headers['X-Request-ID']='new-question'
        def run(data,progress):
            progress('retrieval'); progress('generation')
            return {'status':'answered'}
        with patch.object(server.RUNTIME,'ask',side_effect=run): h.do_POST()
        self.assertEqual(h.results[0][0],200)
        self.assertEqual(server.PROGRESS['request_id'],'new-question')
        self.assertEqual([e['stage'] for e in server.PROGRESS['events']],['retrieval','generation'])
        self.assertTrue(all(e['seconds']>=0 for e in server.PROGRESS['events']))

    def test_foreign_origin_and_missing_token_do_not_run_inference(self):
        for h in [self.request(origin='https://example.com'),self.request(token='')]:
            with patch.object(server.RUNTIME,'ask') as run:
                h.do_POST()
                self.assertEqual(h.results[0][0],403)
                run.assert_not_called()

    def test_unload_requires_same_local_authorization(self):
        h=self.request(token='')
        h.path='/api/unload'
        with patch.object(server.RUNTIME,'close') as close:
            h.do_POST()
            self.assertEqual(h.results[0][0],403)
            close.assert_not_called()
        h=self.request()
        h.path='/api/unload'
        with patch.object(server.RUNTIME,'close') as close:
            h.do_POST()
            self.assertEqual(h.results[0],(200,{'released':True}))
            close.assert_called_once()

    def test_timeout_releases_request_lock_and_returns_no_answer(self):
        h=self.request()
        def timeout(data,progress):
            progress('grounding check')
            raise TimeoutError('worker')
        with patch.object(server.RUNTIME,'ask',side_effect=timeout):
            h.do_POST()
        self.assertEqual(h.results[0][0],504)
        self.assertIn('Last reported step: grounding check',h.results[0][1]['error'])
        self.assertNotIn('answer',h.results[0][1])
        self.assertTrue(server.LOCK.acquire(blocking=False))
        server.LOCK.release()

    def test_native_context_reserves_capacity_for_approved_judgments(self):
        # A full 30-source workspace must still be able to supply approved decisions.
        docs=[{'id':f'doc{i}','title':f'Source {i}','text':'Fictional evidence.'} for i in range(40)]
        for path,expected in [('/api/ask',400),('/api/workspace/ask',200)]:
            h=self.request()
            h.path=path
            body=json.dumps({'mode':'granite-hf-adapters','question':'Can I retry?',
                             'documents':docs,'workspace_context':True}).encode()
            h.headers['Content-Length']=str(len(body)); h.rfile=io.BytesIO(body)
            with patch.object(server.RUNTIME,'ask',return_value={'status':'answered'}) as run:
                h.do_POST()
                self.assertEqual(h.results[0][0],expected)
                if expected==200:
                    self.assertTrue(run.call_args.args[0]['workspace_context'])
                    self.assertEqual(len(run.call_args.args[0]['documents']),40)
                else:run.assert_not_called()

if __name__=='__main__':unittest.main()
