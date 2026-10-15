"""Read-only documented app-server RPC; never creates threads or model turns."""
import argparse
import datetime as dt
import json
import pathlib
import queue
import subprocess
import threading
import time
from lifecycle import ProcessJob

ROOT = pathlib.Path(__file__).resolve().parent

def probe(mode="stdio", executable=None):
    proc = subprocess.Popen(
        [executable, "app-server", "--stdio"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW,
    )
    job = ProcessJob(proc)
    inbox = queue.Queue()
    def read():
        for line in proc.stdout:
            try:
                inbox.put(json.loads(line))
            except (ValueError, TypeError):
                pass
        inbox.put(None)
    threading.Thread(target=read, daemon=True).start()
    def send(message):
        proc.stdin.write(json.dumps(message) + "\n")
        proc.stdin.flush()
    def response(rpc_id, timeout=18):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            item = inbox.get(timeout=max(.1, deadline-time.monotonic()))
            if item is None:
                raise RuntimeError("app-server closed before RPC response")
            if item.get("id") == rpc_id:
                if "error" in item:
                    err = item["error"]
                    # No raw server output is retained, including auth notifications.
                    raise RuntimeError("source_unavailable")
                return item.get("result", {})
        raise TimeoutError("RPC timeout")
    try:
        send({"id":1,"method":"initialize","params":{"clientInfo":{"name":"rainmeter_codex_quota","title":"Rainmeter quota reader","version":"1.1"}}})
        response(1)
        send({"method":"initialized","params":{}})
        send({"id":2,"method":"account/rateLimits/read"})
        result = response(2)
        buckets = result.get("rateLimitsByLimitId") or {"codex":result.get("rateLimits")}
        windows=[]
        for bucket_id, bucket in buckets.items():
            if not isinstance(bucket, dict):
                continue
            for window_name in ("primary","secondary"):
                w=bucket.get(window_name)
                if not isinstance(w,dict):
                    continue
                used=w.get("usedPercent")
                resets=w.get("resetsAt")
                windows.append({"limitId":bucket_id,"window":window_name,
                    "usedPercent":used,"remainingPercent":100-used if isinstance(used,(int,float)) else None,
                    "windowDurationMins":w.get("windowDurationMins"),"resetsAt":resets,
                    "resetTaipei":dt.datetime.fromtimestamp(resets,dt.timezone(dt.timedelta(hours=8))).isoformat() if isinstance(resets,(int,float)) else None})
        safe={"checkedAtUtc":dt.datetime.now(dt.timezone.utc).isoformat(),"source":"documented account/rateLimits/read","transport":mode,"unit":"percent","windows":windows,"status":"measured" if windows else "no_quota_windows"}
        output=ROOT/"panel-usage.json"
        temp=ROOT/"panel-usage.tmp.json"
        temp.write_text(json.dumps(safe,ensure_ascii=False,indent=2),encoding="utf-8")
        temp.replace(output)
        return safe
    finally:
        try:
            proc.stdin.close()
            proc.wait(timeout=2)
        except Exception:
            # This is only the read-only helper process created above.
            proc.kill()
            proc.wait(timeout=2)
        job.close()

if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--mode",choices=["stdio","proxy"],default="stdio")
    args=parser.parse_args()
    try:
        print(json.dumps(probe(args.mode),ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({"status":"blocked","error":str(exc)},ensure_ascii=False))
        raise SystemExit(1)
