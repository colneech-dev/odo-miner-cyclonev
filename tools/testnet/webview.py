#!/usr/bin/env python3
"""
webview.py — lightweight web status page for the OdoCrypt test bed.

A stdlib-only replacement for the old Flask `web.py` (no pip packages). Serves
a self-refreshing dashboard showing the regtest/testnet chain height, the live
OdoCrypt job (odokey + target), and blocks mined this session.

Talks to the node over JSON-RPC using the same env vars as the rest of the
harness: ODO_RPC_URL, ODO_RPC_USER, ODO_RPC_PASS.

Usage: python3 webview.py [port]          (default 8080)
Started automatically by run_testbed.py; browse to http://127.0.0.1:8080.
"""

import os
import sys
import json
import base64
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RPC_URL = os.environ.get("ODO_RPC_URL", "http://127.0.0.1:18443/")
RPC_USER = os.environ.get("ODO_RPC_USER", "user")
RPC_PASS = os.environ.get("ODO_RPC_PASS", "pass")
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

_start_height = None


def rpc(method, params=None):
    body = json.dumps({"jsonrpc": "1.0", "id": "web", "method": method,
                       "params": params or []}).encode()
    req = urllib.request.Request(RPC_URL, data=body,
                                 headers={"Content-Type": "application/json"})
    tok = base64.b64encode(f"{RPC_USER}:{RPC_PASS}".encode()).decode()
    req.add_header("Authorization", "Basic " + tok)
    with urllib.request.urlopen(req, timeout=10) as r:
        resp = json.load(r)
    if resp.get("error"):
        raise RuntimeError(resp["error"])
    return resp["result"]


def status():
    global _start_height
    out = {"ok": False}
    try:
        info = rpc("getblockchaininfo")
        h = info["blocks"]
        if _start_height is None:
            _start_height = h
        out.update(chain=info["chain"], height=h,
                   mined=h - _start_height, ok=True)
        try:
            t = rpc("getblocktemplate", [{"rules": ["segwit"]}, "odo"])
            out.update(pow_algo=t.get("pow_algo"), odokey=t.get("odokey"),
                       target=t.get("target", "")[:16] + "...",
                       next_height=t.get("height"))
        except Exception as e:
            out["job"] = f"odo template unavailable: {e}"
    except Exception as e:
        out["error"] = str(e)
    return out


PAGE = """<!DOCTYPE html><html><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>OdoCrypt test bed</title><style>
body{font-family:system-ui,sans-serif;background:#0a1228;color:#e2e8f6;margin:0;
padding:18px;max-width:520px;margin-inline:auto}
h1{font-size:20px;color:#38c8f0;margin:6px 0 14px}
.card{background:#121f44;border:1px solid #1d2f63;border-radius:10px;padding:14px 16px;margin-bottom:12px}
.big{font-size:30px;font-weight:600;color:#38c8f0}
.row{display:flex;justify-content:space-between;padding:3px 0;font-size:14px}
.row span:first-child{color:#7684a8}.bad{color:#f07878}
</style></head><body>
<h1>OdoCrypt test bed</h1>
<div class='card'><div class='row'><span>Chain</span><span id='chain'>-</span></div>
<div class='row'><span>Block height</span><span class='big' id='height'>-</span></div>
<div class='row'><span>Blocks mined this session</span><span id='mined'>-</span></div></div>
<div class='card'><div class='row'><span>PoW algo</span><span id='algo'>-</span></div>
<div class='row'><span>OdoCrypt key (epoch)</span><span id='odokey'>-</span></div>
<div class='row'><span>Target</span><span id='target'>-</span></div>
<div class='row'><span>Next block height</span><span id='next'>-</span></div></div>
<div class='card' id='note'></div>
<script>
function tick(){fetch('/status.json').then(r=>r.json()).then(s=>{
 var n=document.getElementById('note');
 if(s.error){n.innerHTML="<span class='bad'>node: "+s.error+"</span>";return;}
 n.textContent='';
 document.getElementById('chain').textContent=s.chain||'-';
 document.getElementById('height').textContent=s.height;
 document.getElementById('mined').textContent=s.mined;
 document.getElementById('algo').textContent=s.pow_algo||'-';
 document.getElementById('odokey').textContent=s.odokey||'-';
 document.getElementById('target').textContent=s.target||'-';
 document.getElementById('next').textContent=s.next_height||'-';
 if(s.job)n.textContent=s.job;
}).catch(e=>{document.getElementById('note').textContent=e;});}
tick();setInterval(tick,2000);
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/status.json"):
            body = json.dumps(status()).encode()
            ctype = "application/json"
        else:
            body = PAGE.encode()
            ctype = "text/html"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), H)
    print(f"web view on http://127.0.0.1:{PORT}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
