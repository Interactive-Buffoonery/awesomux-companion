"""Disposable managed-session smoke. Leaves history; trashes only owned temp data."""
from http.client import HTTPConnection
import argparse
import json
import signal
import sys
import os
import pathlib
import pty
import re
import secrets
import select
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from private_files import write_private_json
from state import BridgeState
from transport import ProxyConnection,BridgeTransport
from server import make_server


def assistant_answer_observed(messages):
    return any(m.get('role') == 'assistant' and m.get('text') in ('Bridge received ALPHA', 'Bridge received BETA') for m in messages)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interactive',action='store_true',help='bounded 20-minute Simulator development session')
    parser.add_argument('--private-https',action='store_true',help='owned private phone trial; requires separately authorized exact origin')
    parser.add_argument('--approved-private-origin',help='exact previously authorized origin; never contains a key')
    parser.add_argument('--preflight-private-https',action='store_true',help='read-only route capability check; no runtime or exposure')
    args=parser.parse_args()
    route=None
    if args.preflight_private_https:
        from private_route import PrivateRoute
        origin=PrivateRoute().prepare()
        print(json.dumps({'private_origin':origin,'read_only':True,'no_route_enabled':True}),flush=True)
        return
    if args.private_https and (not args.interactive or not args.approved_private_origin):parser.error('private HTTPS requires interactive mode and exact authorized origin')
    if args.approved_private_origin and not args.private_https:parser.error('authorized origin requires private HTTPS')
    stop=threading.Event()
    for sig in (signal.SIGINT,signal.SIGTERM,signal.SIGHUP):signal.signal(sig,lambda *unused:stop.set())
    deadline=time.monotonic()+1200
    proxy_host=None
    if args.private_https:
        from private_route import PrivateRoute
        from urllib.parse import urlsplit
        route=PrivateRoute(deadline=deadline)
        origin=route.prepare()
        if origin!=args.approved_private_origin:raise ValueError('prepared private origin differs from authorization')
        proxy_host=urlsplit(origin).netloc
    root=pathlib.Path(tempfile.mkdtemp(prefix='amx-ios-bridge-',dir='/private/tmp'));root.chmod(0o700)
    (root/'project').mkdir();(root/'amx').mkdir()
    token=secrets.token_urlsafe(32)
    fd=os.open(root/'upstream-token',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as f:f.write(token)
    env=os.environ.copy();scrubbed=[]
    for key in list(env):
        if key.startswith('AWESOMUX_AGENT_') or key in ('AWESOMUX_PANE_ID','AWESOMUX_SESSION_ID','ZMX_SESSION','ZMX_SESSION_PREFIX') or key.startswith('MOSHI_'):
            scrubbed.append(key);env.pop(key)
    result={'cli':'0.160.0','scope':'owned authenticated managed runtime; no existing sessions','server_scrubbed_keys':scrubbed,'notification_overrides':['notify=[]','tui.notifications=false']}
    server=None;port=None;first=None;transport=None;http=None;desktop=None;master=None;name=str(uuid.uuid4());amx_created=False
    errors=[]
    try:
        server=subprocess.Popen(['codex','-c','notify=[]','-c','tui.notifications=false','app-server','--listen','ws://127.0.0.1:0','--ws-auth','capability-token','--ws-token-file',str(root/'upstream-token')],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,start_new_session=True)
        result['owned_server_pid']=server.pid
        buf=b'';end=time.monotonic()+30
        while time.monotonic()<end and not stop.is_set():
            if not select.select([server.stderr],[],[],.5)[0]:continue
            chunk=os.read(server.stderr.fileno(),4096)
            if not chunk:
                result['startup_permission_denied']=b'Operation not permitted' in buf or b'Permission denied' in buf
                raise EOFError('owned server exited')
            buf+=chunk;match=re.search(rb'ws://127\.0\.0\.1:(\d+)',buf)
            if match:port=int(match[1]);break
            if len(buf)>65536:raise ValueError('startup bound')
        if port is None:raise TimeoutError('startup deadline')
        # Drain and discard diagnostics; never retain host configuration/transcripts.
        def drain():
            while server.poll() is None:
                try:
                    if not os.read(server.stderr.fileno(),65536):break
                except OSError:break
        threading.Thread(target=drain,daemon=True).start()
        endpoint='ws://127.0.0.1:'+str(port)
        def handshake(extra):
            with socket.create_connection(('127.0.0.1',port),timeout=5) as s:
                request='GET / HTTP/1.1\r\nHost: 127.0.0.1:'+str(port)+'\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n'+extra+'\r\n'
                s.sendall(request.encode());return s.recv(4096).split(b'\r\n',1)[0].decode()
        result['missing_auth']=handshake('');result['wrong_auth']=handshake('Authorization: Bearer wrong\r\n');result['origin']=handshake('Authorization: Bearer '+token+'\r\nOrigin: https://example.invalid\r\n')
        if any('101' in result[k] for k in ('missing_auth','wrong_auth','origin')):raise RuntimeError('upstream boundary rejected')
        first=ProxyConnection(endpoint,root/'upstream-token','launcher')
        first.call('initialize',{'clientInfo':{'name':'awesomux_bridge_smoke','version':'0.1'},'capabilities':{'experimentalApi':True}})
        first.write('launcher',{'method':'initialized'})
        effective=first.call('config/read',{'includeLayers':False})['config']
        result['notify_empty_verified']=effective.get('notify')==[]
        result['tui_notifications_disabled_verified']=effective.get('tui',{}).get('notifications') is False
        if not result['notify_empty_verified'] or not result['tui_notifications_disabled_verified']:raise RuntimeError('quiet-launch readback failed')
        started=first.call('thread/start',{'cwd':str(root/'project')})
        tid=started['thread']['id'];model=started['model'];result['thread_prefix']=tid[:8];result['model']=model
        write_private_json(root,'provenance.json',{'server_pid':server.pid,'endpoint':endpoint,'thread_id':tid,'project':str(root/'project')})
        def turn():
            return first.call('turn/start',{'threadId':tid,'input':[{'type':'text','text':'This is a disposable interface test. Do not read files, use shell, change files, or use any tool except request_user_input. Immediately ask one request_user_input question id probe_choice, header Probe, question "Probe choice?", options ALPHA and BETA. After the answer respond exactly "Bridge received ALPHA" for ALPHA or "Bridge received BETA" for BETA.'}],'collaborationMode':{'mode':'plan','settings':{'model':model,'developer_instructions':None}}})
        if stop.is_set():raise InterruptedError('launcher stopped')
        turn()
        master,slave=pty.openpty();desktop_env=dict(env,ZMX_DIR=str(root/'amx'),AMX_COMPANION_PROBE_TOKEN=token)
        try:desktop=subprocess.Popen(['amx','attach',name,'codex','-c','notify=[]','-c','tui.notifications=false','--remote',endpoint,'--remote-auth-token-env','AMX_COMPANION_PROBE_TOKEN','resume',tid,'--no-alt-screen'],env=desktop_env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True)
        finally:os.close(slave)
        amx_created=True
        result['tui_notification_argv_overrides']=['notify=[]','tui.notifications=false']
        def drain_tui():
            while desktop.poll() is None:
                try:
                    if select.select([master],[],[],.5)[0]:os.read(master,65536)
                except (OSError,ValueError):break
        threading.Thread(target=drain_tui,daemon=True).start()
        state=BridgeState(tid);transport=BridgeTransport(state,root,endpoint,tid);transport.start()
        http_token=secrets.token_urlsafe(32)
        http=make_server(state,lambda c,o,a,confirm:transport.answer(c,o,a,confirm),http_token,allowed_proxy_host=proxy_host)
        threading.Thread(target=http.serve_forever,daemon=True).start()
        if args.interactive:
            client_origin='http://127.0.0.1:'+str(http.server_port)
            if route is not None:
                if stop.is_set():raise InterruptedError('launcher stopped')
                client_origin=route.start(http.server_port,proxy_host.rsplit(':',1)[0])
            write_private_json(root,'client.json',{'endpoint':client_origin,'token':http_token})
            result['interactive']=True
            print(json.dumps({'development_directory':str(root),'client_file':str(root/'client.json'),'commands':'next, stop','expires_in_seconds':max(0,int(deadline-time.monotonic())),**({'private_origin':client_origin} if route is not None else {})}),flush=True)
            while not stop.is_set() and time.monotonic()<deadline and server.poll() is None and (route is None or route.alive):
                if select.select([sys.stdin],[],[],.5)[0]:
                    command=sys.stdin.readline().strip()
                    if command=='stop' or command=='':break
                    if command=='next' and state.snapshot()['connected'] and not state.snapshot()['pending']:turn()
                snap=state.snapshot()
                result['ui_answer_observed']=assistant_answer_observed(snap['messages'])
                result['resolved_operation_count']=sum(v=='resolved' for v in snap['operations'].values())
            return
        def request(method,path,value=None):
            c=HTTPConnection('127.0.0.1',http.server_port,timeout=8)
            body=json.dumps(value) if value is not None else None
            headers={'Authorization':'Bearer '+http_token}
            if body is not None:headers['Content-Type']='application/json'
            c.request(method,path,body,headers);r=c.getresponse();data=json.loads(r.read());status=r.status;c.close();return status,data
        def until(predicate,seconds=120):
            end=time.monotonic()+seconds
            while time.monotonic()<end:
                status,snapshot=request('GET','/v1/thread')
                if status!=200:raise RuntimeError('snapshot failed')
                if predicate(snapshot):return snapshot
                time.sleep(.25)
            raise TimeoutError('observation deadline')
        pending=until(lambda s:len(s['pending'])==1)['pending'][0]
        answers={q['id']:{'answers':['ALPHA']} for q in pending['questions']}
        op=str(uuid.uuid4());status,response=request('POST','/v1/answers',{'control_id':pending['control_id'],'operation_id':op,'answers':answers})
        result['first_http_status']=status;result['first_reply']=response.get('outcome')
        result['duplicate_reply']=request('POST','/v1/answers',{'control_id':pending['control_id'],'operation_id':op,'answers':answers})[1].get('outcome')
        complete=until(lambda s:not s['pending'] and assistant_answer_observed(s['messages']),60)
        result['first_answer_observed']=True;result['resolved_operation']=complete['operations'].get(op)
        turn();pending=until(lambda s:len(s['pending'])==1)['pending'][0]
        old_generation=state.generation
        with transport.lock:old_connection=transport.current
        old_connection.close();state.disconnect(old_generation)
        replay=until(lambda s:len(s['pending'])==1 and s['pending'][0]['control_id']!=pending['control_id'],45)['pending'][0]
        result['pending_replayed']=True
        result['stale_control_reply']=request('POST','/v1/answers',{'control_id':pending['control_id'],'operation_id':str(uuid.uuid4()),'answers':answers})[1].get('outcome')
        op2=str(uuid.uuid4());result['replayed_reply']=request('POST','/v1/answers',{'control_id':replay['control_id'],'operation_id':op2,'answers':answers})[1].get('outcome')
        until(lambda s:not s['pending'] and s['operations'].get(op2)=='resolved',60)
        result['replayed_answer_resolved']=True
        turn();third=until(lambda s:len(s['pending'])==1)['pending'][0]
        op3=str(uuid.uuid4())
        with transport.lock:loss_connection=transport.current
        # Fault injection: discard old-generation resolution delivery, then close
        # immediately after pipe handoff. Never infer server acceptance from this.
        original_apply=state.apply
        def fault_apply(generation,message):
            if generation==loss_connection.generation and message.get('method')=='serverRequest/resolved':return
            original_apply(generation,message)
        state.apply=fault_apply
        def write_then_drop(message):
            loss_connection.write(loss_connection.generation,message)
            state.disconnect(loss_connection.generation)
            loss_connection.close()
        result['post_handoff_loss_outcome']=state.answer(third['control_id'],op3,answers,write_then_drop,expected_generation=loss_connection.generation)
        state.apply=original_apply
        result['post_handoff_loss_operation']=state.snapshot()['operations'].get(op3)
        result['loss_acceptance']='unknown; fault-injected after proxy handoff, resolution suppressed'
        result['loss_automatic_resend']=False
        if result['post_handoff_loss_outcome']!='uncertain':raise RuntimeError('uncertainty guard failed')
        result['desktop_process_alive']=desktop.poll() is None
        result['desktop_prompt_state']='not inspected; continuation evidence is protocol completed text only'
    except Exception as exc:result['failure']=type(exc).__name__+': '+str(exc)[:160]
    finally:
        if route is not None:
            result['private_route_cleanup']=route.close()
            if not all(result['private_route_cleanup'].values()):errors.append('private route cleanup conflict')
        def attempt(label,action):
            try:return action()
            except Exception as exc:errors.append(label+': '+type(exc).__name__)
        if http:attempt('http shutdown',http.shutdown);attempt('http close',http.server_close)
        if transport:attempt('transport',transport.close)
        if first:attempt('launcher',first.close)
        if amx_created:
            killed=attempt('amx kill',lambda:subprocess.run(['amx','kill',name],env=desktop_env,capture_output=True,timeout=10))
            listed=attempt('amx list',lambda:subprocess.run(['amx','list','--short'],env=desktop_env,capture_output=True,timeout=10))
            result['amx_kill_exit']=killed.returncode if killed else None
            result['amx_absent']=name not in listed.stdout.decode() if listed and listed.returncode==0 else None
            if result['amx_absent'] is not True:result['owned_amx_session']=name
        def stop_process(p):
            if p.poll() is None:
                os.killpg(p.pid,signal.SIGTERM)
            try:p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGKILL)
                p.wait(timeout=5)
        if desktop:attempt('desktop',lambda:stop_process(desktop))
        if master is not None:attempt('pty',lambda:os.close(master))
        if server:attempt('server',lambda:stop_process(server));result['server_exit']=server.poll()
        if port:
            with socket.socket() as s:s.settimeout(2);result['endpoint_closed']=s.connect_ex(('127.0.0.1',port))!=0
        if not errors and result.get('endpoint_closed') is True and (not amx_created or result.get('amx_absent') is True):
            trashed=attempt('trash',lambda:subprocess.run(['trash',str(root)],capture_output=True,timeout=10))
            result['private_root_absent']=not root.exists() if trashed and trashed.returncode==0 else False
        if root.exists():result['owned_private_root']=str(root)
        result['cleanup_errors']=errors
        output=pathlib.Path(__file__).resolve().parent.parent/('docs/reviews/2026-10-02-physical-live-result.json' if args.private_https else ('docs/reviews/2026-10-02-native-live-result.json' if args.interactive else 'docs/reviews/2026-10-02-foreground-live-result.json'))
        output.write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))

if __name__=='__main__':main()
