"""Owned foreground Tailscale route. No off/reset, background or Funnel commands."""
import copy
import json
import os
import stat
import re
import subprocess

VERSION='1.102.4'
COMMIT='3caf7d9e7dcaba589cfc58beda596929733e4fea'
class RouteFailure(RuntimeError):pass

def canonical_dns(name):
    if not isinstance(name,str):raise RouteFailure('invalid private host')
    name=name.removesuffix('.')
    labels=name.split('.')
    if len(name)>253 or len(labels)<4 or labels[-2:]!=['ts','net'] or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?',l) for l in labels):
        raise RouteFailure('invalid private host')
    return name

def validate_status(config):
    if not isinstance(config,dict) or set(config)-{'TCP','Web','AllowFunnel','Foreground','ETag'}:raise RouteFailure('unsupported Serve schema')
    for key in ('TCP','Web','AllowFunnel','Foreground'):
        if key in config and not isinstance(config[key],dict):raise RouteFailure('unsupported Serve schema')
    for port in config.get('TCP',{}):
        if not isinstance(port,str) or not port.isdigit() or not 1<=int(port)<=65535:raise RouteFailure('invalid Serve port')
    for key in ('Web','AllowFunnel'):
        for origin in config.get(key,{}):
            if not isinstance(origin,str) or ':' not in origin or not origin.rsplit(':',1)[1].isdigit():raise RouteFailure('unsupported Serve origin')
    for child in config.get('Foreground',{}).values():validate_status(child)

def occupied(config):
    validate_status(config)
    ports={int(p) for p in config.get('TCP',{})}
    ports.update(int(origin.rsplit(':',1)[1]) for key in ('Web','AllowFunnel') for origin in config.get(key,{}))
    for child in config.get('Foreground',{}).values():ports.update(occupied(child))
    return ports

def choose_port(config):
    used=occupied(config)
    for port in (8443,10000):
        if port not in used:return port
    raise RouteFailure('private trial ports already occupied')

def normalize(config):
    validate_status(config)
    value=copy.deepcopy(config);value.pop('ETag',None)
    for key in ('TCP','Web','AllowFunnel','Foreground'):
        if value.get(key)=={}:value.pop(key)
    if 'Foreground' in value:value['Foreground']={k:normalize(v) for k,v in value['Foreground'].items()}
    return value

def verify_owned_entry(before,after,dns,port,backend):
    dns=canonical_dns(dns);before=normalize(before);after=normalize(after)
    prior=before.get('Foreground',{});current=after.get('Foreground',{})
    added=set(current)-set(prior)
    if len(added)!=1:raise RouteFailure('route ownership not established')
    session=added.pop()
    expected={'TCP':{str(port):{'HTTPS':True}},'Web':{f'{dns}:{port}':{'Handlers':{'/':{'Proxy':f'http://127.0.0.1:{backend}'}}}}}
    if current[session]!=expected:raise RouteFailure('route target or private scope differs')
    remaining=copy.deepcopy(after);del remaining['Foreground'][session]
    if normalize(remaining)!=before:raise RouteFailure('unrelated Serve configuration changed')
    return session

def verify_cleanup(before,after,session,port):
    try:return session not in after.get('Foreground',{}) and port not in occupied(after) and normalize(before)==normalize(after)
    except RouteFailure:return False

class TailscaleCLI:
    def __init__(self,executable='/Applications/Tailscale.app/Contents/MacOS/Tailscale'):
        self.executable=os.path.realpath(executable)
        self.validate_binary()
    def validate_binary(self):
        fd=None
        try:
            fd=os.open(self.executable,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
            if not stat.S_ISREG(os.fstat(fd).st_mode):raise RouteFailure('Tailscale executable must be a native binary')
            magic=os.read(fd,4)
            if magic not in tuple(bytes.fromhex(value) for value in ('feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca')):
                raise RouteFailure('Tailscale executable must be a native binary')
        except OSError:raise RouteFailure('Tailscale executable unavailable') from None
        finally:
            if fd is not None:os.close(fd)
    def read(self,*arguments):
        self.validate_binary()
        result=subprocess.run([self.executable,*arguments],stdin=subprocess.DEVNULL,capture_output=True,timeout=8)
        if result.returncode or len(result.stdout)>1024*1024:raise RouteFailure('Tailscale read unavailable')
        return result.stdout
    def preflight(self):
        try:version=json.loads(self.read('version','--json'))
        except (ValueError,TypeError):raise RouteFailure('unsupported Tailscale version response') from None
        if version.get('short')!=VERSION or version.get('gitCommit')!=COMMIT:raise RouteFailure('Tailscale version not reviewed')
        try:status=json.loads(self.read('status','--json'))
        except ValueError:raise RouteFailure('invalid Tailscale status') from None
        if status.get('BackendState')!='Running':raise RouteFailure('tailnet is unavailable')
        dns=canonical_dns(status.get('Self',{}).get('DNSName'))
        baseline=self.status();port=choose_port(baseline)
        return dns,baseline,port
    def status(self):
        try:value=json.loads(self.read('serve','status','--json'))
        except ValueError:raise RouteFailure('invalid Serve status') from None
        validate_status(value);return value
    def command(self,port,backend):
        self.validate_binary()
        if port not in (8443,10000) or type(backend) is not int or not 1<=backend<=65535:raise RouteFailure('invalid route ports')
        return [self.executable,'serve',f'--https={port}',f'http://127.0.0.1:{backend}']

class PrivateRoute:
    def __init__(self,cli=None,watcher_factory=None,deadline=None):
        import time
        from route_watchdog import WatchedChild
        self.cli=cli or TailscaleCLI();self.watcher_factory=watcher_factory or WatchedChild
        self.deadline=deadline if deadline is not None else time.monotonic()+1200
        self.prepared=None;self.watcher=None;self.session=None;self.cleanup=None
    def prepare(self):
        if self.watcher is not None:raise RouteFailure('route already started')
        dns,before,port=self.cli.preflight();self.prepared=(dns,copy.deepcopy(before),port)
        return f'https://{dns}:{port}'
    @property
    def alive(self):return self.watcher is not None and self.watcher.alive
    def start(self,backend_port,expected_dns_name):
        import os,time
        if self.watcher is not None or type(backend_port) is not int or not 1<=backend_port<=65535:raise RouteFailure('invalid route start')
        if self.prepared is None:self.prepare()
        dns,before,port=self.prepared
        current=self.cli.preflight()
        if canonical_dns(expected_dns_name)!=expected_dns_name or expected_dns_name!=dns or current[0]!=dns or current[2]!=port or normalize(current[1])!=normalize(before):
            raise RouteFailure('prepared route baseline changed')
        env=os.environ.copy()
        for key in list(env):
            if key.startswith(('MOSHI_','AWESOMUX_AGENT_')) or key in ('AWESOMUX_PANE_ID','AWESOMUX_SESSION_ID','ZMX_SESSION','ZMX_SESSION_PREFIX'):env.pop(key)
        try:
            self.watcher=self.watcher_factory(self.cli.command(port,backend_port),self.deadline,env=env)
            end=min(time.monotonic()+8,self.deadline)
            while time.monotonic()<end and self.watcher.alive:
                after=self.cli.status()
                if normalize(after)==normalize(before):time.sleep(.1);continue
                self.session=verify_owned_entry(before,after,dns,port,backend_port)
                return f'https://{dns}:{port}'
            raise RouteFailure('foreground route did not become ready')
        except BaseException:
            self.close();raise
    def close(self):
        if self.cleanup is not None:return self.cleanup
        stopped=True
        if self.watcher is not None:
            try:self.watcher.close();stopped=not self.watcher.alive
            except Exception:stopped=False
        absent=preserved=False
        if self.prepared is not None:
            dns,before,port=self.prepared
            try:
                import time
                end=time.monotonic()+3
                after=self.cli.status()
                while self.session is not None and self.session in after.get('Foreground',{}) and time.monotonic()<end:
                    time.sleep(.1);after=self.cli.status()
                absent=self.session not in after.get('Foreground',{}) and port not in occupied(after)
                preserved=normalize(before)==normalize(after)
            except Exception:pass
        self.cleanup={'owned_process_stopped':stopped,'owned_route_absent':absent,'unrelated_routes_preserved':preserved}
        return self.cleanup
