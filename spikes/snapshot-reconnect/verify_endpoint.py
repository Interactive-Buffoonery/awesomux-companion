"""Exercise a running fixture endpoint using its private connection.json."""
import hashlib
import http.client
import json
from pathlib import Path
import ssl
import sys
import time
from urllib.parse import urlencode, urlsplit

def check(condition):
    if not condition:
        raise AssertionError("fixture verification failed")


config = json.loads(Path(sys.argv[1]).read_text())
address = urlsplit(config['url'])
context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE
context.minimum_version = ssl.TLSVersion.TLSv1_2


def get(path, token=None):
    connection = http.client.HTTPSConnection(address.hostname, address.port, context=context, timeout=5)
    connection.connect()
    # The private fixture uses exact DER pinning, never accept arbitrary certificates.
    actual = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
    if actual != config['pin']:
        connection.close()
        raise ValueError('fixture certificate pin mismatch')
    connection.request('GET', path, headers={'Authorization': 'Bearer ' + (token or config['token'])})
    response = connection.getresponse()
    body = response.read(256 * 1024 + 1)
    check(len(body) <= 256 * 1024)
    status = response.status
    connection.close()
    return status, json.loads(body)


check(get('/snapshot', token='invalid')[0] == 401)
status, snapshot = get('/snapshot')
check(status == 200 and snapshot['kind'] == 'snapshot')
check((snapshot['columns'], snapshot['rows']) == (20, 6))
time.sleep(2.2)
query = urlencode({'runID': snapshot['runID'], 'after': snapshot['sequence']})
status, events = get('/events?' + query)
check(status == 200 and events['kind'] == 'events')
check(events['runID'] == snapshot['runID'])
check(len(events['events']) >= 2)
check([e['sequence'] for e in events['events']] == list(range(snapshot['sequence'] + 1, snapshot['sequence'] + len(events['events']) + 1)))
check(get('/events?' + urlencode({'runID': 'old-generation', 'after': 0}))[0] == 409)
check(get('/events?' + urlencode({'runID': snapshot['runID'], 'after': 999999}))[0] == 409)
check(get('/events?' + urlencode({'runID': snapshot['runID'], 'after': 'bad'}))[0] == 400)
check(get('/events?after=0')[0] == 400)
check(get('/other')[0] == 404)
status, resumed = get('/snapshot')
check(status == 200 and resumed['sequence'] >= events['events'][-1]['sequence'])
report = {'endpoint': config['url'], 'authorizationRejection': 'passed',
          'snapshotThenContiguousEvents': 'passed', 'generationRejection': 'passed',
          'futureSequenceRejection': 'passed', 'freshReconnectSnapshot': 'passed',
          'snapshotSequence': snapshot['sequence'], 'resumedSequence': resumed['sequence'],
          'eventCount': len(events['events'])}
print(json.dumps(report, indent=2))
