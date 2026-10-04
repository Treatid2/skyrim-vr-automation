# SPDX-License-Identifier: GPL-3.0-or-later
import copy
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('sweep',ROOT/'racemenu_sweep.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class BinaryStdout:
    """Actual-main tests capture the public binary UTF-8 terminal contract."""
    def __init__(self):self.buffer=io.BytesIO()
    def getvalue(self):return self.buffer.getvalue().decode('utf-8')


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
    def test_cli_terminal_faults_always_attempt_own_cleanup_and_report(self):
        original_open, original_unlink = Path.open, Path.unlink
        original_write, original_close, original_fsync, original_link = m.Trace.write, m.Trace.close, m.os.fsync, m.os.link
        for fault in ('none','trace-write','trace-close','receipt-open','receipt-write','receipt-flush','receipt-fsync','receipt-close','receipt-publish','audit-open','audit-close','audit-update','candidate-cleanup','lock-close','lock-unlink'):
            for earlier_error in (False, True):
                with self.subTest(fault=fault,earlier_error=earlier_error):
                    folder=Path(self.temp.name)/f'final-{fault}-{earlier_error}'
                    folder.mkdir()
                    session=folder/'session';session.mkdir()
                    output=folder/'output'
                    protocol=folder/'protocol.json'
                    protocol.write_text(json.dumps(dict(limits=dict(maximumInputRequestsInFlight=1,mutationRetries=0,phaseDeadlineSeconds=900,menuSettleDeadlineSeconds=30),phases=[dict(id='qualification',maximumChanges=20)])))
                    events=[]
                    receipt_fd=[None]
                    class FileProxy:
                        def __init__(self,stream,kind):self.stream,self.kind=stream,kind
                        def __getattr__(self,name):return getattr(self.stream,name)
                        def __enter__(self):return self
                        def __exit__(self,*unused):self.close()
                        def write(self,value):
                            if self.kind=='receipt' and fault=='receipt-write':raise OSError('injected receipt write')
                            return self.stream.write(value)
                        def flush(self):
                            if self.kind=='receipt' and fault=='receipt-flush':raise OSError('injected receipt flush')
                            return self.stream.flush()
                        def close(self):
                            events.append(self.kind+'-close')
                            self.stream.close()
                            if fault==self.kind+'-close':raise OSError('injected '+self.kind+' close')
                    def faulty_open(path,*args,**kwargs):
                        if path.name.startswith('receipt.candidate-'):
                            if fault=='receipt-open':raise OSError('injected receipt open')
                            stream=original_open(path,*args,**kwargs);receipt_fd[0]=stream.fileno()
                            return FileProxy(stream,'receipt')
                        if path.name.startswith('receipt.pending-'):
                            if fault=='audit-open':raise OSError('injected audit open')
                            if args[0]=='w' and fault=='audit-update':raise OSError('injected audit update')
                            return FileProxy(original_open(path,*args,**kwargs),'audit')
                        if path.name=='.racemenu-sweep.lock':return FileProxy(original_open(path,*args,**kwargs),'lock')
                        return original_open(path,*args,**kwargs)
                    def faulty_unlink(path,*args,**kwargs):
                        if path.name.startswith('receipt.candidate-') and fault=='candidate-cleanup':
                            raise OSError('injected candidate cleanup')
                        if path.name=='.racemenu-sweep.lock':
                            events.append('lock-unlink')
                            if fault=='lock-unlink':raise OSError('injected lock unlink')
                        return original_unlink(path,*args,**kwargs)
                    def faulty_trace_write(trace,kind,**values):
                        if kind=='terminal' and fault=='trace-write':raise OSError('injected terminal trace')
                        return original_write(trace,kind,**values)
                    def faulty_trace_close(trace):
                        events.append('trace-close');original_close(trace)
                        if fault=='trace-close':raise OSError('injected trace close')
                    def faulty_fsync(fd):
                        if receipt_fd[0] is not None and fd==receipt_fd[0] and fault=='receipt-fsync':raise OSError('injected receipt fsync')
                        return original_fsync(fd)
                    def faulty_link(source,destination):
                        if fault in ('receipt-publish','audit-update','candidate-cleanup'):raise OSError('injected receipt publication')
                        return original_link(source,destination)
                    class Adapter:
                        state=dict(sessionDirectory=str(session))
                    class CompletedSweep:
                        completed=3
                        def __init__(self,*args,**kwargs):pass
                        def run(self):
                            events.append('single-sweep-run')
                            if earlier_error:raise m.StopSweep('original sweep failure')
                            return dict(ok=True,state='bounded-count-completed',completedChanges=3)
                    argv=['--capture-session','retained-session','--capture-controller',str(ROOT/'Invoke-SweepDevBench.ps1'),'--confirm-existing-capture-lane','--pwsh','fixture-only','--protocol',str(protocol),'--qualification','owner-fixture','--output',str(output),'--phase','qualification','--maximum-changes','3']
                    stdout=BinaryStdout()
                    with contextlib.ExitStack() as stack:
                        stack.enter_context(patch.object(m,'CaptureAdapter',return_value=Adapter()))
                        stack.enter_context(patch.object(m,'Sweep',CompletedSweep))
                        stack.enter_context(patch.object(m,'attest',return_value={}))
                        stack.enter_context(patch.object(Path,'open',faulty_open))
                        stack.enter_context(patch.object(Path,'unlink',faulty_unlink))
                        stack.enter_context(patch.object(m.Trace,'write',faulty_trace_write))
                        stack.enter_context(patch.object(m.Trace,'close',faulty_trace_close))
                        stack.enter_context(patch.object(m.os,'fsync',faulty_fsync))
                        stack.enter_context(patch.object(m.os,'link',faulty_link))
                        stack.enter_context(contextlib.redirect_stdout(stdout))
                        code=m.main(argv)
                    result=json.loads(stdout.getvalue())
                    self.assertEqual(events.count('single-sweep-run'),1)
                    self.assertIn('lock-close',events);self.assertIn('lock-unlink',events)
                    self.assertEqual(result['completedChanges'],3)
                    self.assertEqual(result['sweepOutcome']['ok'],not earlier_error)
                    if earlier_error:self.assertEqual(result['sweepOutcome']['error'],'original sweep failure')
                    self.assertFalse(result['captureFinalized']);self.assertFalse(result['gameLaunched'])
                    self.assertEqual(result['ownedLockReleased'],fault!='lock-unlink')
                    self.assertEqual((session/'.racemenu-sweep.lock').exists(),fault=='lock-unlink')
                    if fault!='none':
                        self.assertEqual(code,2);self.assertFalse(result['ok'])
                        self.assertFalse(result['terminalEvidenceFinalized'])
                        self.assertTrue(result['evidenceFinalizationErrors'])
                    else:
                        self.assertEqual(code,2 if earlier_error else 0)
                        self.assertTrue(result['terminalEvidenceFinalized'])
                        self.assertEqual(result['evidenceFinalizationErrors'],[])
                    if fault.startswith(('receipt-','audit-')) or fault=='candidate-cleanup':
                        self.assertFalse((output/'receipt.json').exists())
                    elif (output/'receipt.json').exists():
                        self.assertEqual(json.loads((output/'receipt.json').read_text()),result)
                        self.assertEqual((output/'receipt.json').read_bytes(),stdout.buffer.getvalue())
                    for pending_path in output.glob('receipt.pending-*.json'):
                        pending=json.loads(pending_path.read_text())
                        self.assertFalse(pending['terminalEvidenceFinalized'])
                        self.assertFalse(pending['ok'])
                        if fault.startswith('receipt-') or fault in ('audit-close','candidate-cleanup'):
                            self.assertEqual(next(e for e in pending['evidenceFinalizationErrors'] if e['operation']=='terminal-receipt-persist'),
                                             next(e for e in result['evidenceFinalizationErrors'] if e['operation']=='terminal-receipt-persist'))
                    if fault=='audit-update':
                        self.assertIn('terminal-receipt-audit-persist',[e['operation'] for e in result['evidenceFinalizationErrors']])
                    if fault=='candidate-cleanup':
                        self.assertIn('terminal-receipt-candidate-cleanup',[e['operation'] for e in result['evidenceFinalizationErrors']])
                    elif fault.startswith('receipt-'):
                        self.assertEqual(list(output.glob('receipt.candidate-*.tmp')),[])
    def test_cli_unicode_and_escaped_lines_share_one_exact_terminal_buffer(self):
        for failed in (False, True):
            with self.subTest(failed=failed):
                folder=Path(self.temp.name)/('unicode-failed' if failed else 'unicode-success')
                folder.mkdir()
                protocol=folder/'protocol.json'
                protocol.write_text(json.dumps(dict(limits=dict(maximumInputRequestsInFlight=1,mutationRetries=0,phaseDeadlineSeconds=900,menuSettleDeadlineSeconds=30),phases=[dict(id='qualification',maximumChanges=20)])))
                message='Épreuve — 雪 🐈\nsecond line\r\n"quoted" \\ path'
                class Adapter:
                    state=dict(sessionDirectory=str(folder))
                class CompletedSweep:
                    completed=1
                    def __init__(self,*args,**kwargs):pass
                    def run(self):
                        if failed:raise m.StopSweep(message)
                        return dict(ok=True,state='bounded-count-completed',completedChanges=1,detail=message)
                stdout=BinaryStdout()
                with patch.object(m,'CaptureAdapter',return_value=Adapter()), patch.object(m,'Sweep',CompletedSweep), patch.object(m,'attest',return_value={}), contextlib.redirect_stdout(stdout):
                    code=m.main(['--capture-session','fixture','--capture-controller',str(ROOT/'Invoke-SweepDevBench.ps1'),'--confirm-existing-capture-lane','--pwsh','fixture','--protocol',str(protocol),'--qualification','fixture','--output',str(folder/'output'),'--phase','qualification','--maximum-changes','1'])
                raw=stdout.buffer.getvalue()
                self.assertEqual(code,2 if failed else 0)
                self.assertEqual((folder/'output'/'receipt.json').read_bytes(),raw)
                self.assertIn('雪 🐈'.encode('utf-8'),raw)
                self.assertFalse(raw.startswith(b'\xef\xbb\xbf'))
                self.assertEqual(raw.count(b'\n'),1)
                self.assertNotIn(b'\r',raw)
                result=json.loads(raw)
                self.assertEqual(result['sweepOutcome']['error' if failed else 'detail'],message)
                self.assertTrue(result['ownedLockReleased'])
                self.assertFalse((folder/'.racemenu-sweep.lock').exists())
    def test_cli_extreme_slider_arithmetic_is_structured_before_mutation(self):
        cases=[('nonfinite lattice',-1e307,1e307,1e-308,'lattice'),
               ('nonfinite span',-1e308,1e308,1,'span'),
               ('inexact lattice',0,1,1e-16,'lattice'),
               ('nonadvancing step',1e15,1e15+1,.001,'advance')]
        for name,low,high,step,message in cases:
            with self.subTest(name=name):
                folder=Path(self.temp.name)/name;folder.mkdir()
                protocol=folder/'protocol.json'
                protocol.write_text(json.dumps(dict(limits=dict(maximumInputRequestsInFlight=1,mutationRetries=0,phaseDeadlineSeconds=900,menuSettleDeadlineSeconds=30),phases=[dict(id='race-slider-cross-product',maximumChanges=200)])))
                class Adapter(Fake):
                    def refresh(self,deadline):return m.snapshot(super().refresh(deadline))
                adapter=Adapter();adapter.state=dict(sessionDirectory=str(folder))
                adapter.s['sliders'][0].update(minimum=low,maximum=high,step=step,value=low)
                stdout=BinaryStdout()
                with patch.object(m,'CaptureAdapter',return_value=adapter), patch.object(m,'attest',return_value={}), contextlib.redirect_stdout(stdout):
                    code=m.main(['--capture-session','fixture','--capture-controller',str(ROOT/'Invoke-SweepDevBench.ps1'),'--confirm-existing-capture-lane','--pwsh','fixture','--protocol',str(protocol),'--qualification','fixture','--output',str(folder/'output'),'--phase','race-slider-cross-product'])
                result=json.loads(stdout.getvalue())
                self.assertEqual(code,2);self.assertFalse(result['ok'])
                self.assertIn(message,result['error']);self.assertEqual(result['completedChanges'],0)
                self.assertEqual(adapter.calls,[]);self.assertTrue(result['ownedLockReleased'])
                self.assertFalse((folder/'.racemenu-sweep.lock').exists())
                self.assertEqual(json.loads((folder/'output'/'receipt.json').read_text()),result)
                self.assertEqual((folder/'output'/'receipt.json').read_bytes(),stdout.buffer.getvalue())
                self.assertTrue(result['terminalEvidenceFinalized'])
    def test_slider_arithmetic_residual_and_oversized_integers_fail_closed(self):
        self.assertFalse(m.number(10**400))
        s=state();s['generation']=10**400
        with self.assertRaises(m.StopSweep):m.snapshot(s)
        with patch.object(m.math,'floor',side_effect=OverflowError('residual arithmetic')):
            with self.assertRaisesRegex(m.StopSweep,'Unsafe slider lattice arithmetic'):
                m.legal_targets(state()['sliders'][0])
    def test_cli_never_removes_a_foreign_unacquired_lock(self):
        foreign=Path(self.temp.name)/'.racemenu-sweep.lock'
        foreign.write_text('foreign-owner-evidence')
        with patch.object(m,'load',side_effect=OSError('preflight rejected before lock acquisition')), patch.object(Path,'unlink') as unlink:
            stdout=BinaryStdout()
            with contextlib.redirect_stdout(stdout):
                code=m.main(['--capture-session','retained','--capture-controller','fixture','--confirm-existing-capture-lane','--pwsh','fixture','--protocol','bad','--qualification','fixture','--output','unused','--phase','qualification'])
            self.assertEqual(code,2)
            self.assertFalse(json.loads(stdout.getvalue())['ok'])
            unlink.assert_not_called()
            self.assertEqual(foreign.read_text(),'foreign-owner-evidence')
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
    def test_guard_log_ignores_history_then_matches_split_new_marker(self):
        log=Path(self.temp.name)/'guard.log'
        log.write_bytes(b'[VR pose binding guard] historical\n')
        guard=m.GuardLog(log,self.trace)
        guard.check()  # Existing content is not a current event.
        with log.open('ab') as stream: stream.write(b'new line [VR pose ')
        guard.check()
        with log.open('ab') as stream: stream.write(b'binding guard] rejection\n')
        with self.assertRaises(m.StopSweep): guard.check()
    def test_guard_log_truncation_and_read_budget_fail_closed(self):
        log=Path(self.temp.name)/'guard.log';log.write_bytes(b'old')
        guard=m.GuardLog(log,self.trace)
        log.write_bytes(b'')
        with self.assertRaises(m.StopSweep): guard.check()
        guard=m.GuardLog(log,self.trace)
        log.write_bytes(b'x'*(m.GuardLog.LIMIT+1))
        with self.assertRaises(m.StopSweep): guard.check()


class Entrypoint(unittest.TestCase):
    def test_production_entrypoint_and_adapter_policy(self):
        self.run_entrypoint(False)

    def test_real_capture_composite_observer_and_sweep_entrypoint(self):
        self.run_entrypoint(True)

    def run_entrypoint(self, real_capture):
        pwsh=shutil.which('pwsh')
        if not pwsh: self.skipTest('PowerShell unavailable')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            capture=root/'capture-interaction-control';capture.mkdir()
            devbench=root/'devbench-control';devbench.mkdir()
            for dest in (capture/'Invoke-CaptureInteraction.ps1',devbench/'Invoke-DevBenchControl.ps1'):
                shutil.copyfile(ROOT/'tests'/'fixture.ps1',dest)
            if real_capture:
                # Only DevBench responses are substituted. The actual capture
                # entry point/module build and journal the composite observation.
                for name in ('Invoke-CaptureInteraction.ps1','CaptureInteractionControl.psm1'):
                    shutil.copyfile(ROOT.parent/'capture-interaction-control'/name,capture/name)
            model=state();model['frame']=0;model['mutations']=0
            if real_capture: model['calls']=[]
            model_path=root/'model.json';model_path.write_text(json.dumps(model))
            identity=dict(listenerPid=1,processPath='fixture.exe',processStartTimeUtc='fixture',
                          buildId='fixture',artifactPath='fixture.dll',artifactSha256='a'*64)
            session=root/'session.json'
            session.write_text(json.dumps(dict(contractVersion='1.0.0',status='active',sessionId='fixture',
                               sessionDirectory=str(root),runtimeIdentity=identity,modelPath=str(model_path),
                               runtimePath=str(model_path),visualMode='sequence',preferredView='left_eye',
                               screenshot=dict(requestId='fixture-shot'))))
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
            result=subprocess.run(argv,capture_output=True,timeout=50)
            failure_trace=(root/'run'/'trace.ndjson').read_text() if (root/'run'/'trace.ndjson').exists() else ''
            self.assertEqual(result.returncode,0,result.stdout+result.stderr+failure_trace.encode('utf-8'))
            receipt=json.loads(result.stdout)
            self.assertEqual((root/'run'/'receipt.json').read_bytes(),result.stdout)
            self.assertTrue(result.stdout.endswith(b'\n'))
            self.assertNotIn(b'\r\n',result.stdout)
            self.assertFalse(result.stdout.startswith(b'\xef\xbb\xbf'))
            self.assertEqual(receipt['completedChanges'],1)
            model=json.loads(model_path.read_text(encoding='utf-8-sig'))
            self.assertEqual(model['mutations'],1)
            self.assertEqual(model['retries'],0)
            self.assertLessEqual(model['timeout'],30)
            if real_capture:
                observation=json.loads((root/'latest-observation.json').read_text(encoding='utf-8-sig'))
                self.assertTrue(observation['game']['ok'])
                self.assertTrue(observation['recording']['ok'])
                self.assertIsNone(observation['screenshot']['error'])
                observed={(c['tool'],c['arguments'].get('action',c['arguments'].get('kind')))
                          for c in model['calls'] if c['tool']!='papyrus'}
                self.assertEqual(observed,{('record','status'),('inspect','state'),('menu','list'),
                                           ('input','status'),('input','observe'),
                                           ('communityshaders.screenshot','request_get')})
                for call in model['calls']:
                    self.assertEqual(json.loads(call['identity']),identity)
                    self.assertEqual(call['retries'],0)
                    self.assertGreaterEqual(call['timeout'],1)
                    self.assertLessEqual(call['timeout'],30)
                    if call['tool']!='papyrus': self.assertNotIn('function',call['arguments'])
            self.assertFalse((root/'.racemenu-sweep.lock').exists())
            entries=[json.loads(line) for line in (root/'run'/'trace.ndjson').read_text().splitlines()]
            self.assertEqual(sum(e['kind']=='mutation-intent' for e in entries),1)
            self.assertEqual(sum(e['kind']=='mutation-menu-verified' for e in entries),1)
            forwarded=json.loads(next(e['stdout'] for e in entries if e['kind']=='capture-call-result'))
            original=forwarded['data']['action']['receipt']['result']['originalControllerEnvelope']
            self.assertFalse(original['ok'])
            self.assertFalse(original['semantic']['known'])
            # A repeated production entry point refuses reuse before any actor mutation.
            again=subprocess.run(argv,capture_output=True,text=True,timeout=10)
            self.assertEqual(again.returncode,2)
            self.assertEqual(json.loads(model_path.read_text(encoding='utf-8-sig'))['mutations'],1)
            # Scoped qualification must not override known semantic rejection or
            # called=false, even when the transport and shape look plausible.
            for flag in ('denyKnown','denyCalled'):
                denied_model=dict(model,**{flag:True})
                model_path.write_text(json.dumps(denied_model))
                denied=argv.copy()
                denied[denied.index(str(root/'run'))]=str(root/flag)
                rejected=subprocess.run(denied,capture_output=True,text=True,timeout=5)
                self.assertEqual(rejected.returncode,2,rejected.stdout+rejected.stderr)
                self.assertEqual(json.loads(model_path.read_text(encoding='utf-8-sig'))['mutations'],1)
            if real_capture:
                # A real composite observer retains failed probes rather than
                # fabricating qualified progress. Either mandatory probe stops
                # the production sweep before another actor mutation.
                for tool in ('inspect','record'):
                    model_path.write_text(json.dumps(dict(model,denyObservation=tool)))
                    denied=argv.copy()
                    denied[denied.index(str(root/'run'))]=str(root/('deny-'+tool))
                    rejected=subprocess.run(denied,capture_output=True,text=True,timeout=15)
                    self.assertEqual(rejected.returncode,2,rejected.stdout+rejected.stderr)
                    self.assertEqual(json.loads(model_path.read_text(encoding='utf-8-sig'))['mutations'],1)
                    observation=json.loads((root/'latest-observation.json').read_text(encoding='utf-8-sig'))
                    key='game' if tool=='inspect' else 'recording'
                    self.assertFalse(observation[key]['ok'])
                    self.assertIsNone(observation[key]['value'])
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


class AdapterShape(unittest.TestCase):
    def test_typed_papyrus_guard_and_unchanged_observation_responses(self):
        pwsh=shutil.which('pwsh')
        if not pwsh: self.skipTest('PowerShell unavailable')
        request=dict(action='call',script='UI',function='GetString',
                     args=[m.MENU,m.OWNER+'.vrDiagnosticSnapshotJson'])
        response=dict(ok=False,transportOk=True,indeterminate=False,semantic=dict(known=False),
                      errors=['unrecognized return'],data=dict(content=[dict(called=True,returned='{}',returnedType='String')]))
        with tempfile.TemporaryDirectory() as directory:
            model_path=Path(directory)/'model.json'
            env=os.environ.copy()
            env['RACEMENU_SWEEP_DEVBENCH_SCRIPT']=str(ROOT/'tests'/'fixture.ps1')
            def call(tool,args,envelope):
                model_path.write_text(json.dumps(dict(adapterResponse=envelope)))
                env['RACEMENU_SWEEP_DEADLINE_UTC']=(datetime.now(timezone.utc)+timedelta(seconds=15)).isoformat()
                result=subprocess.run([pwsh,'-NoProfile','-NonInteractive','-File',
                         str(ROOT/'Invoke-SweepDevBench.ps1'),'call','-Tool',tool,
                         '-ArgumentsJson',json.dumps(args),'-RuntimePath',str(model_path),
                         '-ExpectedRuntimeIdentityJson','{}','-Compact','-NoExit'],
                         env=env,capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                return json.loads(result.stdout)
            qualified=call('papyrus',request,response)
            self.assertTrue(qualified['ok'])
            self.assertEqual(qualified['originalControllerEnvelope'],response)
            malformed=[{},None,[],dict(request,function=None),dict(request,function=['GetString']),
                       dict(request,action=False),dict(request,script=7),dict(request,args=None),
                       dict(request,args='not an array'),dict(request,args=[m.MENU]),
                       dict(request,args=[m.MENU,False]),dict(request,args=['Other Menu',request['args'][1]]),
                       dict(request,args=[m.MENU,m.OWNER+'.unrelated'])]
            for args in malformed:
                with self.subTest(request=args): self.assertEqual(call('papyrus',args,response),response)
            negatives=[]
            for key,value in [('transportOk',False),('transportOk','true'),('indeterminate',True),
                              ('indeterminate','false'),('semantic',{}),('semantic',dict(known=True)),
                              ('semantic',dict(known='false')),('data',{}),('data',dict(content=[None]))]:
                negatives.append(dict(response,**{key:value}))
            for key,value in [('called',False),('called','true'),('returned',7),('returnedType',None)]:
                item=dict(response['data']['content'][0],**{key:value})
                negatives.append(dict(response,data=dict(content=[item])))
            for envelope in negatives:
                with self.subTest(response=envelope): self.assertEqual(call('papyrus',request,envelope),envelope)
            # Unknown/non-Papyrus envelopes are not candidates for Papyrus
            # qualification, even if they contain a plausible called receipt.
            for tool,args in [('record',dict(action='status')),('inspect',dict(kind='state')),
                              ('menu',dict(action='list')),('input',dict(action='observe')),
                              ('communityshaders.screenshot',dict(action='request_get'))]:
                with self.subTest(tool=tool):
                    actual=call(tool,args,response)
                    self.assertEqual(actual,response)
                    self.assertNotIn('originalControllerEnvelope',actual)
                    positive=dict(response,ok=True)
                    self.assertEqual(call(tool,args,positive),positive)


if __name__=='__main__': unittest.main(verbosity=2)
