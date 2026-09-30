# SPDX-License-Identifier: GPL-3.0-or-later
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('sweep',ROOT/'racemenu_sweep.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def state():
    return dict(schema=1,status='ready',generation=1,mode=0,
                races=[dict(id=1,name='Nord',enabled=True,active=True),dict(id=2,name='Argonian',enabled=True,active=False)],
                sliders=[dict(id=10,slot=0,callback='ChangeWeight',action='set-slider',enabled=True,
                              minimum=0,maximum=1,step=.3,value=.3)])


class Fake:
    def __init__(self,mode='normal'):
        self.s = state()
        self.mode = mode
        self.calls=[]
        self.frame=0
    def refresh(self,deadline):
        if self.mode=='pending':
            return dict(self.s,status='race-change-pending')
        return copy.deepcopy(self.s)
    def mutate(self,action,deadline):
        self.calls.append(action)
        if self.mode=='reject':
            return dict(ok=False,code='stale-generation',generation=1)
        if self.mode=='lost':
            raise m.StopSweep('lost response')
        if action['kind']=='race' and self.mode!='unchanged':
            self.s['generation']+=1
            for r in self.s['races']: r['active']=r['id']==action['raceId']
        elif action['kind'] in ('slider','sex'):
            self.s['sliders'][0]['value']=action['value']
            if action['kind']=='sex': self.s['generation']+=1
        return dict(ok=True,code='dispatched',generation=self.s['generation'])
    def observe(self,deadline):
        if self.mode!='frozen': self.frame+=1
        return dict(game=dict(value=dict(playerLoaded=True,frame=self.frame)),recording=dict(value=dict(recording=True)))


class Unit(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.trace=m.Trace(Path(self.temp.name)/'trace')
    def tearDown(self):
        self.trace.close()
        self.temp.cleanup()
    def run_fake(self, fake, phase='human-beast-alternation', count=2, **kw):
        return m.Sweep(fake,self.trace,phase,count,phase_seconds=1,settle_seconds=.05,
                       pace=0,poll=.001,race_ids=[1,2],**kw).run()
    def test_alternation_and_unique_intents(self):
        fake=Fake()
        result=self.run_fake(fake)
        self.assertTrue(result['ok'])
        self.assertEqual([a['raceId'] for a in fake.calls],[2,1])
        self.assertEqual([a['generation'] for a in fake.calls],[1,2])
    def test_rejection_not_replayed(self):
        fake=Fake('reject')
        with self.assertRaises(m.StopSweep): self.run_fake(fake)
        self.assertEqual(len(fake.calls),1)
    def test_lost_response_not_replayed(self):
        fake=Fake('lost')
        with self.assertRaises(m.StopSweep): self.run_fake(fake)
        self.assertEqual(len(fake.calls),1)
    def test_pending_is_bounded_and_no_mutation(self):
        fake=Fake('pending')
        started=time.monotonic()
        with self.assertRaises(m.StopSweep): self.run_fake(fake)
        self.assertLess(time.monotonic()-started,.3)
        self.assertEqual(fake.calls,[])
    def test_dispatch_is_not_state_completion(self):
        fake=Fake('unchanged')
        with self.assertRaises(m.StopSweep): self.run_fake(fake)
        self.assertEqual(len(fake.calls),1)
    def test_frozen_frame_stops(self):
        fake=Fake('frozen')
        with self.assertRaises(m.StopSweep): self.run_fake(fake)
        self.assertEqual(len(fake.calls),1)
    def test_slider_targets_on_live_lattice(self):
        self.assertEqual(m.legal_targets(state()['sliders'][0]),[0,.8999999999999999])
        fake=Fake()
        result=self.run_fake(fake,phase='race-slider-cross-product',count=3)
        self.assertEqual(result['completedChanges'],3)
        self.assertEqual([a['kind'] for a in fake.calls],['slider','slider','race'])
    def test_bool_or_malformed_snapshot_refused(self):
        for key,value in [('generation',True),('mode',False)]:
            s=state();s[key]=value
            with self.assertRaises(m.StopSweep): m.snapshot(s)
        s=state();s['races'][1]['active']=True
        with self.assertRaises(m.StopSweep): m.snapshot(s)
    def test_disabled_race_refused(self):
        fake=Fake();fake.s['races'][1]['enabled']=False
        with self.assertRaises(m.StopSweep): self.run_fake(fake)
        self.assertEqual(fake.calls,[])
    def test_nonready_tab_not_polled(self):
        fake=Fake();fake.s['status']='sliders-tab-inactive'
        with self.assertRaises(m.StopSweep): self.run_fake(fake)
        self.assertEqual(fake.calls,[])
    def test_stop_signal_prevents_calls(self):
        stop=Path(self.temp.name)/'stop';stop.touch()
        fake=Fake()
        with self.assertRaises(m.StopSweep): self.run_fake(fake,stop_file=stop)
        self.assertEqual(fake.calls,[])
    def test_trace_refuses_existing_directory(self):
        with self.assertRaises(FileExistsError): m.Trace(self.trace.directory)


class Entrypoint(unittest.TestCase):
    def test_production_entrypoint_and_adapter_policy(self):
        pwsh=shutil.which('pwsh')
        if not pwsh: self.skipTest('PowerShell unavailable')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            capture=root/'capture-interaction-control';capture.mkdir()
            devbench=root/'devbench-control';devbench.mkdir()
            for dest in (capture/'Invoke-CaptureInteraction.ps1',devbench/'Invoke-DevBenchControl.ps1'):
                shutil.copyfile(ROOT/'tests'/'fixture.ps1',dest)
            model=state();model['frame']=0;model['mutations']=0
            model_path=root/'model.json';model_path.write_text(json.dumps(model))
            identity=dict(listenerPid=1,processPath='fixture.exe',processStartTimeUtc='fixture',
                          buildId='fixture',artifactPath='fixture.dll',artifactSha256='a'*64)
            session=root/'session.json'
            session.write_text(json.dumps(dict(contractVersion='1.0.0',status='active',sessionId='fixture',
                               sessionDirectory=str(root),runtimeIdentity=identity,modelPath=str(model_path))))
            protocol=root/'protocol.json'
            protocol.write_text(json.dumps(dict(limits=dict(maximumInputRequestsInFlight=1,mutationRetries=0,
                                     phaseDeadlineSeconds=900,menuSettleDeadlineSeconds=30),
                                     phases=[dict(id='qualification',maximumChanges=20)])))
            evidence=root/'evidence.txt';evidence.write_text('fixture qualification only')
            qualification=root/'qualification.json'
            qualification.write_text(json.dumps(dict(schema='racemenu-sweep-qualification-v1',sessionId='fixture',
                     runtimeIdentity=identity,protocolSha256=m.sha(protocol),checks={key:True for key in m.CHECKS},
                     evidence=[dict(path=str(evidence),sha256=m.sha(evidence))])))
            argv=[sys.executable,'-B',str(ROOT/'racemenu_sweep.py'),'--capture-session',str(session),
                  '--capture-controller',str(capture/'Invoke-CaptureInteraction.ps1'),
                  '--pwsh',pwsh,'--confirm-existing-capture-lane','--protocol',str(protocol),
                  '--qualification',str(qualification),'--output',str(root/'run'),
                  '--phase','qualification','--maximum-changes','1','--pace-seconds','0']
            result=subprocess.run(argv,capture_output=True,text=True,timeout=50)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            receipt=json.loads(result.stdout)
            self.assertEqual(receipt['completedChanges'],1)
            model=json.loads(model_path.read_text(encoding='utf-8-sig'))
            self.assertEqual(model['mutations'],1)
            self.assertEqual(model['retries'],0)
            self.assertLessEqual(model['timeout'],30)
            self.assertFalse((root/'.racemenu-sweep.lock').exists())
            entries=[json.loads(line) for line in (root/'run'/'trace.ndjson').read_text().splitlines()]
            self.assertEqual(sum(e['kind']=='mutation-intent' for e in entries),1)
            self.assertEqual(sum(e['kind']=='mutation-menu-verified' for e in entries),1)
            # A repeated production entry point refuses reuse before any actor mutation.
            again=subprocess.run(argv,capture_output=True,text=True,timeout=10)
            self.assertEqual(again.returncode,2)
            self.assertEqual(json.loads(model_path.read_text(encoding='utf-8-sig'))['mutations'],1)
            # Exercise bounded cancellation through the real entry point, not
            # merely a mocked watchdog. The owned worker sleeps without progress.
            model['hang']=True
            model_path.write_text(json.dumps(model))
            blocked=argv.copy()
            blocked[blocked.index(str(root/'run'))]=str(root/'hung-run')
            blocked += ['--call-seconds','0.2']
            started=time.monotonic()
            cancelled=subprocess.run(blocked,capture_output=True,text=True,timeout=5)
            self.assertEqual(cancelled.returncode,2,cancelled.stdout+cancelled.stderr)
            self.assertLess(time.monotonic()-started,4)
            self.assertFalse((root/'.racemenu-sweep.lock').exists())
            self.assertEqual(json.loads(model_path.read_text(encoding='utf-8-sig'))['mutations'],1)
            self.assertEqual(json.loads((root/'run'/'receipt.json').read_text()),receipt)
            stopped=json.loads(cancelled.stdout)
            self.assertFalse(stopped['ok'])
            self.assertIn('timed out',stopped['error'])


if __name__=='__main__': unittest.main(verbosity=2)
