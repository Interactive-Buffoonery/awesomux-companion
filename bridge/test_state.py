import threading
import unittest
from state import BridgeState

def question(rid=7, turn='turn', item='qitem'):
    return {'id':rid,'method':'item/tool/requestUserInput','params':{'threadId':'owned','turnId':turn,'itemId':item,'isBlocking':True,'questions':[{'id':'q','header':'Choice','question':'Choose','options':[{'label':'A','description':'A'},{'label':'B','description':'B'}]}]}}

A={'q':{'answers':['A']}}
OP='00000000-0000-4000-8000-000000000001'
OP2='00000000-0000-4000-8000-000000000002'

class StateChecks(unittest.TestCase):
    def ready(self):
        s=BridgeState('owned');g=s.begin();s.hydrate(g,{'id':'owned','turns':[]});s.apply(g,question());return s,g,s.snapshot()['pending'][0]['control_id']
    def test_control_reservation_and_operations(self):
        s,g,c=self.ready();writes=[]
        self.assertEqual(s.answer(c,OP,A,writes.append),'submitted')
        self.assertEqual(s.answer(c,OP,A,writes.append),'submitted')
        self.assertEqual(s.answer(c,OP,{'q':{'answers':['B']}},writes.append),'conflict')
        self.assertEqual(s.answer(c,OP2,A,writes.append),'already_submitted')
        self.assertEqual(writes,[{'id':7,'result':{'answers':A}}])
        s.apply(g,{'method':'serverRequest/resolved','params':{'threadId':'owned','requestId':7}})
        self.assertEqual(s.snapshot()['pending'],[])
    def test_uncertain_reconnect_and_old_events(self):
        s,g,c=self.ready();writes=[]
        def fail(m):writes.append(m);raise OSError()
        self.assertEqual(s.answer(c,OP,A,fail),'uncertain')
        self.assertEqual(s.answer(c,OP2,A,writes.append),'uncertain')
        s.disconnect(g);g2=s.begin();s.hydrate(g2,{'id':'owned','turns':[]});s.apply(g2,question())
        new=s.snapshot()['pending'][0];self.assertNotEqual(c,new['control_id']);self.assertTrue(new['prior_attempt_uncertain'])
        s.apply(g,{'method':'serverRequest/resolved','params':{'threadId':'owned','requestId':7}})
        self.assertEqual(len(s.snapshot()['pending']),1)
        self.assertEqual(s.answer(c,OP2,A,writes.append),'rejected')
        self.assertEqual(s.answer(new['control_id'],OP2,A,writes.append),'confirmation_required')
        self.assertEqual(s.answer(new['control_id'],OP2,A,writes.append,confirm_uncertain=True),'submitted')
    def test_writes_do_not_hold_lock_and_duplicate_returns_immediately(self):
        s,g,c=self.ready();entered=threading.Event();release=threading.Event();result=[]
        def blocking(m):entered.set();release.wait(2)
        t=threading.Thread(target=lambda:result.append(s.answer(c,OP,A,blocking)));t.start();self.assertTrue(entered.wait(1))
        self.assertEqual(s.answer(c,OP,A,blocking),'submitting')
        self.assertEqual(s.answer(c,OP2,A,blocking),'already_submitted')
        self.assertEqual(len(s.snapshot()['pending']),1)
        s.disconnect(g);g2=s.begin();s.hydrate(g2,{'id':'owned','turns':[]});s.apply(g2,question())
        release.set();t.join(2);self.assertEqual(result,['uncertain'])
        self.assertEqual(s.snapshot()['pending'][0]['status'],'pending')
    def test_invalid_foreign_unsupported_and_process_nonce(self):
        s,g,c=self.ready();writes=[]
        for answers in ({},{'q':{'answers':['invalid']}},{'q':{'answers':[1]}}):self.assertEqual(s.answer(c,OP,answers,writes.append),'rejected')
        s.apply(g,dict(question(),params=dict(question()['params'],threadId='foreign')))
        s.apply(g,{'id':9,'method':'item/commandExecution/requestApproval','params':{'threadId':'owned'}})
        s.apply(g,None);s.apply(g,{'method':'serverRequest/resolved','params':{'threadId':'owned','requestId':[]}})
        self.assertEqual(writes,[])
        self.assertTrue(s.snapshot()['unsupported_request'])
        s2,g2,c2=self.ready();self.assertNotEqual(c,c2)
    def test_completed_history_projection_replay(self):
        s=BridgeState('owned');g=s.begin();item={'id':'i','type':'agentMessage','text':'hello'}
        s.hydrate(g,{'id':'owned','turns':[{'id':'t','items':[item]}]})
        s.apply(g,{'method':'item/completed','params':{'threadId':'owned','turnId':'t','item':item}})
        self.assertEqual(len(s.snapshot()['messages']),1)
        s.disconnect(g);g2=s.begin();s.hydrate(g2,{'id':'owned','turns':[{'id':'t','items':[dict(item,text='updated')]}]})
        self.assertEqual(s.snapshot()['messages'][0]['text'],'updated')
        s.apply(g2,question());self.assertEqual(len(s.snapshot()['pending']),1) # silence does not rotate generation

    def test_resolved_controls_do_not_exhaust_pending_capacity(self):
        s=BridgeState('owned');g=s.begin();s.hydrate(g,{'id':'owned','turns':[]})
        for rid in range(40):
            s.apply(g,question(rid=rid,item=str(rid)))
            s.apply(g,{'method':'serverRequest/resolved','params':{'threadId':'owned','requestId':rid}})
        s.apply(g,question(rid=41,item='last'))
        self.assertIsNone(s.snapshot()['error']);self.assertEqual(len(s.snapshot()['pending']),1)

    def test_writer_rejection_does_not_leave_submitting(self):
        s,g,c=self.ready()
        def fail(message):raise ValueError('wire size')
        self.assertEqual(s.answer(c,OP,A,fail),'uncertain')
        self.assertEqual(s.answer(c,OP2,A,lambda m:None),'uncertain')

    def test_unicode_answer_is_bounded_before_reservation(self):
        import json
        s=BridgeState('owned');g=s.begin();s.hydrate(g,{'id':'owned','turns':[]})
        q=question();q['params']['questions'][0].pop('options');s.apply(g,q)
        c=s.snapshot()['pending'][0]['control_id'];w=[]
        self.assertEqual(s.answer(c,OP,{'q':{'answers':['界'*8000]}},w.append),'submitted')
        self.assertLess(len(json.dumps(w[0],ensure_ascii=False).encode()),65536)
        s2=BridgeState('owned');g2=s2.begin();s2.hydrate(g2,{'id':'owned','turns':[]});s2.apply(g2,q)
        c2=s2.snapshot()['pending'][0]['control_id']
        self.assertEqual(s2.answer(c2,OP,{'q':{'answers':['界'*8000]*3}},w.append),'rejected')
        self.assertEqual(s2.snapshot()['operations'],{})
