#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded menu-owned diagnostics through an existing capture owner only."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

MENU = 'RaceSex Menu'
OWNER = '_root.RaceSexMenuBaseInstance.RaceSexPanelsInstance'
PENDING = {'race-change-pending', 'sliders-rebuilding', 'menu-not-ready'}
CAPS = {'qualification': 20, 'human-beast-alternation': 100, 'race-slider-cross-product': 200}
CHECKS = ('moduleHashesVerified', 'csxPoseGuardQualified', 'nullHmdQualified',
          'dumpWindowActive', 'freshGameQualified', 'devbenchLiveIdentityVerified')


def utc():
    return datetime.now(timezone.utc).isoformat()


def load(path):
    with Path(path).open(encoding='utf-8-sig') as stream:
        return json.load(stream)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class StopSweep(RuntimeError):
    pass


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def integer(value):
    return number(value) and int(value) == value


def snapshot(value):
    if not isinstance(value, dict) or type(value.get('schema')) is not int or value['schema'] != 1 or not integer(value.get('generation')):
        raise StopSweep('Malformed or unsupported live snapshot')
    if value['generation'] < 1 or value['generation'] > 16000000:
        raise StopSweep('Generation outside the movie contract')
    if value.get('status') == 'ready':
        if type(value.get('mode')) is not int or value['mode'] != 0:
            raise StopSweep('Ready snapshot is not the sliders tab')
        for key in ('races', 'sliders'):
            if not isinstance(value.get(key), list):
                raise StopSweep('Missing live control list')
        ids, slots = set(), set()
        active = 0
        for race in value['races']:
            if not isinstance(race, dict) or not integer(race.get('id')) or type(race.get('enabled')) is not bool or type(race.get('active')) is not bool:
                raise StopSweep('Malformed live race')
            if race['id'] in ids:
                raise StopSweep('Duplicate race ID')
            ids.add(race['id'])
            active += int(race['active'])
        if active != 1:
            raise StopSweep('Exactly one live active race is required')
        for slider in value['sliders']:
            if not isinstance(slider, dict) or not integer(slider.get('slot')) or slider['slot'] < 0 or not integer(slider.get('id')):
                raise StopSweep('Malformed slider identity')
            if slider['slot'] in slots or type(slider.get('enabled')) is not bool:
                raise StopSweep('Duplicate slider slot or malformed enabled flag')
            slots.add(slider['slot'])
            if slider.get('action') not in ('set-slider', 'select-sex'):
                raise StopSweep('Unsupported slider action')
            if not isinstance(slider.get('callback'), str) or not slider['callback']:
                raise StopSweep('Missing slider callback')
            if any(not number(slider.get(k)) for k in ('minimum', 'maximum', 'step', 'value')):
                raise StopSweep('Nonfinite or malformed slider bounds')
            if slider['maximum'] < slider['minimum'] or slider['step'] < 0:
                raise StopSweep('Invalid slider bounds')
    return value


def active_race(s):
    return next(r['id'] for r in s['races'] if r['active'])


def legal_targets(s):
    low, high, step = s['minimum'], s['maximum'], s['step']
    # A maximum need not be interval-aligned. Stay on the minimum-based lattice.
    top = low + math.floor((high-low)/step + 1e-8)*step if step else high
    return [v for v in (low, min(top, high)) if not math.isclose(v, s['value'], abs_tol=1e-6, rel_tol=0)]


class Trace:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=False)
        self.path = self.directory / 'trace.ndjson'
        self.stream = self.path.open('x', encoding='utf-8')
        self.ordinal = 0

    def write(self, kind, **values):
        self.ordinal += 1
        entry = dict(ordinal=self.ordinal, utc=utc(), kind=kind, **values)
        self.stream.write(json.dumps(entry, allow_nan=False, ensure_ascii=False) + '\n')
        self.stream.flush()
        os.fsync(self.stream.fileno())

    def close(self):
        self.stream.close()


class GuardLog:
    """Short read-only inspections of one exact file, starting at admission EOF."""
    MARKER = b'[VR pose binding guard]'
    LIMIT = 65536

    def __init__(self, path, trace):
        self.path, self.trace = Path(path).resolve(), trace
        stat = self.path.stat()
        if not self.path.is_file() or not stat.st_ino:
            raise StopSweep('Guard log requires an exact regular file with stable identity')
        self.identity = (stat.st_dev,stat.st_ino)
        self.offset = stat.st_size
        self.tail = b''
        trace.write('guard-log-admission',path=str(self.path),identity=self.identity,
                    offsetBytes=self.offset,historyMatched=False,boundary='start-at-current-EOF')

    def check(self):
        stat = self.path.stat()
        if (stat.st_dev,stat.st_ino) != self.identity or stat.st_size < self.offset:
            raise StopSweep('Guard log replaced or truncated; stop inputs')
        available = stat.st_size-self.offset
        if not available:
            return
        start = self.offset
        with self.path.open('rb') as stream:
            opened = os.fstat(stream.fileno())
            if (opened.st_dev,opened.st_ino) != self.identity:
                raise StopSweep('Guard log changed during open')
            stream.seek(start)
            data = stream.read(min(available,self.LIMIT))
        self.offset += len(data)
        joined = self.tail+data
        found = joined.find(self.MARKER)
        self.trace.write('guard-log-read',path=str(self.path),identity=self.identity,
                         startByteInclusive=start,endByteExclusive=self.offset,
                         sourceSizeAtReadStart=stat.st_size,bytesRead=len(data),
                         markerFound=found >= 0,utf8ReplacementCharacters=data.decode('utf-8','replace').count('\ufffd'))
        if found >= 0:
            self.trace.write('guard-log-match',path=str(self.path),
                             markerByteOffset=start-len(self.tail)+found,
                             excerptStartByteInclusive=start-len(self.tail),
                             excerptEndByteExclusive=self.offset,
                             excerpt=joined.decode('utf-8','replace'),historicalMatch=False)
            raise StopSweep('New native pose guard event; stop inputs and retain capture/game')
        if available > self.LIMIT or len(data) != available:
            raise StopSweep('Guard log exceeded bounded read or changed during read; stop inputs')
        self.tail = joined[-(len(self.MARKER)-1):]


class CaptureAdapter:
    def __init__(self, session_path, capture_controller, pwsh, trace, stop_file=None, call_timeout=10, guard_log=None):
        self.session_path = Path(session_path).resolve()
        self.controller = Path(capture_controller).resolve()
        self.pwsh = Path(pwsh).resolve()
        self.trace = trace
        self.stop_file = Path(stop_file) if stop_file else None
        self.call_timeout = call_timeout
        self.state = load(self.session_path)
        identity = self.state.get('runtimeIdentity', {})
        if self.state.get('contractVersion') != '1.0.0' or self.state.get('status') != 'active':
            raise StopSweep('An existing active capture interaction session is required')
        if not self.state.get('sessionId') or any(not identity.get(k) for k in
              ('listenerPid','processPath','processStartTimeUtc','buildId','artifactPath','artifactSha256')):
            raise StopSweep('Capture runtime identity is incomplete')
        self.devbench = self.controller.parent.parent / 'devbench-control' / 'Invoke-DevBenchControl.ps1'
        if not all(p.is_file() for p in (self.controller, self.pwsh, self.devbench)):
            raise StopSweep('Exact capture owner, PowerShell or bundled DevBench controller missing')
        self.guard = GuardLog(guard_log,trace) if guard_log else None

    def check(self):
        if self.guard:
            self.guard.check()
        if self.stop_file and self.stop_file.exists():
            raise StopSweep('Owner stop signal present; preserving capture')
        state = load(self.session_path)
        if state.get('status') != 'active' or state.get('sessionId') != self.state['sessionId'] or state.get('runtimeIdentity') != self.state['runtimeIdentity']:
            raise StopSweep('Capture owner or runtime identity changed')

    def call(self, command, args, deadline):
        self.check()
        remaining = min(self.call_timeout, deadline-time.monotonic())
        if remaining <= 0.1:
            raise StopSweep('Call budget expired before dispatch')
        env = os.environ.copy()
        env['RACEMENU_SWEEP_DEVBENCH_SCRIPT'] = str(self.devbench)
        env['RACEMENU_SWEEP_DEADLINE_UTC'] = (datetime.now(timezone.utc) + timedelta(seconds=remaining)).isoformat()
        argv = [str(self.pwsh), '-NoProfile', '-NonInteractive', '-File', str(self.controller),
                command, '-SessionPath', str(self.session_path), '-DevBenchScriptPath',
                str(Path(__file__).with_name('Invoke-SweepDevBench.ps1')), '-Compact']
        if args is not None:
            argv += ['-DirectTool','papyrus','-DirectArgumentsJson',json.dumps(args, allow_nan=False)]
        # The intent is durable BEFORE the call. A lost result is never replayed.
        self.trace.write('capture-call-intent', command=command, arguments=args, timeoutSeconds=remaining)
        try:
            result = subprocess.run(argv, capture_output=True, text=True, encoding='utf-8-sig',
                                    errors='replace', timeout=remaining, env=env, check=False)
        except subprocess.TimeoutExpired as error:
            self.trace.write('capture-call-timeout', command=command,
                             stdout=str(error.stdout), stderr=str(error.stderr), indeterminate=args is not None)
            raise StopSweep('Owned capture call timed out; no replay, capture left running') from error
        self.trace.write('capture-call-result', command=command, exitCode=result.returncode,
                         stdout=result.stdout, stderr=result.stderr)
        if time.monotonic() >= deadline:
            raise StopSweep('Late capture result cannot satisfy an expired deadline')
        try:
            envelope = json.loads(result.stdout)
        except (ValueError, TypeError) as error:
            raise StopSweep('Malformed capture envelope; execution state unresolved') from error
        if result.returncode != 0 or envelope.get('ok') is not True:
            raise StopSweep('Capture call failed; no replay')
        self.check()
        return envelope

    def ui(self, function, arguments, deadline):
        remaining = deadline-time.monotonic()
        if remaining <= 0.5:
            raise StopSweep('Insufficient budget for Papyrus dispatch')
        args = {'action':'call','script':'UI','function':function,'args':arguments,
                'timeoutMs': min(3000, max(1, int((remaining-0.25)*1000)))}
        envelope = self.call('act', args, deadline)
        try:
            value = envelope['data']['action']['receipt']['result']
            if value['called'] is not True:
                raise KeyError('called')
            return value.get('returned')
        except (KeyError, TypeError) as error:
            raise StopSweep('Unqualified Papyrus return envelope') from error

    def refresh(self, deadline):
        self.ui('InvokeIntA',[MENU,OWNER+'.RefreshVRDiagnosticControls',[0]], deadline)
        raw = self.ui('GetString',[MENU,OWNER+'.vrDiagnosticSnapshotJson'], deadline)
        if not isinstance(raw, str):
            raise StopSweep('Snapshot property is not a string')
        return snapshot(json.loads(raw))

    def mutate(self, action, deadline):
        if action['kind'] == 'race':
            function, values = 'SelectVRDiagnosticRace', [action['generation'],action['raceId']]
            api = 'InvokeIntA'
        else:
            function = 'SelectVRDiagnosticSex' if action['kind'] == 'sex' else 'SetVRDiagnosticSlider'
            # Explicit floats prevent integer JSON from binding to a Papyrus Int[].
            values = [float(action[k]) for k in ('generation','slot','value')]
            api = 'InvokeFloatA'
        self.ui(api,[MENU,OWNER+'.'+function,values],deadline)
        raw = self.ui('GetString',[MENU,OWNER+'.vrDiagnosticResultJson'],deadline)
        if not isinstance(raw, str):
            raise StopSweep('Result property is not a string')
        return json.loads(raw)

    def observe(self, deadline):
        envelope = self.call('observe', None, deadline)
        try:
            observation = envelope['data']['observation']
            game_probe = observation['game']
            record_probe = observation['recording']
            if game_probe.get('ok') is not True or record_probe.get('ok') is not True:
                raise KeyError('failed game/recording probe')
            game = game_probe['value']
            record = record_probe['value']
            if not isinstance(game, dict) or not isinstance(record, dict):
                raise KeyError('malformed game/recording value')
            if game['playerLoaded'] is not True or not integer(game['frame']):
                raise KeyError('loaded/frame')
            if record.get('recording') is not True:
                raise KeyError('recording')
        except (KeyError, TypeError, AttributeError) as error:
            raise StopSweep('Game/capture progress observation is not qualified') from error
        return observation


def attest(path, adapter, protocol_path):
    value = load(path)
    if value.get('schema') != 'racemenu-sweep-qualification-v1' or value.get('sessionId') != adapter.state['sessionId'] or value.get('runtimeIdentity') != adapter.state['runtimeIdentity']:
        raise StopSweep('Owner qualification does not bind this capture runtime')
    if value.get('protocolSha256') != sha(protocol_path) or any(value.get('checks',{}).get(k) is not True for k in CHECKS):
        raise StopSweep('Missing protocol qualification prerequisites')
    refs = value.get('evidence', [])
    if not refs or not isinstance(refs, list):
        raise StopSweep('Qualification needs retained evidence, not just flags')
    for ref in refs:
        if sha(ref['path']).lower() != str(ref['sha256']).lower():
            raise StopSweep('Qualification evidence hash mismatch')
    return value


class Sweep:
    def __init__(self, adapter, trace, phase, count, phase_seconds=900, settle_seconds=30,
                 pace=2, poll=0.1, race_ids=None, include_sex=False, stop_file=None):
        self.adapter, self.trace = adapter, trace
        self.phase, self.count = phase, count
        self.phase_seconds, self.settle_seconds = phase_seconds, settle_seconds
        self.pace, self.poll, self.race_ids = pace, poll, race_ids
        self.include_sex = include_sex
        self.stop_file = Path(stop_file) if stop_file else None
        self.completed = 0
        self.visited = set()
        self.cursor = 0

    def check(self, deadline):
        if time.monotonic() >= deadline:
            raise StopSweep('Phase or settle deadline exceeded')
        if self.stop_file and self.stop_file.exists():
            raise StopSweep('Owner stop signal present')

    def ready(self, phase_deadline, target=None, before=None, settle_deadline=None):
        deadline = min(phase_deadline,settle_deadline if settle_deadline is not None else time.monotonic()+self.settle_seconds)
        while True:
            self.check(deadline)
            state = self.adapter.refresh(deadline)
            self.trace.write('live-snapshot', snapshot=state)
            self.check(deadline)
            if state['status'] == 'ready':
                if target is None or self.matches(state, target, before):
                    return state
                # Ready but old state is not a second dispatch opportunity.
            elif state['status'] not in PENDING:
                raise StopSweep('Menu rejected readiness: '+str(state['status']))
            time.sleep(min(self.poll,max(0,deadline-time.monotonic())))

    def matches(self, after, action, before):
        if action['kind'] == 'race':
            return after['generation'] != before['generation'] and active_race(after) == action['raceId']
        if action['kind'] == 'sex' and after['generation'] == before['generation']:
            return False
        matches = [s for s in after['sliders'] if s['id'] == action['id'] and s['callback'] == action['callback'] and s['enabled']]
        return len(matches) == 1 and math.isclose(matches[0]['value'],action['value'],abs_tol=1e-5,rel_tol=0)

    def choose(self, s):
        races = sorted((r for r in s['races'] if r['enabled']),key=lambda r:r['id'])
        current = active_race(s)
        if self.phase == 'human-beast-alternation':
            if not self.race_ids or len(set(self.race_ids)) != 2 or not all(any(r['id']==n for r in races) for n in self.race_ids):
                raise StopSweep('Both explicit alternation race IDs must be live and enabled')
            desired = self.race_ids[1] if current == self.race_ids[0] else self.race_ids[0]
        elif self.phase == 'qualification':
            candidates = [r for r in races if r['id'] != current]
            if not candidates:
                raise StopSweep('No different enabled race is offered')
            desired = candidates[self.cursor % len(candidates)]['id']
            self.cursor += 1
        else:
            for slider in sorted(s['sliders'],key=lambda x:(x['id'],x['slot'])):
                if not slider['enabled'] or (slider['action']=='select-sex' and not self.include_sex):
                    continue
                for value in legal_targets(slider):
                    key = (current,slider['id'],slider['callback'],value)
                    if key not in self.visited:
                        self.visited.add(key)
                        return dict(kind='sex' if slider['action']=='select-sex' else 'slider',
                                    generation=s['generation'],slot=slider['slot'],id=slider['id'],
                                    callback=slider['callback'],value=value)
            self.visited.add(('race-covered',current))
            candidates = [r for r in races if ('race-covered',r['id']) not in self.visited and r['id'] != current]
            if not candidates:
                return None
            desired = candidates[0]['id']
        return dict(kind='race',generation=s['generation'],raceId=desired)

    def run(self):
        deadline = time.monotonic()+self.phase_seconds
        exhausted = False
        previous_frame = None
        while self.completed < self.count:
            before = self.ready(deadline)
            observation = self.adapter.observe(deadline)
            frame = observation['game']['value']['frame']
            self.trace.write('before-observation',observation=observation)
            if previous_frame is not None and frame < previous_frame:
                raise StopSweep('Game frame regressed; stop inputs')
            action = self.choose(before)
            if action is None:
                exhausted = True
                break
            self.check(deadline)
            self.trace.write('mutation-intent',before=before,action=action)
            settle_deadline = min(deadline,time.monotonic()+self.settle_seconds)
            result = self.adapter.mutate(action, settle_deadline)
            self.trace.write('menu-callback-result',action=action,result=result)
            if not isinstance(result, dict) or result.get('ok') is not True or result.get('code') != 'dispatched' or not integer(result.get('generation')):
                raise StopSweep('Menu callback rejected or unqualified; no replay')
            if action['kind'] == 'slider' and result['generation'] != before['generation']:
                raise StopSweep('Unexpected slider result generation')
            if action['kind'] != 'slider' and result['generation'] == before['generation']:
                raise StopSweep('Race/sex callback did not invalidate generation')
            after = self.ready(deadline,action,before,settle_deadline)
            after_observation = self.adapter.observe(deadline)
            previous_frame = after_observation['game']['value']['frame']
            if previous_frame <= frame:
                raise StopSweep('Game frame did not advance across mutation')
            self.completed += 1
            self.trace.write('mutation-menu-verified',action=action,after=after,
                             observation=after_observation,completedChanges=self.completed)
            if self.pace and self.completed < self.count:
                if deadline-time.monotonic() <= self.pace:
                    raise StopSweep('Insufficient phase budget for pacing')
                time.sleep(self.pace)
        return dict(ok=True,state='coverage-exhausted' if exhausted else 'bounded-count-completed',
                    completedChanges=self.completed,requestedMaximum=self.count,
                    completionBasis='verified-menu-state-and-frame-progress',nativeFaultEliminated=False)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture-session',required=True)
    parser.add_argument('--capture-controller',required=True)
    parser.add_argument('--confirm-existing-capture-lane',action='store_true',required=True)
    parser.add_argument('--pwsh',required=True)
    parser.add_argument('--protocol',required=True)
    parser.add_argument('--qualification',required=True)
    parser.add_argument('--output',required=True,help='New unique directory; existing paths are refused')
    parser.add_argument('--phase',choices=CAPS,required=True)
    parser.add_argument('--maximum-changes',type=int)
    parser.add_argument('--phase-seconds',type=float,default=900)
    parser.add_argument('--settle-seconds',type=float,default=30)
    parser.add_argument('--pace-seconds',type=float)
    parser.add_argument('--poll-seconds',type=float,default=0.1)
    parser.add_argument('--call-seconds',type=float,default=10)
    parser.add_argument('--race-ids',type=int,nargs=2)
    parser.add_argument('--include-sex',action='store_true')
    parser.add_argument('--stop-file')
    parser.add_argument('--guard-log',help='Exact current CSX log; bounded new-byte inspection starting at admission EOF')
    args = parser.parse_args(argv)
    count = args.maximum_changes if args.maximum_changes is not None else CAPS[args.phase]
    pace = args.pace_seconds if args.pace_seconds is not None else (2 if args.phase=='qualification' else 0)
    for value,minimum,maximum in ((count,1,CAPS[args.phase]),(args.phase_seconds,0.1,900),
            (args.settle_seconds,0.1,30),(pace,0,30),(args.poll_seconds,0.01,5),(args.call_seconds,0.1,30)):
        if not number(value) or not minimum <= value <= maximum:
            parser.error('Invalid finite bound or phase maximum')
    trace = None
    lock = None
    result = {'ok':False,'state':'preflight-refused','completedChanges':0}
    sweep = None
    started = utc()
    try:
        # Validate protocol limits rather than silently widening its contract.
        protocol = load(args.protocol)
        limits = protocol['limits']
        phase = next(p for p in protocol['phases'] if p['id']==args.phase)
        if limits['maximumInputRequestsInFlight'] != 1 or limits['mutationRetries'] != 0 or count > phase['maximumChanges'] or args.phase_seconds > limits['phaseDeadlineSeconds'] or args.settle_seconds > limits['menuSettleDeadlineSeconds']:
            raise StopSweep('Requested run exceeds retained protocol')
        trace = Trace(args.output)
        adapter = CaptureAdapter(args.capture_session,args.capture_controller,args.pwsh,trace,args.stop_file,args.call_seconds,args.guard_log)
        qualification = attest(args.qualification,adapter,args.protocol)
        lock_path = Path(adapter.state['sessionDirectory']) / '.racemenu-sweep.lock'
        lock = lock_path.open('x',encoding='utf-8')
        lock.write(json.dumps({'pid':os.getpid(),'runId':str(uuid.uuid4()),'startedUtc':started,'trace':str(trace.path)}))
        lock.flush()
        os.fsync(lock.fileno())
        trace.write('run-preflight',phase=args.phase,protocol=protocol,protocolSha256=sha(args.protocol),
                    qualification=qualification,qualificationBasis='owner-attested-hash-bound-evidence',
                    captureSession=adapter.state,controllerSha256=sha(args.capture_controller),
                    mutationRetries=0,maximumInputRequestsInFlight=1)
        sweep = Sweep(adapter,trace,args.phase,count,args.phase_seconds,args.settle_seconds,
                      pace,args.poll_seconds,args.race_ids,args.include_sex,args.stop_file)
        result = sweep.run()
    except (StopSweep, OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        result = dict(ok=False,state='stopped-inputs-capture-retained',error=str(error),
                      completedChanges=sweep.completed if sweep else 0,mutationReplayPerformed=False)
    finally:
        original_outcome = dict(result)
        finalization_errors = []
        lock_released = lock is None
        result.update(startedUtc=started,endedUtc=utc(),phase=args.phase,
                      captureFinalized=False,gameLaunched=False,tracePath=str(trace.path) if trace else None)
        def finalization_error(operation, error):
            finalization_errors.append(dict(operation=operation,error=str(error)))
        try:
            if trace:
                try:
                    trace.write('terminal',result=dict(result))
                except Exception as error:
                    finalization_error('terminal-trace-write',error)
                try:
                    trace.close()
                except Exception as error:
                    finalization_error('terminal-trace-close',error)
        finally:
            if lock is not None:
                try:
                    lock.close()
                except Exception as error:
                    finalization_error('owned-lock-close',error)
                # Close failure must not suppress the independent unlink attempt.
                try:
                    lock_path.unlink()  # Only THIS invocation acquired this lock.
                    lock_released = True
                except Exception as error:
                    finalization_error('owned-lock-unlink',error)
        result.update(sweepOutcome=original_outcome,ownedLockReleased=lock_released,
                      terminalEvidenceFinalized=False,evidenceFinalizationErrors=finalization_errors)
        if finalization_errors:
            result.update(ok=False,state='terminal-finalization-failed')
        if trace:
            receipt = Path(args.output)/'receipt.json'
            pending_receipt = Path(args.output)/('receipt.pending-'+str(uuid.uuid4())+'.json')
            result['receiptStagingPath'] = str(pending_receipt)
            # Publish only the fully written/closed file, with exclusive creation
            # of the canonical name. Retain staging as audit even on failure.
            # A pending path is never a completed receipt. No overwrite fallback.
            result['terminalEvidenceFinalized'] = not finalization_errors
            try:
                with pending_receipt.open('x',encoding='utf-8') as stream:
                    json.dump(result,stream,indent=2,allow_nan=False)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.link(pending_receipt,receipt)
            except Exception as error:
                finalization_error('terminal-receipt-persist',error)
                result.update(ok=False,state='terminal-finalization-failed',terminalEvidenceFinalized=False)
    print(json.dumps(result,allow_nan=False))
    return 0 if result['ok'] else 2


if __name__ == '__main__':
    sys.exit(main())
