import unittest
from runtime import WarmRuntime


def fake_worker(conn, mode):
    conn.send({'type':'ready'})
    while True:
        job = conn.recv()
        if job.get('crash'): return
        if job.get('hang'):
            import time
            time.sleep(5)
        conn.send({'type':'stage','stage':'retrieval'})
        conn.send({'type':'result','result':{'question':job.get('question')}})


def loading_worker(conn, mode):
    import time
    time.sleep(5)


class RuntimeTests(unittest.TestCase):
    def test_large_request_cannot_block_startup_timeout(self):
        r=WarmRuntime(target=loading_worker,timeout=.3)
        try:
            with self.assertRaises(TimeoutError):
                r.ask({'mode':'test','question':'x'*200000})
        finally:r.close()

    def test_reuses_process_and_can_release(self):
        r=WarmRuntime(target=fake_worker,timeout=3)
        try:
            stages=[]
            a=r.ask({'mode':'test','question':'one'},progress=stages.append)
            self.assertEqual(stages,['Loading model','retrieval'])
            pid=r.process.pid
            b=r.ask({'mode':'test','question':'two'})
            self.assertEqual(r.process.pid,pid)
            self.assertFalse(a['runtime']['warm'])
            self.assertTrue(b['runtime']['warm'])
            self.assertEqual(b['question'],'two')
            r.close()
            self.assertIsNone(r.process)
        finally:r.close()

    def test_backend_switch_restarts_worker(self):
        r=WarmRuntime(target=fake_worker,timeout=3)
        try:
            r.ask({'mode':'first','question':'one'})
            pid=r.process.pid
            result=r.ask({'mode':'second','question':'two'})
            self.assertNotEqual(r.process.pid,pid)
            self.assertFalse(result['runtime']['warm'])
        finally:r.close()

    def test_timeout_and_crash_allow_next_request(self):
        r=WarmRuntime(target=fake_worker,timeout=.5)
        try:
            with self.assertRaises(TimeoutError):r.ask({'mode':'test','hang':True})
            self.assertIsNone(r.process)
            with self.assertRaises(RuntimeError):r.ask({'mode':'test','crash':True})
            self.assertEqual(r.ask({'mode':'test','question':'recovered'})['question'],'recovered')
        finally:r.close()
