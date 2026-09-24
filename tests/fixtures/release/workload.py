#!/usr/bin/env python3
"""Disposable loopback workload for the opt-in release pilot; never production.

serve DATABASE ADDRESS_FILE persists requests, writes and idempotent action IDs.
request URL PATH [JSON] performs an actual HTTP request and prints its response.
observe URL EVIDENCE_FILE captures health (including a failed HTTP probe) then
prints a bounded notification for an existing registered Firstmate check.
"""
import http.server
import json
import sqlite3
import socketserver
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def request(url, path, data=None):
    req = urllib.request.Request(url+path, data=None if data is None else json.dumps(data).encode(),
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=2) as result:
        return json.load(result)


def serve(database, address, manifest):
    db = sqlite3.connect(database)
    db.execute('CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT)')
    db.execute('CREATE TABLE IF NOT EXISTS requests (at REAL, wrote INTEGER)')
    db.execute('CREATE TABLE IF NOT EXISTS actions (id TEXT PRIMARY KEY, operation TEXT, target TEXT)')
    defaults = dict(gate='disabled', leak=False, monitoring=True, fail_restore=False, exposure='none',
                    candidate='local-build-v1', source='source-v1', configuration='gated-v1',
                    environment='loopback', dependencies='python-stdlib', since=time.time())
    defaults.update(json.loads(Path(manifest).read_text()))
    for key,value in defaults.items():
        db.execute('INSERT OR IGNORE INTO state VALUES (?,?)',(key,json.dumps(value)))
    db.commit()

    def state():
        return {k:json.loads(v) for k,v in db.execute('SELECT key,value FROM state')}

    def update(values):
        for k,v in values.items():
            if k not in defaults: raise ValueError('unknown control')
            db.execute('UPDATE state SET value=? WHERE key=?',(json.dumps(v),k))
        db.commit()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def reply(self, payload, code=200):
            raw=json.dumps(payload).encode(); self.send_response(code)
            self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw)))
            self.end_headers(); self.wfile.write(raw)
        def do_GET(self):
            s=state()
            if self.path=='/request':
                visible=s['gate']=='enabled'
                wrote=visible or s['leak']
                db.execute('INSERT INTO requests VALUES (?,?)',(time.time(),int(wrote))); db.commit()
                self.reply(dict(visible=visible,wrote=wrote,protective_control=True)); return
            if self.path=='/health' and not s['monitoring']:
                self.reply({'health':'unknown','reason':'monitor unavailable'},503); return
            rows=db.execute('SELECT COUNT(*),COALESCE(SUM(wrote),0) FROM requests').fetchone()
            samples=db.execute('SELECT COUNT(*) FROM requests WHERE at>=?',(s['since'],)).fetchone()[0]
            actions=[dict(id=i,operation=o,target=t) for i,o,t in db.execute('SELECT * FROM actions')]
            now=time.time()
            self.reply(dict(s,requests=rows[0],writes=rows[1],actions=actions,samples=samples,
                            id='obs-%.6f'%now,signal_source='loopback-http',started_at=s['since'],ended_at=now,
                            observed_at=now,health='unhealthy' if s['leak'] else 'healthy',stop=bool(s['leak'])))
        def do_POST(self):
            payload=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
            if self.path=='/control':
                update(payload); self.reply({'controlled':payload}); return
            if self.path!='/action': self.reply({'error':'unknown path'},404); return
            key,op,target=payload['id'],payload['operation'],payload['target']
            found=db.execute('SELECT operation,target FROM actions WHERE id=?',(key,)).fetchone()
            if found:
                self.reply({'replay':True,'id':key},200 if found==(op,target) else 409); return
            if op=='restore' and state()['fail_restore']:
                self.reply({'accepted':False,'recovery':'failed'},503); return
            if op=='deploy': update(dict(exposure='none',gate='disabled'))
            elif op in ('expose','advance'): update(dict(exposure=target,gate='enabled',since=time.time()))
            elif op=='contain': update(dict(exposure='none',gate='disabled'))
            elif op!='restore': self.reply({'error':'unknown operation'},400); return
            db.execute('INSERT INTO actions VALUES (?,?,?)',(key,op,target)); db.commit()
            self.reply({'accepted':True,'id':key})

    class LoopbackServer(http.server.HTTPServer):
        def server_bind(self):
            socketserver.TCPServer.server_bind(self)
            self.server_name='localhost'
            self.server_port=self.server_address[1]
    server=LoopbackServer(('127.0.0.1',0),Handler)
    Path(address).write_text('http://127.0.0.1:%d'%server.server_port)
    server.serve_forever()


if __name__=='__main__':
    if sys.argv[1]=='serve': serve(*sys.argv[2:])
    elif sys.argv[1]=='request':
        print(json.dumps(request(sys.argv[2],sys.argv[3],json.loads(sys.argv[4]) if len(sys.argv)>4 else None)))
    elif sys.argv[1]=='observe':
        try: result=request(sys.argv[2],'/health')
        except (OSError,urllib.error.URLError) as exc: result={'health':'unknown','reason':str(exc),'observed_at':time.time()}
        Path(sys.argv[3]).write_text(json.dumps(result,indent=2)+'\n')
        print('release-local health='+result['health']+' evidence='+sys.argv[3])
