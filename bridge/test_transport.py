import unittest
from unittest.mock import patch
from transport import ProxyConnection, validate_provenance

class TransportChecks(unittest.TestCase):
    def test_old_envelope_never_redirects(self):
        c=ProxyConnection.__new__(ProxyConnection);c.generation='old';c.closed=True
        with self.assertRaises(OSError):c.write('old',{'id':7,'result':{}})
        c.closed=False
        with self.assertRaises(OSError):c.write('new',{'id':7,'result':{}})
    def test_provenance_rejects_mismatch_before_launch(self):
        with patch('transport.read_private_json',return_value={'endpoint':'ws://127.0.0.1:5','thread_id':'owned','server_pid':123,'project':'/private/tmp/x/project'}):
            with self.assertRaises(ValueError):validate_provenance('/private/tmp/x','ws://127.0.0.1:6','owned')
            with self.assertRaises(ValueError):validate_provenance('/private/tmp/x','ws://127.0.0.1:5','foreign')

    def test_partial_write_failure_retires_connection(self):
        import queue,threading
        c=ProxyConnection.__new__(ProxyConnection);c.generation='g';c.closed=False;c.queue=queue.Queue();c.p=type('P',(),{'stdin':type('I',(),{'fileno':lambda self:3})()})()
        e={'generation':'g','line':b'1234','done':threading.Event(),'error':None};next_e={'generation':'g','line':b'5678','done':threading.Event(),'error':None}
        c.queue.put(e);c.queue.put(next_e)
        calls=[]
        def write(fd,line):
            calls.append(line)
            if len(calls)==1:return 2
            raise OSError('pipe failure')
        with patch('transport.select.select',return_value=([],[c.p.stdin],[])),patch('transport.os.write',side_effect=write):
            worker=threading.Thread(target=c._writer,daemon=True);worker.start();e['done'].wait(1)
            # Explicit stop prevents the old implementation looping in the test.
            failed_closed=c.closed;c.closed=True;worker.join(1)
        self.assertTrue(failed_closed);self.assertEqual(len(calls),2);self.assertTrue(next_e['error'])

    def test_queued_old_generation_is_cancelled_without_writing(self):
        import queue,threading
        c=ProxyConnection.__new__(ProxyConnection);c.generation='new';c.closed=False;c.queue=queue.Queue();c.p=type('P',(),{'stdin':object()})()
        e={'generation':'old','line':b'old answer','done':threading.Event(),'error':None};c.queue.put(e)
        with patch('transport.os.write') as write:
            worker=threading.Thread(target=c._writer,daemon=True);worker.start();self.assertTrue(e['done'].wait(1));worker.join(1)
        write.assert_not_called();self.assertTrue(e['error']);self.assertTrue(c.closed)

    def test_transport_answer_keeps_original_proxy_during_replacement(self):
        import threading
        from transport import BridgeTransport
        from state import BridgeState
        from test_state import question,A,OP
        state=BridgeState('owned');old_g=state.begin();state.hydrate(old_g,{'id':'owned','turns':[]});state.apply(old_g,question())
        control=state.snapshot()['pending'][0]['control_id'];entered=threading.Event();release=threading.Event()
        class Peer:
            def __init__(self,generation):self.generation=generation;self.closed=False;self.writes=[]
            def write(self,generation,message):
                entered.set();release.wait(2)
                if self.closed or generation!=self.generation:raise OSError()
                self.writes.append(message)
        old=Peer(old_g);transport=BridgeTransport.__new__(BridgeTransport);transport.lock=threading.Lock();transport.current=old;transport.state=state
        result=[];worker=threading.Thread(target=lambda:result.append(transport.answer(control,OP,A)));worker.start();self.assertTrue(entered.wait(1))
        old.closed=True;state.disconnect(old_g);new_g=state.begin();state.hydrate(new_g,{'id':'owned','turns':[]});state.apply(new_g,question());new=Peer(new_g)
        with transport.lock:transport.current=new
        release.set();worker.join(2)
        self.assertEqual(result,['uncertain']);self.assertEqual(old.writes,[]);self.assertEqual(new.writes,[])
        self.assertEqual(state.snapshot()['pending'][0]['status'],'pending')
