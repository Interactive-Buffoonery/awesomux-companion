import unittest
from dataclasses import replace
from codex_control_probe import ProbeClient


class ReplyChecks(unittest.TestCase):
    def test_reply_is_scoped_single_use_and_not_replayed(self):
        writes = []
        client = ProbeClient('owned', writes.append)
        request = {'id': 7, 'method': 'item/tool/requestUserInput', 'params': {
            'threadId': 'owned', 'turnId': 'turn', 'itemId': 'item',
            'isBlocking': True, 'questions': [{'id': 'choice', 'header': 'Choice',
            'question': 'Choose', 'options': [{'label': 'A', 'description': 'A'}]}]}}
        client.handle_message(request)
        ref = client.pending[7]
        result = {'answers': {'choice': {'answers': ['A']}}}
        self.assertEqual(client.reply(replace(ref, thread_id='foreign'), result), 'rejected')
        self.assertEqual(writes, [])
        self.assertEqual(client.reply(ref, result), 'sent')
        self.assertEqual(writes, [{'id': 7, 'result': result}])
        self.assertEqual(client.reply(ref, result), 'sent')
        self.assertEqual(len(writes), 1)
        client.disconnect()
        self.assertEqual(client.reply(ref, result), 'uncertain')
        client.handle_message(request)
        new_ref = client.pending[7]
        self.assertNotEqual(ref.connection_incarnation, new_ref.connection_incarnation)
        self.assertEqual(client.reply(ref, result), 'uncertain')
        client.handle_message({'method': 'serverRequest/resolved', 'params': {'threadId': 'owned', 'requestId': 7}})
        self.assertEqual(client.reply(new_ref, result), 'already_resolved')
        self.assertEqual(len(writes), 1)
        foreign = dict(request, params=dict(request['params'], threadId='foreign'))
        client.handle_message(foreign)
        self.assertEqual(client.pending, {})
        client.handle_message(dict(request, method='unknown'))
        self.assertEqual(client.pending, {})
        client.handle_message(dict(request, params=dict(request['params'], questions=[])))
        self.assertEqual(client.pending, {})

    def test_partial_write_is_uncertain_and_never_retried(self):
        attempts = []
        def failed_write(message):
            attempts.append(message)
            raise OSError('connection lost')
        client = ProbeClient('owned', failed_write)
        client.handle_message({'id': 'r', 'method': 'item/tool/requestUserInput', 'params': {
            'threadId': 'owned', 'turnId': 't', 'itemId': 'i', 'isBlocking': True,
            'questions': [{'id': 'q', 'header': 'Q', 'question': 'Q?'}]}})
        ref = client.pending['r']
        self.assertEqual(client.reply(ref, {'answers': {'q': {'answers': ['A']}}}), 'uncertain')
        self.assertEqual(client.reply(ref, {'answers': {'q': {'answers': ['A']}}}), 'uncertain')
        self.assertEqual(len(attempts), 1)

    def test_malformed_messages_and_answers_do_not_write(self):
        writes = []
        c = ProbeClient('owned', writes.append)
        params = dict(threadId='owned', turnId='t', itemId='i', isBlocking=True,
                      questions=[dict(id='q', header='Q', question='Q?', options=123)])
        c.handle_message(None)
        c.handle_message(dict(id=1, method='item/tool/requestUserInput', params=params))
        self.assertEqual(c.pending, {})
        params['questions'][0].pop('options')
        c.handle_message(dict(id=1, method='item/tool/requestUserInput', params=params))
        ref = c.pending[1]
        for rid in ([], True):
            c.handle_message(dict(method='serverRequest/resolved', params=dict(threadId='owned', requestId=rid)))
        for result in ({}, {'answers': {'wrong': {'answers': ['A']}}}, {'answers': {'q': {'answers': [1]}}}):
            self.assertEqual(c.reply(ref, result), 'rejected')
        self.assertEqual(writes, [])
        self.assertEqual(c.reply(ref, {'answers': {'q': {'answers': ['free text']}}}), 'sent')


if __name__ == '__main__':
    unittest.main()
