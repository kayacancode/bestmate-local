"""Single warm inference process; restarting it drops model and document memory."""
import multiprocessing as mp
import time


class WarmRuntime:
    def __init__(self,target=None,timeout=240):
        if target is None:
            from worker import serve
            target=serve
        self.target,self.timeout=target,timeout
        self.process=self.conn=self.mode=None
        self.stage='Not loaded'

    def close(self):
        if self.process is not None:
            if self.process.is_alive():
                self.process.terminate()
                self.process.join(3)
                if self.process.is_alive():self.process.kill();self.process.join(3)
            else:self.process.join()
        if self.conn is not None:self.conn.close()
        self.process=self.conn=self.mode=None
        self.stage='Not loaded'

    def ask(self,data,progress=None):
        def report(stage):
            self.stage=stage
            if progress: progress(stage)
        start=time.monotonic()
        warm=self.process is not None and self.process.is_alive() and self.mode==data['mode']
        if not warm:
            self.close()
            ctx=mp.get_context('spawn')
            self.conn,child=ctx.Pipe()
            self.mode=data['mode']
            self.process=ctx.Process(target=self.target,args=(child,self.mode),daemon=True)
            report('Loading model')
            self.process.start()
            child.close()
        try:
            if warm:
                report('Preparing request')
                self.conn.send(data)
            while True:
                remaining=self.timeout-(time.monotonic()-start)
                if remaining<=0 or not self.conn.poll(remaining):raise TimeoutError('Local inference exceeded four minutes.')
                msg=self.conn.recv()
                if msg['type']=='ready':
                    self.conn.send(data)
                    continue
                if msg['type']=='stage':report(msg['stage']);continue
                if msg['type']=='error':raise RuntimeError(msg['error'])
                if msg['type']=='result':
                    self.stage='Ready · model in memory'
                    return {**msg['result'],'runtime':{'warm':warm,'total_seconds':round(time.monotonic()-start,2)}}
        except TimeoutError:
            self.close()
            raise
        except (EOFError,BrokenPipeError,OSError) as e:
            self.close()
            raise RuntimeError('Local model worker stopped. Retry to start a fresh worker.') from e
        except Exception:
            self.close()
            raise
