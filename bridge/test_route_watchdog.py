import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from route_watchdog import WatchedChild, process_identity

class WatchdogChecks(unittest.TestCase):
 def test_deadline_and_ignoring_term_child_are_bounded(self):
  for ignore in (False,True):
   code='import time,signal;'+('signal.signal(signal.SIGTERM,signal.SIG_IGN);' if ignore else '')+'time.sleep(30)'
   child=WatchedChild([sys.executable,'-c',code],time.monotonic()+2)
   self.assertIsNotNone(process_identity(child.child.pid))
   end=time.monotonic()+7
   while child.child.poll() is None and time.monotonic()<end:time.sleep(.05)
   self.assertIsNotNone(child.child.poll())
   child.close();self.assertIsNotNone(child.supervisor.poll())
 def test_supervisor_death_stops_owned_child(self):
  child=WatchedChild([sys.executable,'-c','import time;time.sleep(30)'],time.monotonic()+10)
  child.supervisor.kill();child.supervisor.wait(2)
  end=time.monotonic()+5
  while child.child.poll() is None and time.monotonic()<end:time.sleep(.05)
  self.assertIsNotNone(child.child.poll());child.close()
 def test_parent_sigkill_leaves_supervisor_to_stop_child(self):
  with tempfile.TemporaryDirectory(prefix='amx-watchdog-test-') as folder:
   ready=pathlib.Path(folder)/'ready.json'
   program="import sys,time,json;sys.path.insert(0,sys.argv[1]);from route_watchdog import WatchedChild;c=WatchedChild([sys.executable,'-c','import time;time.sleep(30)'],time.monotonic()+5);open(sys.argv[2],'w').write(json.dumps([c.child.pid,c.supervisor.pid]));time.sleep(30)"
   parent=subprocess.Popen([sys.executable,'-c',program,str(pathlib.Path(__file__).parent),str(ready)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   try:
    end=time.monotonic()+5
    while not ready.exists() and time.monotonic()<end:time.sleep(.05)
    self.assertTrue(ready.exists())
    import json
    child_pid,watcher_pid=json.loads(ready.read_text());identity=process_identity(child_pid)
    self.assertIsNotNone(identity)
    parent.kill();parent.wait(2)
    end=time.monotonic()+6
    while process_identity(child_pid)==identity and time.monotonic()<end:time.sleep(.05)
    self.assertNotEqual(process_identity(child_pid),identity)
   finally:
    if parent.poll() is None:parent.kill();parent.wait(2)
 def test_missing_readiness_stops_child_before_returning(self):
  from unittest.mock import patch
  from route_watchdog import WatchdogFailure
  actual=subprocess.Popen;created=[]
  def record(*args,**kwargs):
   process=actual(*args,**kwargs);created.append(process);return process
  with patch('route_watchdog.subprocess.Popen',side_effect=record):
   with self.assertRaises(WatchdogFailure):
    WatchedChild([sys.executable,'-c','import time;time.sleep(30)'],time.monotonic()+10,supervisor_command=[sys.executable,'-c','pass'])
  self.assertEqual(len(created),2)
  self.assertTrue(all(process.poll() is not None for process in created))
 def test_supervisor_payload_broken_pipe_is_typed_and_children_stopped(self):
  from unittest.mock import patch
  from route_watchdog import WatchdogFailure
  actual=subprocess.Popen;created=[]
  def record(*args,**kwargs):
   process=actual(*args,**kwargs);created.append(process);return process
  with patch('route_watchdog.subprocess.Popen',side_effect=record),patch('route_watchdog.os.write',side_effect=BrokenPipeError()):
   with self.assertRaises(WatchdogFailure):
    WatchedChild([sys.executable,'-c','import time;time.sleep(30)'],time.monotonic()+10)
  self.assertTrue(all(process.poll() is not None for process in created))
