"""AI usage collector for Rainmeter: Codex weekly quota + Claude plan usage.

Standard library only. Never starts a model turn. Writes panel-data.txt next to this file.
"""
import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import queue
import subprocess
import threading
import time

UTC = dt.timezone.utc
TAIPEI = dt.timezone(dt.timedelta(hours=8), "Asia/Taipei")


def epoch(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(value) and value > 0:
        return int(value)
    if isinstance(value, str):
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            return int(parsed.timestamp()) if parsed.tzinfo else None
        except ValueError:
            pass
    return None


def normalize(result):
    """Map by actual duration, never assume primary=5h or secondary=weekly."""
    buckets = result.get("rateLimitsByLimitId") or {}
    bucket = buckets.get("codex")
    if not bucket:
        candidate = result.get("rateLimits") or {}
        if candidate.get("limitId") in (None, "codex"):
            bucket = candidate
    out = {}
    for window in ((bucket or {}).get("primary"), (bucket or {}).get("secondary")):
        if not isinstance(window, dict):
            continue
        duration = window.get("windowDurationMins")
        key = {10080: "weekly"}.get(duration)
        used = window.get("usedPercent")
        if not key or isinstance(used, bool) or not isinstance(used, (int, float)):
            continue
        if not math.isfinite(used) or not 0 <= used <= 100:
            continue
        out[key] = {"remaining": round(100 - used, 1), "reset": epoch(window.get("resetsAt"))}
    return out


def find_codex(configured=None):
    """Configured path, else the native binary inside the npm install, else codex on PATH."""
    import shutil
    if configured and Path(configured).exists():
        return configured
    roaming = Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
    native = sorted((roaming / "npm" / "node_modules" / "@openai" / "codex").glob("**/codex.exe"))
    if native:
        return str(native[0])
    return shutil.which("codex")


def official_read(executable, timeout=18):
    # Documented app-server RPC (account/rateLimits/read), see read_quota.py.
    from read_quota import probe
    if not executable:
        raise ValueError("codex not found")
    return probe(executable=executable)


def snapshot_result(snapshot):
    if "windows" not in snapshot:
        return snapshot["result"], epoch(snapshot.get("observed_at"))
    bucket = {}
    for window in snapshot.get("windows", []):
        if isinstance(window, dict) and window.get("limitId") == "codex" and window.get("window") in ("primary", "secondary"):
            bucket[window["window"]] = window
    return {"rateLimitsByLimitId": {"codex": bucket}}, epoch(snapshot.get("checkedAtUtc"))


def claude_history_paths():
    # Claude Desktop is an MSIX app: its real AppData sits under Packages\Claude_*\LocalCache.
    local = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
    paths = sorted((local / "Packages").glob("Claude_*/LocalCache/Roaming/Claude/plan-usage-history.json"))
    roaming = Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
    return paths + [roaming / "Claude" / "plan-usage-history.json"]
WEEK = 7 * 86400


CLAUDE_CREDENTIALS = Path.home() / ".claude" / ".credentials.json"
CLAUDE_TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"


def http_json(url, body=None, headers=None, timeout=8):
    import urllib.request
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, headers={
        "Content-Type": "application/json", "User-Agent": "rainmeter-ai-usage", **(headers or {})})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def claude_api(now):
    """Official plan usage via the Claude Code login (same call the CLI makes). No model turns."""
    import urllib.error
    try:
        creds = read_json(CLAUDE_CREDENTIALS)
        oauth = creds.get("claudeAiOauth") or {}
        if not oauth.get("accessToken"):
            return {}
        if oauth.get("refreshToken") and (oauth.get("expiresAt") or 0) / 1000 < now + 120:
            fresh = http_json(CLAUDE_TOKEN_URL, {"grant_type": "refresh_token", "client_id": CLAUDE_CLIENT_ID,
                                                 "refresh_token": oauth["refreshToken"]})
            oauth.update(accessToken=fresh["access_token"],
                         refreshToken=fresh.get("refresh_token", oauth["refreshToken"]),
                         expiresAt=int((time.time() + int(fresh["expires_in"])) * 1000))
            creds["claudeAiOauth"] = oauth
            write_atomic(CLAUDE_CREDENTIALS, json.dumps(creds))
        usage = http_json(CLAUDE_USAGE_URL, headers={"Authorization": "Bearer " + oauth["accessToken"],
                                                     "anthropic-beta": "oauth-2025-04-20"})
        five, week = usage.get("five_hour") or {}, usage.get("seven_day") or {}
        if not all(isinstance(w.get("utilization"), (int, float)) for w in (five, week)):
            return {}
        out = {"claude_five": round(five["utilization"]), "claude_week": round(week["utilization"]),
               "claude_observed": now, "claude_source": "api",
               "claude_five_reset": epoch(five.get("resets_at")) or 0}
        if epoch(week.get("resets_at")):
            out["claude_reset"] = epoch(week["resets_at"])
        plan = (oauth.get("subscriptionType") or "").strip()
        if plan:
            out["claude_plan"] = plan[:1].upper() + plan[1:]
        return out
    except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError):
        return {}  # Never expose tokens or upstream errors.


def read_claude(now, manual):
    """Claude plan usage: official API when logged in, else Claude Desktop's cached samples."""
    out = {}
    try:
        samples = []
        for path in claude_history_paths():
            try:
                samples += read_json(path).get("samples") or []
            except (OSError, ValueError):
                pass
        latest = max((s for s in samples if isinstance(s, dict) and isinstance(s.get("u"), dict)),
                     key=lambda s: s.get("t", 0), default=None)
        if latest:
            u = latest["u"]
            five, seven = u.get("fh"), u.get("sd")
            if all(isinstance(v, (int, float)) and not isinstance(v, bool) and 0 <= v <= 100 for v in (five, seven)):
                out.update(claude_five=round(five), claude_week=round(seven),
                           claude_observed=int(latest.get("t", 0) / 1000))
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    anchor = manual.get("claude_weekly_anchor")
    if isinstance(anchor, (int, float)) and anchor > 0:
        anchor = int(anchor)
        if anchor <= now:
            anchor += ((now - anchor) // WEEK + 1) * WEEK
        out["claude_reset"] = anchor
    if out:
        out["claude_source"] = "desktop"
    out.update(claude_api(now))
    return out


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write_atomic(path, value):
    path = Path(path)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(value, encoding="utf-8")
    os.replace(temp, path)


def collect(resources, now=None):
    from lifecycle import SingleReader
    with SingleReader(Path(resources) / 'reader.lock'):
        return collect_locked(resources, now)


def collect_locked(resources, now=None):
    resources = Path(resources)
    fixed_now = now is not None
    now = int(time.time()) if now is None else now
    try:
        config = read_json(resources / "config.json")
    except (OSError, ValueError):
        config = {"source": "official_cli"}
    cache_path = resources / "quota-cache.json"
    try:
        cache = read_json(cache_path)
    except (OSError, ValueError):
        cache = {}
    success = False
    status_path = resources / 'producer-status.json'
    paused = (resources / 'paused.flag').exists()
    write_atomic(status_path, json.dumps({'pid':os.getpid(), 'active':not paused,
        'state':'stopped' if paused else 'reading', 'owner':'Rainmeter MeasurePoll',
        'model_turns':0, 'started_at':now}))
    try:
        if paused:
            raise RuntimeError('panel_updates_stopped')
        if config.get("source") == "official_cli":
            result, observed = snapshot_result(official_read(find_codex(config.get("codex_executable"))))
        elif config.get("source") == "snapshot":
            snapshot = read_json(config["snapshot_path"])
            result, observed = snapshot_result(snapshot)
            if observed is None or observed > now + 30:
                raise ValueError("invalid observation")
        else:
            raise ValueError("no source")
        windows = normalize(result)
        if not windows:
            raise ValueError("no supported quota windows")
        cache = {"observed_at": observed, "windows": windows, "source": config["source"],
                 "poll_sequence":cache.get("poll_sequence",0)+1}
        write_atomic(cache_path, json.dumps(cache, ensure_ascii=False))
        success = True
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, queue.Empty, subprocess.SubprocessError):
        pass  # Never expose auth, account IDs, raw upstream errors, or stderr.
    if not fixed_now:
        now = int(time.time())
    paused = (resources / 'paused.flag').exists()
    packet = {"refreshed_at": now, "observed_at": cache.get("observed_at", 0),
              "fetch_ok": int(success and not paused), "source": cache.get("source", "none"), "stale_seconds": 180,
              "polling_state":"stopped" if paused else 'active', "poll_sequence":cache.get("poll_sequence",0)}
    for key in ("weekly",):
        window = cache.get("windows", {}).get(key, {})
        packet[key + "_remaining"] = window.get("remaining", "")
        packet[key + "_reset"] = window.get("reset") or 0
    try:
        manual = read_json(resources / "manual.json")
    except (OSError, ValueError):
        manual = {}
    for key in ("claude_reset", "bank_cards"):
        if key in manual and manual[key] not in (None, ""):
            packet[key] = manual[key]
    packet.update(read_claude(now, manual))
    # Packet is inert UTF-8 data, not a Rainmeter include or executable script.
    write_atomic(resources / "panel-data.txt", "\n".join(f"{k}={v}" for k, v in packet.items()) + "\n")
    write_atomic(status_path, json.dumps({'pid':os.getpid(), 'active':False,
        'state':'stopped' if paused else ('success' if success else 'source_unavailable'),
        'owner':'Rainmeter MeasurePoll', 'model_turns':0, 'completed_at':now,
        'observed_at':cache.get('observed_at',0), 'poll_sequence':cache.get('poll_sequence',0)}))
    return packet


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--resources", type=Path, default=Path(__file__).parent)
    parser.add_argument('--pause',action='store_true')
    parser.add_argument('--resume',action='store_true')
    args = parser.parse_args()
    try:
        if args.pause or args.resume:
            flag = args.resources/'paused.flag'
            if args.pause:
                flag.touch()
            elif flag.exists():
                flag.unlink()
            packet_path = args.resources/'panel-data.txt'
            if packet_path.exists():
                packet = dict(line.split('=',1) for line in packet_path.read_text(encoding='utf-8').splitlines())
                packet.update(fetch_ok=0,polling_state='stopped' if args.pause else 'active')
                write_atomic(packet_path,'\n'.join(f'{k}={v}' for k,v in packet.items())+'\n')
        else:
            collect(args.resources)
    except (OSError, ValueError, RuntimeError):
        raise SystemExit(1)
