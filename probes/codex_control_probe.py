"""Local guards for an isolated Codex question probe; not a product bridge."""
from dataclasses import dataclass
from uuid import uuid4


@dataclass(frozen=True)
class PendingRequestRef:
    connection_incarnation: str
    request_id: str | int
    thread_id: str
    turn_id: str


class ProbeClient:
    def __init__(self, thread_id, write):
        self.thread_id = thread_id
        self.write = write
        self.incarnation = str(uuid4())
        self.pending = {}
        self.outcomes = {}
        self.question_ids = {}

    def handle_message(self, message):
        if not isinstance(message, dict):
            return
        params = message.get('params')
        if not isinstance(params, dict) or params.get('threadId') != self.thread_id:
            return
        if message.get('method') == 'serverRequest/resolved':
            rid = params.get('requestId')
            if type(rid) not in (str, int):
                return
            ref = self.pending.pop(rid, None)
            if ref:
                self.outcomes[ref] = 'already_resolved'
            return
        if message.get('method') != 'item/tool/requestUserInput':
            return
        rid = message.get('id')
        questions = params.get('questions')
        if (type(rid) not in (str, int) or not isinstance(params.get('turnId'), str)
                or not isinstance(params.get('itemId'), str)
                or not isinstance(params.get('isBlocking'), bool)
                or not isinstance(questions, list) or not questions
                or any(not isinstance(q, dict) or not all(isinstance(q.get(k), str)
                       for k in ('id', 'header', 'question')) for q in questions)):
            return
        ids = [q['id'] for q in questions]
        if any(not i for i in ids) or len(set(ids)) != len(ids):
            return
        for q in questions:
            options = q.get('options')
            if options is not None and (not isinstance(options, list) or not options or any(
                    not isinstance(o, dict) or not all(isinstance(o.get(k), str)
                    for k in ('label', 'description')) for o in options)):
                return
        ref = PendingRequestRef(self.incarnation, rid, self.thread_id, params['turnId'])
        if ref not in self.outcomes:
            self.pending[rid] = ref
            self.question_ids[ref] = set(ids)

    def reply(self, ref, result):
        if ref in self.outcomes:
            return self.outcomes[ref]
        if ref.connection_incarnation != self.incarnation or self.pending.get(ref.request_id) != ref:
            return 'rejected'
        answers = result.get('answers') if isinstance(result, dict) else None
        if not isinstance(answers, dict) or set(answers) != self.question_ids.get(ref):
            return 'rejected'
        if any(not isinstance(v, dict) or not isinstance(v.get('answers'), list)
               or not v['answers'] or any(not isinstance(a, str) for a in v['answers'])
               for v in answers.values()):
            return 'rejected'
        # Mark before writing: failed/partial writes are uncertain, never replayable.
        self.outcomes[ref] = 'uncertain'
        try:
            self.write({'id': ref.request_id, 'result': result})
        except (OSError, EOFError):
            return 'uncertain'
        self.outcomes[ref] = 'sent'
        return 'sent'

    def disconnect(self):
        for ref in self.pending.values():
            if self.outcomes.get(ref) == 'sent':
                self.outcomes[ref] = 'uncertain'
        self.pending.clear()
        self.incarnation = str(uuid4())
