# SPDX-License-Identifier: GPL-3.0-or-later
"""Finite test-only loopback MCP fixture. Never proxies a game endpoint."""
import json
import os
from pathlib import Path
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

root, schema_path, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
schema = json.loads(schema_path.read_text(encoding='utf-8-sig'))
events = []
lease = None
restored = False
status_calls = 0
automatic_reason = None
restore_writes = 0
binding = dict(processSession=f'{os.getpid()}:fixture', pid=os.getpid(),
               loadGeneration=1, cellFormId=7, globalFormIds=[1,2,3,4,5,6])
values = dict(year=201,month=1,day=1,gameHour=12,daysPassed=1,
              calendarRate=20,engineMultiplier=1)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *unused): pass
    def reply(self, data, status=200, session=False):
        raw=json.dumps(data).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type','application/json')
        if session:self.send_header('Mcp-Session-Id','calendar-test-session')
        self.send_header('Content-Length',str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def record(self, method, args=None):
        events.append(dict(method=method,session=self.headers.get('Mcp-Session-Id'),arguments=args))
        (root/'events.json').write_text(json.dumps(events),encoding='utf-8')
    def do_DELETE(self):
        self.record('DELETE')
        self.reply({})
    def do_POST(self):
        global lease, restored, status_calls, automatic_reason, restore_writes
        rpc=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method=rpc['method']; args=rpc.get('params',{})
        self.record(method,args)
        if method=='notifications/initialized':
            self.reply({}); return
        if method=='initialize':
            result=dict(protocolVersion='2025-03-26',capabilities={},serverInfo=dict(name='offline-fixture',version='1'))
        elif method=='tools/list':
            result=dict(tools=[schema,dict(name='inspect',inputSchema={}),dict(name='communityshaders.fixture_api',inputSchema={})])
        elif method=='tools/call':
            name=args['name']; query=args['arguments']
            if self.headers.get('Mcp-Session-Id')!='calendar-test-session':
                self.reply({'error':'wrong fixture session'},400); return
            if name=='communityshaders.fixture_api':
                payload=dict(ok=True,producer=dict(buildId='calendar-fixture-build'))
            elif name=='inspect':
                payload=(dict(pid=os.getpid(),exe=Path(sys.executable).name,port=self.server.server_port,
                              frame=1,lastTaskFrame=1,pendingTasks=0,vr=True)
                         if query['kind']=='health' else dict(ok=mode not in ('failed-observation','scene-release'),playerLoaded=True))
                if query['kind']=='state' and mode=='scene-release':
                    # This observation was dispatched in cell A; cell B appears
                    # before the following release's Tick-before-dispatch step.
                    binding['cellFormId']=8
                    self.record('native-scene-change',dict(cell=8))
            elif name=='calendar':
                action=query['action']
                if action=='status':status_calls+=1
                if mode.startswith('scene-') and lease and not restored and (
                        (mode!='scene-release' and action=='status' and status_calls>1)
                        or (binding['cellFormId']==8 and action=='release')):
                    # Native Handle runs Tick before action dispatch: restore
                    # once and retain original custody as last/history.
                    binding['cellFormId']=8
                    restored=True; automatic_reason='scene_lost'; restore_writes+=1
                    lease['cleanupAttempted']=True
                    self.record('native-auto-restore',dict(reason=automatic_reason,writes=restore_writes))
                if action=='hold':
                    lease=dict(id='fixture-lease',owner=query['owner'],commandId=query['commandId'],
                               binding=json.loads(json.dumps(binding)),applied=True,captured=values.copy(),cleanupAttempted=False)
                if action=='release':
                    if not lease or query['owner']!=lease['owner'] or query['leaseId']!=lease['id'] or query['binding']!=lease['binding'] or any(binding[key]!=lease['binding'][key] for key in ('processSession','pid','loadGeneration','globalFormIds')):
                        self.reply({'error':'foreign release'},400); return
                    if not restored:
                        restored=mode not in ('release-failed','cell-foreign-rate','cell-unavailable')
                        if restored:restore_writes+=1
                    lease['cleanupAttempted']=True
                if mode=='generation' and lease and not restored and action=='status' and status_calls>1:
                    binding['loadGeneration']=2
                if mode.startswith('cell-') and lease and status_calls>1:
                    binding['cellFormId']=8
                    if mode=='cell-new-globals':binding['globalFormIds'][0]=9
                active=lease is not None and not restored
                unavailable=mode=='cell-unavailable' and lease is not None and status_calls>1
                payload=dict(ok=not(action=='release' and not restored),action=action,
                             status=automatic_reason if automatic_reason else 'held' if action=='hold' else 'released' if action=='release' else 'observed',
                             schemaVersion=1,plugin='devbench',binding=binding.copy(),frame=1,
                             readbackFresh=True,available=not unavailable,worldLoaded=True,
                             values=dict(values,calendarRate=21 if mode=='cell-foreign-rate' and lease and status_calls>1 else 0 if active else 20),
                             outstanding=active,leaseActive=active,expiryDue=False,cleanupPending=False,
                             holdValid=active,serviceStopping=False,restored=restored,
                             lastTransition=dict(ok=True,status=automatic_reason or 'released',restored=restored and mode!='cell-no-transition'))
                if lease:
                    payload['lease']=json.loads(json.dumps(lease))
                    if restored and action=='status' and mode=='cell-lease-id':payload['lease']['id']='foreign-lease'
                if mode.startswith('scene-') and restored:
                    # Adversarial public proof variants after a native-equivalent
                    # positive transition must not borrow restoration by name.
                    if action=='release':
                        if mode=='scene-release-restored-false':payload['restored']=False
                        if mode=='scene-release-ok-false':payload['ok']=False
                        if mode=='scene-release-lease-id':payload['lease']['id']='foreign-lease'
                        if mode=='scene-release-binding':payload['lease']['binding']['cellFormId']=8
                    if action=='status':
                        if mode=='scene-generation':payload['binding']['loadGeneration']=2
                        if mode=='scene-globals':payload['binding']['globalFormIds']=[9,2,3,4,5,6]
                        if mode=='scene-session':payload['binding']['processSession']='foreign-incarnation'
                        if mode=='scene-unavailable':payload['available']=False
                        if mode=='scene-rate':payload['values']['calendarRate']=21
                        if mode=='scene-transition-missing':payload['lastTransition']=None
                        if mode=='scene-transition-reason':payload['lastTransition']['status']='released'
                        if mode=='scene-transition-ok-false':payload['lastTransition']['ok']=False
                        if mode=='scene-transition-restored-false':payload['lastTransition']['restored']=False
                    if mode=='scene-unknown-reason':
                        payload['status']='unclassified';payload['lastTransition']['status']='unclassified'
            else:
                self.reply({'error':'unexpected fixture tool'},400); return
            result=dict(isError=False,content=[dict(type='text',text=json.dumps(payload))])
        else:
            self.reply({'error':'unexpected RPC'},400); return
        self.reply(dict(jsonrpc='2.0',id=rpc.get('id'),result=result),session=method=='initialize')

server=HTTPServer(('127.0.0.1',0),Handler)
(root/'runtime.json').write_text(json.dumps(dict(port=server.server_port,pid=os.getpid())),encoding='utf-8')
server.serve_forever()
