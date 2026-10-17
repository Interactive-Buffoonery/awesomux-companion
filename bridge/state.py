"""One-thread foreground projection. No transport or credentials live here."""
import copy
import hashlib
import json
import secrets
import threading
import time
import uuid
from collections import OrderedDict

class BridgeState:
    def __init__(self, thread_id):
        self.thread_id = thread_id
        self.lock = threading.RLock()
        self.generation = None
        self.connected = False
        self.messages = OrderedDict()
        self.controls = {}
        self.operations = {}
        self.uncertain_items = set()
        self.unsupported = False
        self.error = None
        self.updated = time.time()

    def begin(self):
        with self.lock:
            if self.generation:
                self.disconnect(self.generation)
            self.generation = secrets.token_urlsafe(24)
            self.connected = False
            self.controls = {}
            self.error = None
            return self.generation

    def hydrate(self, generation, thread):
        with self.lock:
            if generation != self.generation:
                return
            if not isinstance(thread, dict) or thread.get('id') != self.thread_id or not isinstance(thread.get('turns'), list):
                raise ValueError('invalid thread projection')
            self.messages.clear()
            for turn in thread['turns']:
                if not isinstance(turn, dict) or not isinstance(turn.get('id'), str) or not isinstance(turn.get('items'), list):
                    raise ValueError('invalid turn projection')
                for item in turn['items']:
                    self._project(turn['id'], item)
            self.connected = True
            self.updated = time.time()

    def _project(self, turn_id, item):
        if not isinstance(item, dict) or not isinstance(item.get('id'), str):
            return
        kind = item.get('type')
        if kind == 'agentMessage':
            text = item.get('text')
        elif kind == 'userMessage' and isinstance(item.get('content'), list):
            text = '\n'.join(v['text'] for v in item['content'] if isinstance(v, dict) and v.get('type') == 'text' and isinstance(v.get('text'), str))
        else:
            return
        if not isinstance(text, str):
            return
        key = (turn_id, item['id'])
        self.messages[key] = {'id': item['id'], 'turn_id': turn_id, 'role': 'assistant' if kind == 'agentMessage' else 'user', 'text': text[:16384], 'truncated': len(text) > 16384}
        while len(self.messages) > 200:
            self.messages.popitem(last=False)

    @staticmethod
    def _questions(value):
        if not isinstance(value, list) or not value or len(value) > 32:
            return None
        ids = set()
        for q in value:
            if not isinstance(q, dict) or any(not isinstance(q.get(k), str) or not q[k] or len(q[k]) > 8192 for k in ('id', 'header', 'question')):
                return None
            if q['id'] in ids:
                return None
            ids.add(q['id'])
            if any(k in q and not isinstance(q[k], bool) for k in ('isOther', 'isSecret')) or q.get('isSecret', False):
                return None
            options = q.get('options')
            if options is not None and (not isinstance(options, list) or not options or len(options) > 32 or any(not isinstance(o, dict) or any(not isinstance(o.get(k), str) or not o[k] or len(o[k]) > 8192 for k in ('label','description')) for o in options)):
                return None
        return copy.deepcopy(value)

    def apply(self, generation, message):
        with self.lock:
            if generation != self.generation or not isinstance(message, dict):
                return
            p = message.get('params')
            if not isinstance(p, dict) or p.get('threadId') != self.thread_id:
                return
            method = message.get('method')
            self.updated = time.time()
            if method == 'serverRequest/resolved':
                rid = p.get('requestId')
                if type(rid) not in (str,int):
                    return
                for cid,c in list(self.controls.items()):
                    if type(c['request_id']) is type(rid) and c['request_id'] == rid:
                        c['status'] = 'resolved'
                        if c['operation']:
                            self.operations[c['operation']]['status'] = 'resolved'
                        self.controls.pop(cid, None)
                return
            if method == 'item/completed' and isinstance(p.get('turnId'), str):
                self._project(p['turnId'], p.get('item'))
                return
            if method != 'item/tool/requestUserInput':
                if 'id' in message:
                    self.unsupported = True
                return
            questions = self._questions(p.get('questions'))
            if type(message.get('id')) not in (str,int) or not isinstance(p.get('turnId'), str) or not isinstance(p.get('itemId'), str) or not isinstance(p.get('isBlocking'), bool) or questions is None:
                self.unsupported = True
                return
            rid = message['id']
            for c in self.controls.values():
                if type(c['request_id']) is type(rid) and c['request_id'] == rid:
                    return
            if len(self.controls) >= 32:
                self.error = 'pending_capacity'
                return
            logical = (p['turnId'],p['itemId'])
            self.controls[secrets.token_urlsafe(24)] = {'request_id':rid,'logical':logical,'questions':questions,'status':'pending','operation':None,'prior_attempt_uncertain':logical in self.uncertain_items}

    @staticmethod
    def _valid_answers(questions, answers):
        if not isinstance(answers, dict) or set(answers) != {q['id'] for q in questions}:
            return False
        for q in questions:
            value = answers[q['id']]
            if not isinstance(value, dict) or set(value) != {'answers'} or not isinstance(value['answers'], list) or not value['answers'] or len(value['answers']) > 32:
                return False
            if any(not isinstance(a, str) or not a or len(a) > 8192 for a in value['answers']):
                return False
            if q.get('options') and not q.get('isOther',False) and any(a not in {o['label'] for o in q['options']} for a in value['answers']):
                return False
        return True

    def answer(self, control_id, operation_id, answers, write, confirm_uncertain=False, expected_generation=None):
        if not isinstance(control_id, str) or not isinstance(operation_id, str):
            return 'rejected'
        try:
            if str(uuid.UUID(operation_id)) != operation_id:
                return 'rejected'
        except ValueError:
            return 'rejected'
        with self.lock:
            if expected_generation is not None and expected_generation != self.generation:
                return "rejected"
            if not isinstance(answers, dict):
                return 'rejected'
            digest = hashlib.sha256(json.dumps(answers,sort_keys=True,separators=(',',':')).encode()).hexdigest()
            old = self.operations.get(operation_id)
            if old:
                return old['status'] if old['control']==control_id and old['digest']==digest else 'conflict'
            c = self.controls.get(control_id)
            if c is None or not self._valid_answers(c['questions'],answers):
                return 'rejected'
            wire = {'id':c['request_id'],'result':{'answers':copy.deepcopy(answers)}}
            if len((json.dumps(wire,ensure_ascii=False,separators=(',',':'))+'\n').encode()) > 65536:
                return 'rejected'
            if c['status'] == 'resolved':
                return 'resolved'
            if c['operation']:
                return 'uncertain' if c['status']=='uncertain' else 'already_submitted'
            if not self.connected or self.error:
                return 'disconnected'
            if c['prior_attempt_uncertain'] and not confirm_uncertain:
                return 'confirmation_required'
            if len(self.operations) >= 256:
                self.error = 'operation_capacity'
                return 'capacity'
            generation = self.generation
            c['operation'] = operation_id
            c['status'] = 'submitting'
            op = {'control':control_id,'digest':digest,'status':'submitting','generation':generation,'logical':c['logical']}
            self.operations[operation_id] = op
            wire = {'id':c['request_id'],'result':{'answers':copy.deepcopy(answers)}}
        outcome = 'submitted'
        try:
            write(wire)
        except (OSError,EOFError,TimeoutError,ValueError):
            outcome = 'uncertain'
        with self.lock:
            if op['status']=='resolved':
                return 'resolved'
            if generation != self.generation or not self.connected or op['status']=='uncertain':
                outcome = 'uncertain'
            op['status'] = outcome
            if generation == self.generation:
                c['status'] = outcome
            if outcome=='uncertain':
                self.uncertain_items.add(c['logical'])
            return outcome

    def disconnect(self, generation):
        with self.lock:
            if generation != self.generation:
                return
            self.connected = False
            for op in self.operations.values():
                if op['generation']==generation and op['status'] in ('submitting','submitted'):
                    op['status']='uncertain'
                    self.uncertain_items.add(op['logical'])
            self.controls.clear()
            self.updated = time.time()

    def snapshot(self):
        with self.lock:
            pending=[]
            if self.connected and not self.error:
                for cid,c in self.controls.items():
                    if c['status']!='resolved':
                        pending.append({'control_id':cid,'questions':copy.deepcopy(c['questions']),'status':c['status'],'prior_attempt_uncertain':c['prior_attempt_uncertain']})
            return {'thread_id':self.thread_id,'generation':self.generation,'connected':self.connected,'updated_at':self.updated,'messages':copy.deepcopy(list(self.messages.values())),'pending':pending,'operations':{k:v['status'] for k,v in self.operations.items()},'error':self.error,'unsupported_request':self.unsupported,'capabilities':{'completed_text_only':True,'recent_history_only':True,'questions':True,'approvals':False,'secret_questions':False}}
