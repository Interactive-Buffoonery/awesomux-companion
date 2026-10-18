"""Integration checks against an isolated zmx session, no real user data."""
import base64
from concurrent.futures import ThreadPoolExecutor
import importlib.util
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlencode

def check(condition):
    if not condition:
        raise AssertionError("fixture verification failed")


module_path = Path(__file__).with_name('fixture_server.py')
spec = importlib.util.spec_from_file_location('fixture_server', module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
fixture = module.Fixture(sys.argv[1], tempfile.mkdtemp(prefix='watch-fixture-test-', dir='/tmp'))
try:
    # More history than the event queue retains must require a fresh snapshot.
    for i in range(260):
        with fixture.lock:
            fixture.emit(f'\r\nCUT{fixture.sequence + 1:06d}'.encode())
    query = urlencode({'runID': fixture.run_id, 'after': 0})
    check(fixture.response('/events?' + query)[0] == 409)
    status, snapshot = fixture.response('/snapshot')
    check(status == 200 and f'CUT{snapshot["sequence"]:06d}'.encode() in base64.b64decode(snapshot['dataBase64']))
    oldest = fixture.events[0]['sequence']
    for after, expected in [(oldest - 1, 200), (oldest - 2, 409)]:
        check(fixture.response('/events?' + urlencode({'runID': fixture.run_id, 'after': after}))[0] == expected)

    # Concurrent snapshots and emissions share the same cut in the event stream.
    def produce():
        for i in range(20):
            with fixture.lock:
                fixture.emit(f'\r\nCUT{fixture.sequence + 1:06d}'.encode())

    def observe():
        for _ in range(10):
            status, snap = fixture.response('/snapshot')
            check(status == 200)
            rendered = base64.b64decode(snap['dataBase64'])
            check(f'CUT{snap["sequence"]:06d}'.encode() in rendered)
            check(f'CUT{snap["sequence"] + 1:06d}'.encode() not in rendered)
            status, events = fixture.response('/events?' + urlencode({
                'runID': snap['runID'], 'after': snap['sequence']}))
            check(status == 200)
            sequences = [event['sequence'] for event in events['events']]
            check(sequences == list(range(snap['sequence'] + 1, snap['sequence'] + 1 + len(sequences))))

    with ThreadPoolExecutor(max_workers=3) as pool:
        jobs = [pool.submit(produce), pool.submit(observe), pool.submit(observe)]
        for job in jobs:
            job.result()
    print('PASS: queue eviction requires snapshot; concurrent snapshot/event cuts remain contiguous')
finally:
    fixture.close()
