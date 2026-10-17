"""Owned authenticated protocol peer; queued writes never change destination."""
import json
import os
import pathlib
import queue
import select
import subprocess
import threading
import time
from urllib.parse import urlsplit
from private_files import read_private_json

MAX_LINE=16*1024*1024

def validate_provenance(directory,endpoint,thread_id):
    u=urlsplit(endpoint)
    if u.scheme!='ws' or u.hostname!='127.0.0.1' or not u.port or u.username is not None or u.password is not None or u.path or u.query or u.fragment:
        raise ValueError('literal loopback endpoint required')
    p=read_private_json(directory)
    if not isinstance(p,dict) or p.get('endpoint')!=endpoint or p.get('thread_id')!=thread_id or type(p.get('server_pid')) is not int or p['server_pid']<=0:
        raise ValueError('managed provenance mismatch')
    project=pathlib.Path(p.get('project','')).resolve()
    if project != pathlib.Path(directory).resolve()/'project':
        raise ValueError('private project mismatch')
    os.kill(p['server_pid'],0)
    return p

class ProxyConnection:
    def __init__(self,endpoint,token_path,generation):
        self.generation=generation;self.closed=False;self.buffer=b'';self.inbox=[];self.counter=0
        self.queue=queue.Queue(maxsize=8);self.write_lock=threading.Lock()
        self.p=subprocess.Popen(['node',str(pathlib.Path(__file__).with_name('ws_peer.mjs')),endpoint,str(token_path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,bufsize=0)
        os.set_blocking(self.p.stdin.fileno(),False)
        self.writer=threading.Thread(target=self._writer,daemon=True);self.writer.start()

    def write(self,generation,message):
        if self.closed or generation!=self.generation:
            raise OSError('stale transport')
        line=(json.dumps(message,ensure_ascii=False,separators=(',',':'))+'\n').encode()
        if len(line)>65536:raise ValueError('outgoing line limit')
        done=threading.Event();envelope={'generation':generation,'line':line,'done':done,'error':None}
        try:self.queue.put(envelope,timeout=1)
        except queue.Full:raise TimeoutError('writer queue full')
        if not done.wait(6):self.close();raise TimeoutError('writer deadline')
        if envelope['error']:raise OSError('writer stopped')

    def _writer(self):
        while not self.closed:
            try:e=self.queue.get(timeout=0.2)
            except queue.Empty:continue
            try:
                end=time.monotonic()+4;offset=0
                while offset<len(e['line']):
                    if self.closed or e['generation']!=self.generation:raise OSError('stale transport')
                    left=end-time.monotonic()
                    if left<=0:raise TimeoutError('pipe deadline')
                    if not select.select([],[self.p.stdin],[],min(left,.2))[1]:continue
                    try:offset+=os.write(self.p.stdin.fileno(),e['line'][offset:])
                    except BlockingIOError:continue
            except (OSError,ValueError,TimeoutError):
                e['error']=True
                # A partial JSON line poisons the stream: retire this exact peer.
                self.closed=True
            finally:e['done'].set()
        while True:
            try:e=self.queue.get_nowait();e['error']=True;e['done'].set()
            except queue.Empty:break

    def read(self,timeout=None):
        if self.inbox:return self.inbox.pop(0)
        end=time.monotonic()+timeout if timeout is not None else None
        while b'\n' not in self.buffer:
            if self.closed:raise EOFError()
            wait=.5 if end is None else min(.5,max(0,end-time.monotonic()))
            if not select.select([self.p.stdout],[],[],wait)[0]:
                if end is not None and time.monotonic()>=end:raise TimeoutError('RPC deadline')
                continue
            chunk=os.read(self.p.stdout.fileno(),65536)
            if not chunk:raise EOFError()
            self.buffer+=chunk
            if len(self.buffer)>MAX_LINE:raise ValueError('incoming line limit')
        line,self.buffer=self.buffer.split(b'\n',1)
        if len(line)>MAX_LINE:raise ValueError('incoming line limit')
        message=json.loads(line)
        if not isinstance(message,dict):raise ValueError('message object required')
        return message

    def call(self,method,params):
        self.counter+=1;rid='bridge-'+str(self.counter)
        self.write(self.generation,{'id':rid,'method':method,'params':params})
        saved=[];end=time.monotonic()+30
        try:
            while True:
                m=self.read(max(0,end-time.monotonic()))
                if m.get('id')==rid and 'method' not in m:
                    if 'error' in m:raise RuntimeError('upstream RPC error')
                    return m['result']
                saved.append(m)
                if len(saved)>128:raise ValueError('startup event limit')
        finally:self.inbox=saved+self.inbox

    def close(self):
        self.closed=True
        if getattr(self,'p',None):
            try:self.p.stdin.close()
            except OSError:pass
            try:self.p.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.p.terminate()
                try:self.p.wait(timeout=2)
                except subprocess.TimeoutExpired:self.p.kill();self.p.wait(timeout=2)
        if getattr(self,'writer',None) and self.writer is not threading.current_thread():self.writer.join(timeout=1)

class BridgeTransport:
    def __init__(self,state,directory,endpoint,thread_id):
        self.provenance=validate_provenance(directory,endpoint,thread_id)
        self.state=state;self.directory=pathlib.Path(directory).resolve();self.endpoint=endpoint
        self.lock=threading.Lock();self.current=None;self.stopped=threading.Event()
        self.worker=threading.Thread(target=self._run,daemon=True)

    def start(self):self.worker.start()
    def _run(self):
        backoff=1
        while not self.stopped.is_set():
            generation=self.state.begin();conn=None
            try:
                validate_provenance(self.directory,self.endpoint,self.state.thread_id)
                conn=ProxyConnection(self.endpoint,self.directory/'upstream-token',generation)
                with self.lock:self.current=conn
                conn.call('initialize',{'clientInfo':{'name':'awesomux_companion_bridge','version':'0.1'},'capabilities':{'experimentalApi':True}})
                conn.write(generation,{'method':'initialized'})
                read=conn.call('thread/read',{'threadId':self.state.thread_id,'includeTurns':False})
                if pathlib.Path(read['thread']['cwd']).resolve()!=pathlib.Path(self.provenance['project']):raise ValueError('thread project mismatch')
                resumed=conn.call('thread/resume',{'threadId':self.state.thread_id})
                self.state.hydrate(generation,resumed['thread']);backoff=1
                while not self.stopped.is_set():self.state.apply(generation,conn.read())
            except (OSError,EOFError,TimeoutError,ValueError,RuntimeError,KeyError):
                self.state.disconnect(generation)
            finally:
                with self.lock:
                    if self.current is conn:self.current=None
                if conn:conn.close()
            self.stopped.wait(backoff);backoff=min(8,backoff*2)

    def answer(self,control,operation,answers,confirm_uncertain=False):
        with self.lock:conn=self.current
        if not conn:return 'disconnected'
        return self.state.answer(control,operation,answers,lambda message:conn.write(conn.generation,message),confirm_uncertain=confirm_uncertain,expected_generation=conn.generation)

    def close(self):
        self.stopped.set()
        with self.lock:conn=self.current
        if conn:conn.close();self.state.disconnect(conn.generation)
        self.worker.join(timeout=5)
