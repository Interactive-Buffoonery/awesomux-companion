"""Golden fixtures consumed by native decoding tests; generated from real state."""
import json
import pathlib
import unittest
from state import BridgeState
from test_state import question

class NativeContractChecks(unittest.TestCase):
    def test_native_fixtures_match_state_projection(self):
        fixtures=pathlib.Path(__file__).resolve().parent.parent/'ios/Fixtures'
        s=BridgeState('fixture-thread');initial=s.snapshot();initial['updated_at']=1.5
        self.assertEqual(initial,json.loads((fixtures/'disconnected.json').read_text()))
        g=s.begin();s.hydrate(g,{'id':'fixture-thread','turns':[{'id':'turn','items':[{'id':'message','type':'agentMessage','text':'Which option would you like?'}]}]})
        q=question();q['params']['threadId']='fixture-thread';q['params']['questions'].append({'id':'detail','header':'Details','question':'Any details?','isOther':False,'isSecret':False,'options':None})
        s.apply(g,q);v=s.snapshot();v['generation']='fixture-generation';v['updated_at']=1.5;v['pending'][0]['control_id']='fixture-control'
        self.assertEqual(v,json.loads((fixtures/'pending.json').read_text()))

        control=s.snapshot()['pending'][0]['control_id']
        op='00000000-0000-4000-8000-000000000001'
        self.assertEqual(s.answer(control,op,{'q':{'answers':['A']},'detail':{'answers':['details']}},lambda message:None),'submitted')
        submitted=s.snapshot();submitted['generation']='fixture-generation';submitted['updated_at']=1.5;submitted['pending'][0]['control_id']='fixture-control'
        self.assertEqual(submitted,json.loads((fixtures/'submitted.json').read_text()))
