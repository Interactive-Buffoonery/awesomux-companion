"""Two independent watchers for an owned foreground child; private inherited pipes."""
import ctypes
import json
import os
import pathlib
import select
import signal
import subprocess
import sys
import threading
import time

class WatchdogFailure(RuntimeError):pass

class BSDInfo(ctypes.Structure):
    # Apple proc_bsdinfo layout, PROC_PIDTBSDINFO=3, sizeof=136.
    _fields_=[('words',ctypes.c_uint32*12),('comm',ctypes.c_char*16),('name',ctypes.c_char*32),
              ('details',ctypes.c_uint32*6),('start_seconds',ctypes.c_uint64),('start_microseconds',ctypes.c_uint64)]

def process_identity(pid):
    if type(pid) is not int or pid<=1:return None
    if sys.platform=='darwin':
        info=BSDInfo();lib=ctypes.CDLL('/usr/lib/libproc.dylib')
        lib.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
        lib.proc_pidinfo.restype=ctypes.c_int
        size=ctypes.sizeof(info)
        if size!=136 or lib.proc_pidinfo(pid,3,0,ctypes.byref(info),size)!=size:return None
        if info.words[3]!=pid or info.words[5]!=os.getuid() or info.words[1]==5:return None
        return f'{info.start_seconds}:{info.start_microseconds}'
    if sys.platform.startswith('linux'):
        try:
            path=pathlib.Path('/proc')/str(pid)/'stat'
            if path.stat().st_uid!=os.getuid():return None
            fields=path.read_text().rsplit(')',1)[1].split()
            if fields[0]=='Z':return None
            return fields[19]
        except (OSError,IndexError):return None
    raise WatchdogFailure('unsupported child identity platform')

def stop_identified(pid,identity):
    for sig,seconds in ((signal.SIGTERM,2),(signal.SIGKILL,2)):
        if process_identity(pid)!=identity:return True
        try:os.kill(pid,sig)
        except ProcessLookupError:return True
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            if process_identity(pid)!=identity:return True
            time.sleep(.05)
    return process_identity(pid)!=identity

class WatchedChild:
    def __init__(self,command,deadline,env=None,supervisor_command=None):
        self.child=None;self.supervisor=None;self.write_fd=None;self.stopped=threading.Event();self.child_lock=threading.Lock()
        self.deadline=deadline;self.identity=None
        read_fd,write_fd=os.pipe();ready_read,ready_write=os.pipe()
        self.write_fd=write_fd
        try:
            # The supervisor exists before route startup. Only the route remains in the launcher session.
            args=supervisor_command or [sys.executable,str(pathlib.Path(__file__).resolve()),str(read_fd),str(ready_write)]
            self.supervisor=subprocess.Popen(args,pass_fds=(read_fd,ready_write),stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,env=env)
            os.close(read_fd);read_fd=None;os.close(ready_write);ready_write=None
            self.child=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=env)
            self.identity=process_identity(self.child.pid)
            if self.identity is None or deadline<=time.monotonic():raise WatchdogFailure('child ownership unavailable')
            payload=json.dumps({'pid':self.child.pid,'identity':self.identity,'deadline':deadline}).encode()+b'\n'
            try:os.write(write_fd,payload)
            except OSError:raise WatchdogFailure('supervisor readiness channel failed') from None
            if not select.select([ready_read],[],[],3)[0] or os.read(ready_read,1)!=b'R':raise WatchdogFailure('supervisor readiness failed')
            self.monitor=threading.Thread(target=self._watch,daemon=True);self.monitor.start()
        except BaseException:
            self.close();raise
        finally:
            for fd in (read_fd,ready_read,ready_write):
                if fd is not None:os.close(fd)
    def _stop_child(self):
        # A still-unreaped Popen child cannot have its PID reused while its parent lives.
        with self.child_lock:
            if self.child is not None and self.child.poll() is None:
                self.child.terminate()
                try:self.child.wait(2)
                except subprocess.TimeoutExpired:self.child.kill();self.child.wait(2)
    def _watch(self):
        while not self.stopped.wait(.1):
            if self.supervisor.poll() is not None or time.monotonic()>=self.deadline or self.child.poll() is not None:
                self._stop_child();self.stopped.set();return
    @property
    def alive(self):return not self.stopped.is_set() and self.child is not None and self.child.poll() is None and self.supervisor.poll() is None
    def close(self):
        self.stopped.set()
        self._stop_child()
        if self.write_fd is not None:
            os.close(self.write_fd);self.write_fd=None
        if self.supervisor is not None:
            try:self.supervisor.wait(5)
            except subprocess.TimeoutExpired:self.supervisor.terminate();self.supervisor.wait(2)
        monitor=getattr(self,'monitor',None)
        if monitor is not None and monitor is not threading.current_thread():monitor.join(5)

def supervise(read_fd,ready_fd):
    stop=threading.Event()
    for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,lambda *unused:stop.set())
    value=None
    try:
        buffer=b'';startup=time.monotonic()+3
        while b'\n' not in buffer:
            if stop.is_set() or time.monotonic()>=startup:return
            if select.select([read_fd],[],[],.1)[0]:
                chunk=os.read(read_fd,4096)
                if not chunk:return
                buffer+=chunk
                if len(buffer)>4096:return
        value=json.loads(buffer)
        if set(value)!={'pid','identity','deadline'} or type(value['deadline']) not in (int,float) or not isinstance(value['identity'],str):return
        if process_identity(value['pid'])!=value['identity']:return
        deadline=value['deadline']
        if not time.monotonic()<deadline<=time.monotonic()+1200:return
        os.write(ready_fd,b'R');os.close(ready_fd);ready_fd=None
        while not stop.is_set() and time.monotonic()<deadline and process_identity(value['pid'])==value['identity']:
            if select.select([read_fd],[],[],.1)[0]:
                # The channel is liveness-only after its one authenticated startup record.
                if not os.read(read_fd,1):break
                break
    finally:
        if isinstance(value,dict) and type(value.get('pid')) is int and isinstance(value.get('identity'),str):
            stop_identified(value['pid'],value['identity'])
        os.close(read_fd)
        if ready_fd is not None:os.close(ready_fd)

if __name__=='__main__':supervise(int(sys.argv[1]),int(sys.argv[2]))
