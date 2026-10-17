import copy
import unittest
from private_route import choose_port, canonical_dns, verify_owned_entry, verify_cleanup, RouteFailure

DNS='mac.example.ts.net'
def owned(port=8443,target=43210):
 return {'TCP':{str(port):{'HTTPS':True}},'Web':{f'{DNS}:{port}':{'Handlers':{'/':{'Proxy':f'http://127.0.0.1:{target}'}}}}}
class RouteContracts(unittest.TestCase):
 def test_occupied_anywhere_and_funnel_without_handler(self):
  for config in [{'TCP':{'8443':{'HTTPS':True}}},{'Web':{DNS+':8443':{}}},{'AllowFunnel':{DNS+':8443':False}},{'Foreground':{'other':owned()}}]:
   self.assertEqual(choose_port(config),10000)
  with self.assertRaises(RouteFailure):choose_port({'TCP':{'8443':{},'10000':{}}})
  with self.assertRaises(RouteFailure):choose_port({'Unknown':{}})
 def test_dns_is_canonical_and_private(self):
  self.assertEqual(canonical_dns(DNS+'.'),DNS)
  for name in ['MAC.example.ts.net','mac.ts.net','mac.example.net','mac..example.ts.net','-mac.example.ts.net','127.0.0.1','mac%2eexample.ts.net']:
   with self.assertRaises(RouteFailure):canonical_dns(name)
 def test_only_one_new_exact_foreground_entry_and_baseline_preserved(self):
  base={'TCP':{'443':{'HTTPS':True}},'Foreground':{'other':owned(10000)}}
  new=copy.deepcopy(base);new['Foreground']['ours']=owned()
  self.assertEqual(verify_owned_entry(base,new,DNS,8443,43210),'ours')
  for mutation in ['background','target','funnel','second','old']:
   bad=copy.deepcopy(new)
   if mutation=='background':bad['TCP']['443']['HTTPS']=False
   if mutation=='target':bad['Foreground']['ours']=owned(target=43211)
   if mutation=='funnel':bad['AllowFunnel']={DNS+':8443':True}
   if mutation=='second':bad['Foreground']['extra']=owned(12345)
   if mutation=='old':bad['Foreground']['other']=owned(10001)
   with self.assertRaises(RouteFailure):verify_owned_entry(base,bad,DNS,8443,43210)
  self.assertTrue(verify_cleanup(base,base,'ours',8443))
  self.assertFalse(verify_cleanup(base,new,'ours',8443))
  altered=copy.deepcopy(base);altered['TCP']['443']['HTTPS']=False
  self.assertFalse(verify_cleanup(base,altered,'ours',8443))

from private_route import PrivateRoute
class FakeCLI:
 def __init__(self,before,after):self.before=copy.deepcopy(before);self.after=copy.deepcopy(after);self.current=self.before;self.commands=[];self.reads=0
 def preflight(self):return DNS,copy.deepcopy(self.before),choose_port(self.before)
 def status(self):self.reads+=1;return copy.deepcopy(self.current)
 def command(self,port,backend):
  self.commands.append((port,backend));return ['fake-serve']
class FakeWatcher:
 def __init__(self,cli):self.cli=cli;self.alive=True;cli.current=cli.after
 def close(self):self.alive=False;self.cli.current=self.cli.before
class RouteLifecycle(unittest.TestCase):
 def test_owned_foreground_start_close_without_whole_config_reset(self):
  before={'TCP':{'443':{'HTTPS':True}}};after=copy.deepcopy(before);after['Foreground']={'ours':owned()}
  cli=FakeCLI(before,after)
  route=PrivateRoute(cli=cli,watcher_factory=lambda command,deadline,env:FakeWatcher(cli))
  self.assertEqual(route.prepare(),f'https://{DNS}:8443')
  self.assertEqual(route.start(43210,DNS),f'https://{DNS}:8443')
  self.assertTrue(route.alive)
  self.assertEqual(route.close(),{'owned_process_stopped':True,'owned_route_absent':True,'unrelated_routes_preserved':True})
  self.assertEqual(cli.commands,[(8443,43210)])
 def test_start_readback_conflict_stops_only_owned_watcher(self):
  before={'TCP':{'443':{'HTTPS':True}}};after=copy.deepcopy(before);after['TCP']['443']['HTTPS']=False;after['Foreground']={'ours':owned()}
  cli=FakeCLI(before,after);watchers=[]
  def factory(*args,**kwargs):
   watcher=FakeWatcher(cli);watchers.append(watcher);return watcher
  route=PrivateRoute(cli=cli,watcher_factory=factory);route.prepare()
  with self.assertRaises(RouteFailure):route.start(43210,DNS)
  self.assertFalse(watchers[0].alive)
 def test_prepared_baseline_change_and_wrong_dns_fail_before_start(self):
  cli=FakeCLI({}, {'Foreground':{'ours':owned()}})
  route=PrivateRoute(cli=cli,watcher_factory=lambda *args,**kwargs:self.fail('must not launch'))
  route.prepare();cli.before={'TCP':{'8443':{}}}
  with self.assertRaises(RouteFailure):route.start(43210,DNS)
  self.assertEqual(cli.commands,[])
 def test_failed_cli_start_and_foreign_change_remain_untouched(self):
  cli=FakeCLI({}, {'Foreground':{'ours':owned()}})
  def failed(*args,**kwargs):raise RouteFailure('ETag precondition rejected')
  route=PrivateRoute(cli=cli,watcher_factory=failed);route.prepare()
  with self.assertRaises(RouteFailure):route.start(43210,DNS)
  self.assertEqual(cli.current,{})
  self.assertTrue(route.close()['unrelated_routes_preserved'])
  cli=FakeCLI({}, {'Foreground':{'ours':owned()}})
  class ChangedAfterClose(FakeWatcher):
   def close(self):self.alive=False;self.cli.current={'TCP':{'10000':{'HTTPS':True}}}
  route=PrivateRoute(cli=cli,watcher_factory=lambda *args,**kwargs:ChangedAfterClose(cli));route.prepare();route.start(43210,DNS)
  cleanup=route.close()
  self.assertTrue(cleanup['owned_route_absent']);self.assertFalse(cleanup['unrelated_routes_preserved'])
  self.assertEqual(cli.current,{'TCP':{'10000':{'HTTPS':True}}})

class ExecutableOwnership(unittest.TestCase):
 def test_shell_wrapper_rejected_and_symlink_resolves_binary(self):
  import pathlib,tempfile,subprocess
  from private_route import TailscaleCLI
  folder=pathlib.Path(tempfile.mkdtemp(prefix='amx-route-executable-test-',dir='/private/tmp'))
  try:
   wrapper=folder/'wrapper';wrapper.write_text('#!/bin/sh\n/bin/sleep 30\n');wrapper.chmod(0o700)
   with self.assertRaises(RouteFailure):TailscaleCLI(str(wrapper))
   binary=folder/'binary';binary.write_bytes(bytes.fromhex('cffaedfe')+b'fake binary');binary.chmod(0o700)
   link=folder/'link';link.symlink_to(binary)
   self.assertEqual(TailscaleCLI(str(link)).command(8443,43210)[0],str(binary.resolve()))
   binary.write_text('#!/bin/sh\n/bin/sleep 30\n')
   with self.assertRaises(RouteFailure):TailscaleCLI(str(link)).command(8443,43210)
  finally:subprocess.run(['trash',str(folder)],check=True,capture_output=True)
