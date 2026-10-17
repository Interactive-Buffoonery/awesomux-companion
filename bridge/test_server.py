import http.client
import json
import threading
import unittest
from server import make_server
from state import BridgeState
from test_state import question,A,OP

class HTTPChecks(unittest.TestCase):
    def setUp(self):
        self.state=BridgeState('owned');g=self.state.begin();self.state.hydrate(g,{'id':'owned','turns':[]});self.state.apply(g,question());self.control=self.state.snapshot()['pending'][0]['control_id'];self.writes=[]
        self.server=make_server(self.state,lambda c,o,a,confirm:self.state.answer(c,o,a,self.writes.append,confirm_uncertain=confirm),'x'*43)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
    def tearDown(self):self.server.shutdown();self.server.server_close();self.thread.join(2)
    def request(self,method='GET',path='/v1/thread',body=None,headers=None):
        c=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=2)
        h={'Authorization':'Bearer '+'x'*43};h.update(headers or {})
        c.request(method,path,body=body,headers=h);r=c.getresponse();value=r.read();c.close();return r.status,value
    def test_auth_origin_host_and_no_store(self):
        self.assertEqual(self.request(headers={'Authorization':'bad'})[0],401)
        self.assertEqual(self.request(headers={'Authorization':'Bearer é'})[0],401)
        self.assertEqual(self.request(headers={'Origin':'https://example.invalid'})[0],403)
        self.assertEqual(self.request(headers={'Host':'elsewhere'})[0],403)
        self.assertEqual(self.request()[0],200)
        self.assertEqual(self.writes,[])
    def test_answer_duplicate_and_invalid_body(self):
        value={'control_id':self.control,'operation_id':OP,'answers':A}
        body=json.dumps(value)
        for _ in range(2):self.assertEqual(self.request('POST','/v1/answers',body,{'Content-Type':'application/json'})[0],202)
        self.assertEqual(len(self.writes),1)
        self.assertEqual(self.request('POST','/v1/answers','{',{'Content-Type':'application/json'})[0],400)
        self.assertEqual(self.request('POST','/v1/answers','x'*65537,{'Content-Type':'application/json'})[0],413)
        self.assertEqual(self.request('POST','/v1/answers',body,{'Content-Type':'application/json','Transfer-Encoding':'chunked'})[0],400)
        self.assertEqual(self.request('POST','/v1/answers',json.dumps(dict(value,extra=True)),{'Content-Type':'application/json'})[0],400)
        self.assertEqual(len(self.writes),1)

class ProxyHostChecks(HTTPChecks):
    def setUp(self):
        self.state=BridgeState('owned');g=self.state.begin();self.state.hydrate(g,{'id':'owned','turns':[]});self.state.apply(g,question());self.control=self.state.snapshot()['pending'][0]['control_id'];self.writes=[]
        self.server=make_server(self.state,lambda c,o,a,confirm:self.state.answer(c,o,a,self.writes.append,confirm_uncertain=confirm),'x'*43,allowed_proxy_host='mac.example.ts.net:8443')
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
    def test_exact_proxy_host_retains_other_boundaries(self):
        self.assertEqual(self.request(headers={'Host':'mac.example.ts.net:8443'})[0],200)
        for host in ['mac.example.ts.net','mac.example.ts.net:10000','MAC.example.ts.net:8443','mac.example.ts.net.:8443','other.example.ts.net:8443']:
            self.assertEqual(self.request(headers={'Host':host})[0],403)
        self.assertEqual(self.request(headers={'Host':'mac.example.ts.net:8443','Authorization':'bad'})[0],401)
        self.assertEqual(self.request(headers={'Host':'mac.example.ts.net:8443','Origin':'https://mac.example.ts.net:8443'})[0],403)
        self.assertEqual(self.request(headers={'Host':'elsewhere','X-Forwarded-Host':'mac.example.ts.net:8443'})[0],403)
        body=json.dumps({'control_id':self.control,'operation_id':OP,'answers':A})
        headers={'Host':'mac.example.ts.net:8443','Content-Type':'application/json'}
        self.assertEqual(self.request('POST','/v1/answers',body,headers)[0],202)
        self.assertEqual(self.request('POST','/v1/answers','x'*65537,headers)[0],413)
        self.assertEqual(self.request('POST','/v1/answers',body,dict(headers,**{'Transfer-Encoding':'chunked'}))[0],400)
        self.assertEqual(len(self.writes),1)
