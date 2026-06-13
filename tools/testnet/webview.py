#!/usr/bin/env python3
"""
webview.py — full web dashboard for the OdoCrypt test bed (stdlib only).

Feature-parity replacement for the old Flask + flask-socketio `web.py`, with
NO pip dependencies (Chart.js loads in the browser from a CDN; the server is
Python's http.server). Shows:
  - shares + blocks counters and a live hashrate chart
  - a scrolling live-shares table (time / diff / result)
  - the current OdoCrypt job (id, prevhash, merkle, nbits, ntime, odokey, txs)
  - block-explorer info (chain, height, best block, difficulty, chainwork)
  - a flashing + beeping "BLOCK FOUND!" banner

Reads mining stats from the file the bridge writes (ODO_STATS_FILE, default in
the temp dir) and the chain/job from the node via JSON-RPC (ODO_RPC_*).

Usage: python3 webview.py [port]          (default 8080)
"""

import os
import sys
import json
import base64
import tempfile
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RPC_URL = os.environ.get("ODO_RPC_URL", "http://127.0.0.1:18443/")
RPC_USER = os.environ.get("ODO_RPC_USER", "user")
RPC_PASS = os.environ.get("ODO_RPC_PASS", "pass")
STATS_FILE = os.environ.get(
    "ODO_STATS_FILE", os.path.join(tempfile.gettempdir(), "odo_testbed_stats.json"))
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080


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


def read_stats():
    try:
        with open(STATS_FILE) as f:
            return json.load(f)
    except Exception:
        return {"shares": 0, "blocks": 0, "hashrate": [], "recent": [], "job": {}}


def status():
    out = {"stats": read_stats()}
    try:
        out["chain"] = rpc("getblockchaininfo")
    except Exception as e:
        out["chain_error"] = str(e)
    return out


PAGE = """<!DOCTYPE html><html><head><meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>OdoCrypt test bed</title><style>
body{font-family:system-ui,sans-serif;background:#0a1228;color:#e2e8f6;margin:0;
padding:18px;max-width:760px;margin-inline:auto}
h1{font-size:21px;color:#38c8f0;margin:6px 0 14px}
h2{font-size:15px;color:#7684a8;margin:18px 0 8px;font-weight:500}
.card{background:#121f44;border:1px solid #1d2f63;border-radius:10px;padding:14px 16px;margin-bottom:12px}
.grid{display:flex;gap:24px;flex-wrap:wrap}
.stat .n{font-size:30px;font-weight:600;color:#38c8f0}.stat .l{font-size:12px;color:#7684a8}
.row{display:flex;justify-content:space-between;padding:3px 0;font-size:13px}
.row span:first-child{color:#7684a8}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:4px 6px;border-bottom:1px solid #1d2f63}
th{color:#7684a8;font-weight:500}
.tw{max-height:200px;overflow:auto}
.block{color:#52d68a}.rej{color:#f07878}
#banner{display:none;background:#16331f;color:#52d68a;border:1px solid #2f7d4a;
border-radius:10px;padding:12px;text-align:center;font-size:20px;font-weight:600;margin-bottom:12px}
.mono{font-family:ui-monospace,monospace;font-size:12px;word-break:break-all}
</style></head><body>
<h1>OdoCrypt test bed</h1>
<div id='banner'>BLOCK FOUND!</div>
<div class='card grid'>
 <div class='stat'><div class='n' id='shares'>0</div><div class='l'>SHARES</div></div>
 <div class='stat'><div class='n' id='blocks'>0</div><div class='l'>BLOCKS</div></div>
 <div class='stat'><div class='n' id='height'>-</div><div class='l'>HEIGHT</div></div>
 <div class='stat'><div class='n' id='rate'>-</div><div class='l'>HASHRATE</div></div>
</div>
<div class='card'><h2 style='margin-top:0'>Hashrate</h2><canvas id='chart' height='90'></canvas></div>
<div class='card'><h2 style='margin-top:0'>Live shares</h2>
 <div class='tw'><table id='shares_t'><thead><tr><th>Time</th><th>Diff</th><th>Result</th></tr></thead><tbody></tbody></table></div></div>
<div class='card'><h2 style='margin-top:0'>Current job</h2><div id='job'>-</div></div>
<div class='card'><h2 style='margin-top:0'>Chain</h2><div id='chain'>-</div></div>
<script src='/chart.min.js'></script>
<script>
let chart=null, prevBlocks=0, started=false;
function fmtRate(h){if(!h)return '-';if(h>=1e9)return (h/1e9).toFixed(1)+' GH/s';
 if(h>=1e6)return (h/1e6).toFixed(1)+' MH/s';if(h>=1e3)return (h/1e3).toFixed(1)+' kH/s';return h+' H/s';}
function rows(obj){return Object.entries(obj).map(([k,v])=>
 `<div class='row'><span>${k}</span><span class='mono'>${v}</span></div>`).join('');}
function beep(){try{var a=new (window.AudioContext||window.webkitAudioContext)();
 var o=a.createOscillator(),g=a.createGain();o.connect(g);g.connect(a.destination);
 o.type='sine';o.frequency.value=880;g.gain.value=0.12;o.start();
 setTimeout(()=>{o.stop();a.close();},180);}catch(e){}}
function banner(){var b=document.getElementById('banner');b.style.display='block';
 b.animate([{opacity:.2},{opacity:1}],{duration:400,iterations:5});
 beep();
 setTimeout(()=>{b.style.display='none';},4000);}
function tick(){fetch('/status.json').then(r=>r.json()).then(d=>{
 var s=d.stats||{}, c=d.chain||{};
 document.getElementById('shares').textContent=s.shares||0;
 document.getElementById('blocks').textContent=s.blocks||0;
 document.getElementById('height').textContent=c.blocks!==undefined?c.blocks:'-';
 var hr=(s.hashrate||[]); document.getElementById('rate').textContent=fmtRate(hr[hr.length-1]);
 if(!chart){chart=new Chart(document.getElementById('chart'),{type:'line',
   data:{labels:hr.map((_,i)=>i),datasets:[{label:'H/s',data:hr,borderColor:'#38c8f0',tension:.2,pointRadius:0}]},
   options:{animation:false,plugins:{legend:{display:false}},scales:{x:{display:false},y:{ticks:{color:'#7684a8'}}}}});}
 else{chart.data.labels=hr.map((_,i)=>i);chart.data.datasets[0].data=hr;chart.update();}
 var tb=document.querySelector('#shares_t tbody');tb.innerHTML=(s.recent||[]).slice().reverse().map(r=>
   `<tr><td>${r.time}</td><td>${r.diff}</td><td class='${r.result==="block"?"block":(r.result==="rejected"?"rej":"")}'>${r.result}</td></tr>`).join('');
 document.getElementById('job').innerHTML=s.job&&s.job.job_id?rows(s.job):'(waiting for a miner)';
 document.getElementById('chain').innerHTML=c.chain?rows({chain:c.chain,height:c.blocks,
   bestblock:c.bestblockhash,difficulty:c.difficulty,chainwork:(c.chainwork||'').slice(-16)}):
   (d.chain_error?('<span class=rej>node: '+d.chain_error+'</span>'):'-');
 if(started && (s.blocks||0)>prevBlocks) banner();
 prevBlocks=s.blocks||0; started=true;
}).catch(()=>{});}
tick();setInterval(tick,2000);
</script></body></html>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/status.json"):
            body = json.dumps(status()).encode()
            ctype = "application/json"
        elif self.path.startswith("/chart.min.js"):
            # served locally — no CDN, works offline
            try:
                with open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       "static", "chart.min.js"), "rb") as f:
                    body = f.read()
            except OSError:
                self.send_error(404)
                return
            ctype = "application/javascript"
        else:
            body = PAGE.encode()
            ctype = "text/html"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        cache = "max-age=86400" if self.path.startswith("/chart") else "no-store"
        self.send_header("Cache-Control", cache)
        self.end_headers()
        self.wfile.write(body)


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), H)
    print(f"web view on http://127.0.0.1:{PORT}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.shutdown()
        srv.server_close()


if __name__ == "__main__":
    main()
