# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded synthetic loopback fixture; never connects to a game or VR runtime."""
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

root, source, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
events, requests = [], {}
lease, restored, capture_count, snapshot_count, neutral_count = None, False, 0, 0, 0
build = 'a' * 64
binding = dict(processSession=f'{os.getpid()}:fixture', pid=os.getpid(), loadGeneration=1, cellFormId=7, globalFormIds=[1,2,3,4,5,6])
values = dict(year=201, month=1, day=1, gameHour=12, daysPassed=1, calendarRate=20, engineMultiplier=1)
producer = dict(component='CommunityShaders', buildId=build, sourceCommit='b'*40, shaderCacheAbiId='abi', shaderCompilerIdentity='fxc', sessionId='fixture-shader', serviceSessionId='fixture-shader', manifestVerified=False, manifestError=None)
calendar_schema=json.loads((source/'native-calendar-schema.json').read_text(encoding='utf-8-sig'))
template=json.loads((source/'native-screenshot-completed.json').read_text(encoding='utf-8-sig'))
encoding=json.loads((source/'native-screenshot-encoding.json').read_text(encoding='utf-8-sig'))
def utc(): return datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
def screenshot(q):
    global capture_count
    if q['action']=='capture':
        capture_count+=1
        rid=f'owned-{capture_count}'
        requests[rid]=dict(command=copy.deepcopy(q), accepted=utc(), reads=0, cancelled=False)
        if mode=='lost-acceptance': return dict(error='lost accepted response'), True
        return dict(ok=True, contract=template['contract'], command=q, server=producer, result=dict(requestId=rid, clientId=q['clientId'], commandId=q['commandId'], kind='still')), False
    req=requests[q['requestId']]
    if q['clientId']!=req['command']['clientId']: raise ValueError('foreign screenshot client')
    if q['action']=='request_cancel':
        req['cancelled']=True
        return dict(ok=True, command=q, result=dict(requestId=q['requestId'], state='cancel_requested')), False
    req['reads']+=1
    pending=(mode in ('timeout','cancel-failed') and not req['cancelled']) or req['reads']==1
    p=copy.deepcopy(encoding if pending else template)
    p['command']=q; p['server']=producer.copy(); p['timestampUtc']=utc()
    r=p['result']; cmd=req['command']; r.update(requestId=q['requestId'],clientId=cmd['clientId'],commandId=cmd['commandId'],acceptedUtc=req['accepted'],requested=cmd)
    r['effective']=copy.deepcopy(cmd['capture']);r['actual']['source']=copy.deepcopy(cmd['capture']['source'])
    r['actual']['acquisition'].update(engineFrame=100+capture_count,compositorCycle=200+capture_count,utcTimestamp=p['timestampUtc'])
    if not pending:
        r['terminalUtc']=p['timestampUtc']
        for art in r['artifacts']:
            suffix='left' if art['actual']['view']=='left_eye' else 'right'
            path=Path(cmd['capture']['destination']['directory'])/(cmd['capture']['destination']['baseName']+'_'+suffix+'.png')
            # Synthetic PNG signature only: fixture checks publication ownership,
            # not decoding, visual fidelity or a real engine capture.
            raw=bytes.fromhex('89504e470d0a1a0a')+bytes([capture_count])*16
            path.write_bytes(raw);art.update(path=str(path),bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
        if req['cancelled']:
            r.update(state='cancelled',terminal=True,artifacts=[])
            r['artifactProgress']=dict(expected=2,successful=0,terminal=2)
        if mode=='bad-hash': r['artifacts'][0]['sha256']='0'*64
        if mode=='wrong-command': r['commandId']='foreign'
        if mode=='wrong-path': r['artifacts'][0]['path']=str(root/'foreign.png')
        if mode=='missing-eye': r['artifacts']=r['artifacts'][:1]
        if mode=='stale-frame': r['actual']['acquisition']['engineFrame']=100
    if mode=='cancel-failed' and req['cancelled']:p['ok']=False
    return p, False

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*unused): pass
    def reply(self,data,session=False,status=200):
        raw=json.dumps(data).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)))
        if session:self.send_header('Mcp-Session-Id','stills-fixture')
        self.end_headers();self.wfile.write(raw)
    def record(self,method,args=None):
        events.append(dict(method=method,session=self.headers.get('Mcp-Session-Id'),arguments=args,utc=utc()))
        (root/'events.json').write_text(json.dumps(events),encoding='utf-8')
    def do_DELETE(self):self.record('DELETE');self.reply({})
    def do_POST(self):
        global lease, restored, snapshot_count, neutral_count
        rpc=json.loads(self.rfile.read(int(self.headers['Content-Length'])));method=rpc['method'];args=rpc.get('params',{});self.record(method,args)
        if method=='notifications/initialized': self.reply({});return
        if method=='initialize':result=dict(protocolVersion='2025-03-26',capabilities={},serverInfo=dict(name='offline-stills',version='1'))
        elif method=='tools/list':
            actions=['capture','request_get','request_cancel'] if mode!='schema-missing' else ['capture','request_get']
            result=dict(tools=[calendar_schema,dict(name='inspect',inputSchema={}),dict(name='communityshaders.screenshot',inputSchema=dict(properties=dict(action=dict(type='string',enum=actions),contractMajor=dict(type='integer',const=1)))),dict(name='communityshaders.shader_api',inputSchema=dict(required=['contractMajor','clientId','commandId','action'],properties=dict(contractMajor=dict(type='integer',const=1),clientId=dict(type='string'),commandId=dict(type='string'),action=dict(type='string',enum=['registry','snapshot']))))])
            if mode in ('nonneutral','epoch-drift'):result['tools'].append(dict(name='skyrimvrupscaler.temporalProbe',inputSchema={}))
        elif method=='tools/call':
            if self.headers.get('Mcp-Session-Id')!='stills-fixture': self.reply(dict(error='foreign session'),status=400);return
            name,q=args['name'],args['arguments'];tool_error=False
            if name=='inspect':p=dict(pid=os.getpid(),exe=Path(sys.executable).name,port=self.server.server_port,frame=1,lastTaskFrame=1,pendingTasks=0,vr=True)
            elif name=='calendar':
                action=q['action']
                if action=='hold':lease=dict(id='stills-lease',owner=q['owner'],commandId=q['commandId'],binding=copy.deepcopy(binding),applied=True,captured=values.copy())
                if action=='release':
                    if q['leaseId']!=lease['id'] or q['owner']!=lease['owner'] or q['binding']!=lease['binding']:raise ValueError('foreign release')
                    restored=mode!='release-failed'
                b=binding.copy()
                if mode=='cell-drift' and capture_count:b['cellFormId']=8
                active=bool(lease) and not restored
                p=dict(ok=True,action=action,status='held' if action=='hold' else 'released' if action=='release' else 'observed',schemaVersion=1,plugin='devbench',binding=b,readbackFresh=True,available=True,worldLoaded=True,values=dict(values,calendarRate=0 if active else 20),outstanding=active,leaseActive=active,expiryDue=False,cleanupPending=False,holdValid=active,serviceStopping=False,restored=restored,lastTransition=dict(ok=True,status='released',restored=restored))
                if lease:p['lease']=lease
            elif name=='communityshaders.screenshot':p,tool_error=screenshot(q)
            elif name=='skyrimvrupscaler.temporalProbe':
                neutral_count+=1;p=dict(performanceDistorted=mode=='nonneutral',physicalStateKnown=True,performanceEpoch=neutral_count if mode=='epoch-drift' else 1)
            elif name=='communityshaders.shader_api':
                if q['action']=='registry':p=dict(ok=True,server=producer,result=dict(service='csx.shader'))
                else:
                    snapshot_count+=1
                    comp=dict(active=False,async_=True,skipUnchanged=False,activeShaderCapture=False,totalTasks=10,completedTasks=10,failedTasks=1 if mode=='compiler' or (mode=='after-compiler' and capture_count) else 0,currentFailedShaders=0,memoryCacheHits=0,diskCacheHits=0,sourceCompiles=10,slowTasks=0,verySlowTasks=0,heavyTasksInFlight=0,foregroundThreadCount=2,backgroundThreadCount=1,statisticsText='fixture',recentFailures=[]);comp['async']=comp.pop('async_')
                    snap=dict(available=True,stateRevision=1,capabilities=1,customShaders=dict(requested=True,effective=True,transitionPending=False),diskCache=dict(requested=True,active=True,held=False,previousAvailable=False,featureSetChanged=False,featureSetRevertPending=False),persistence=dict(mutationBlocked=False,saveLoadSafeModeActive=False),compilation=comp,provenance=dict(buildId=build,shaderCacheAbiId='abi',shaderCompilerIdentity='fxc'))
                    p=dict(ok=True,contract=dict(name='csx.shader',major=1,minor=0,schemaRevision=1),command=q,timestampUtc=utc(),server=producer,result=dict(status='success',snapshot=snap))
            else:raise ValueError('unexpected fixture tool')
            result=dict(isError=tool_error,content=[dict(type='text',text=json.dumps(p))])
        else:raise ValueError('unexpected method')
        self.reply(dict(jsonrpc='2.0',id=rpc.get('id'),result=result),session=method=='initialize')

server=HTTPServer(('127.0.0.1',0),Handler)
(root/'runtime.json').write_text(json.dumps(dict(port=server.server_port,pid=os.getpid())),encoding='utf-8')
server.serve_forever()
