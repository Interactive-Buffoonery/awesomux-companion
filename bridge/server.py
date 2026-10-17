"""Loopback-only development HTTP adapter. No request logging or CORS."""
import argparse
import hmac
import json
import secrets
import signal
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from private_files import write_private_json
from state import BridgeState
from transport import BridgeTransport

class LocalServer(ThreadingHTTPServer):
    daemon_threads=True
    request_queue_size=16
    def handle_error(self,request,client_address):pass


def make_server(state,answer,token,allowed_proxy_host=None):
    if allowed_proxy_host is not None:
        from private_route import canonical_dns,RouteFailure
        try:
            dns,port=allowed_proxy_host.rsplit(':',1)
            if canonical_dns(dns)!=dns or port not in ('8443','10000'):raise ValueError()
        except (ValueError,AttributeError,RouteFailure):raise ValueError('invalid configured proxy host') from None
    capability=token.encode('ascii')
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup();self.connection.settimeout(5)
        def log_message(self,*args):pass
        def reply(self,status,value):
            data=json.dumps(value,separators=(',',':')).encode()
            self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(data)));self.send_header('Connection','close');self.end_headers()
            self.wfile.write(data);self.close_connection=True
        def allowed(self):
            values=self.headers.get_all('Authorization',[])
            if len(values)!=1 or not values[0].startswith('Bearer ') or not hmac.compare_digest(values[0][7:].encode('utf-8'),capability):
                self.reply(401,{'error':'unauthorized'});return False
            hosts=self.headers.get_all('Host',[])
            if self.headers.get_all('Origin') or len(hosts)!=1 or hosts[0] not in ('127.0.0.1:'+str(self.server.server_port),allowed_proxy_host):
                self.reply(403,{'error':'forbidden'});return False
            return True
        def do_GET(self):
            if not self.allowed():return
            if self.path!='/v1/thread':self.reply(404,{'error':'not_found'});return
            self.reply(200,state.snapshot())
        def do_POST(self):
            if not self.allowed():return
            if self.path!='/v1/answers':self.reply(404,{'error':'not_found'});return
            lengths=self.headers.get_all('Content-Length',[])
            if self.headers.get_all('Transfer-Encoding') or len(lengths)!=1 or not lengths[0].isascii() or not lengths[0].isdigit() or self.headers.get_all('Content-Type',[])!=['application/json']:
                self.reply(400,{'error':'invalid_request'});return
            size=int(lengths[0])
            if size>65536:self.reply(413,{'error':'body_limit'});return
            try:
                raw=self.rfile.read(size)
                if len(raw)!=size:raise ValueError()
                value=json.loads(raw)
                if not isinstance(value,dict) or not {'control_id','operation_id','answers'}<=set(value) or set(value)-{'control_id','operation_id','answers','confirm_uncertain'} or ('confirm_uncertain' in value and type(value['confirm_uncertain']) is not bool):raise ValueError()
                outcome=answer(value['control_id'],value['operation_id'],value['answers'],value.get('confirm_uncertain',False))
            except (ValueError,UnicodeError,TimeoutError,socket.timeout):self.reply(400,{'error':'invalid_request'});return
            status={'submitted':202,'submitting':202,'uncertain':202,'resolved':200,'conflict':409,'already_submitted':409,'confirmation_required':409,'rejected':404,'disconnected':503,'capacity':503}.get(outcome,503)
            self.reply(status,{'outcome':outcome})
    return LocalServer(('127.0.0.1',0),Handler)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--private-directory',required=True);parser.add_argument('--endpoint',required=True);parser.add_argument('--thread',required=True)
    args=parser.parse_args()
    state=BridgeState(args.thread)
    # Provenance validation precedes HTTP binding or upstream attachment.
    transport=BridgeTransport(state,args.private_directory,args.endpoint,args.thread)
    token=secrets.token_urlsafe(32)
    server=make_server(state,transport.answer,token)
    started=False
    stop=threading.Event()
    try:
        write_private_json(args.private_directory,'client.json',{'endpoint':'http://127.0.0.1:'+str(server.server_port),'token':token})
        transport.start();started=True
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        def stopping(*unused):stop.set()
        signal.signal(signal.SIGINT,stopping);signal.signal(signal.SIGTERM,stopping)
        while not stop.wait(.5):
            if not transport.worker.is_alive():break
    finally:
        if started:server.shutdown();transport.close()
        server.server_close()

if __name__=='__main__':main()
