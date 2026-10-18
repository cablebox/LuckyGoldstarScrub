import json, subprocess, sys, time, urllib.request, websocket
CHROME = "/tmp/chrome-linux64/chrome"
URL = sys.argv[1]; BUDGET = int(sys.argv[2]) if len(sys.argv) > 2 else 600
proc = subprocess.Popen([CHROME, "--headless=new", "--no-sandbox", "--disable-gpu",
    "--user-data-dir=/tmp/cdp3", "--remote-debugging-port=9333", "--remote-allow-origins=*", URL],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def get_target():
    for _ in range(30):
        time.sleep(1)
        try:
            pages = json.load(urllib.request.urlopen("http://127.0.0.1:9333/json"))
            for p in pages:
                if p.get("type") == "page": return p["webSocketDebuggerUrl"]
        except Exception: pass
    return None
wsurl = get_target()
print("target:", bool(wsurl), flush=True)
ws = websocket.create_connection(wsurl, timeout=10)
ws.send(json.dumps({"id": 1, "method": "Runtime.enable"}))
start = time.time(); last = ""
def terminal(v):
    return ("exec!" in v) or ("WKERR" in v) or ("WK-CATCH" in v) or ("WK-UNCAUGHT" in v)
while time.time() - start < BUDGET:
    try:
        ws.settimeout(4)
        m = json.loads(ws.recv())
        if m.get("method") == "Runtime.consoleAPICalled":
            txt = " ".join(str(a.get("value", "")) for a in m["params"]["args"])
            print(f"[t+{int(time.time()-start)}s] CONSOLE: {txt[:200]}", flush=True)
    except websocket.WebSocketTimeoutException:
        pass
    except Exception:
        break
    try:
        ws.settimeout(2)
        ws.send(json.dumps({"id": 2, "method": "Runtime.evaluate",
                            "params": {"expression": "document.getElementById('sink') ? document.getElementById('sink').textContent : 'NOSINK'"}}))
        repl = json.loads(ws.recv())
        val = ""
        if "result" in repl and "result" in repl["result"]:
            val = repl["result"]["result"].get("value", "")
        if val and val != last:
            print(f"[t+{int(time.time()-start)}s] SINK: {val[:400]}", flush=True); last = val
            if terminal(val):
                print("TERMINAL STATE", flush=True); break
    except Exception:
        pass
proc.terminate()
print("finished", flush=True)
