#!/usr/bin/env python3
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "web"
DS4_BASE = os.environ.get("DS4_BASE", "http://127.0.0.1:8000")
DASHBOARD_HOST = os.environ.get("DASHBOARD_HOST", "127.0.0.1")
DASHBOARD_PORT = int(os.environ.get("DASHBOARD_PORT", "8791"))
LAUNCH_LABEL = os.environ.get("LAUNCH_LABEL", "ai.deepseek-v4-local")
EXPERT_CACHE = os.environ.get("EXPERT_CACHE", "24GB")
SERVER_CTX = int(os.environ.get("SERVER_CTX", "16384"))
STATUS_INTERVAL = float(os.environ.get("STATUS_INTERVAL", "1.0"))

STATUS_LOCK = threading.Lock()
STATUS_STATE = {
    "active_requests": 0,
    "request_seq": 0,
    "last_chat": None,
    "last_error": None,
}


def run_text(argv):
    return subprocess.check_output(argv, text=True, stderr=subprocess.DEVNULL)


def parse_gib(value):
    m = re.match(r"^([0-9.]+)\s*GB$", value.strip(), re.I)
    return float(m.group(1)) if m else None


def launch_pid():
    try:
        out = run_text(["launchctl", "print", f"gui/{os.getuid()}/{LAUNCH_LABEL}"])
    except Exception:
        return None
    m = re.search(r"\bpid = (\d+)", out)
    return int(m.group(1)) if m else None


def process_stats(pid):
    if not pid:
        return {"pid": None, "rss_gib": 0, "cpu_percent": 0, "mem_percent": 0}
    try:
        out = run_text(["ps", "-o", "pid,%cpu,%mem,rss,command", "-p", str(pid)])
    except Exception:
        return {"pid": pid, "rss_gib": 0, "cpu_percent": 0, "mem_percent": 0}
    lines = [line for line in out.splitlines() if line.strip()]
    if len(lines) < 2:
        return {"pid": pid, "rss_gib": 0, "cpu_percent": 0, "mem_percent": 0}
    parts = lines[1].split(None, 4)
    rss_kib = int(parts[3])
    return {
        "pid": int(parts[0]),
        "cpu_percent": float(parts[1]),
        "mem_percent": float(parts[2]),
        "rss_gib": round(rss_kib / 1024 / 1024, 2),
        "command": parts[4] if len(parts) > 4 else "",
    }


def swap_stats():
    try:
        out = run_text(["sysctl", "vm.swapusage"])
    except Exception:
        return {"total_gib": 0, "used_gib": 0, "free_gib": 0}
    m = re.search(r"total = ([0-9.]+)M\s+used = ([0-9.]+)M\s+free = ([0-9.]+)M", out)
    if not m:
        return {"total_gib": 0, "used_gib": 0, "free_gib": 0}
    return {
        "total_gib": round(float(m.group(1)) / 1024, 2),
        "used_gib": round(float(m.group(2)) / 1024, 2),
        "free_gib": round(float(m.group(3)) / 1024, 2),
    }


def memory_free_percent():
    try:
        out = run_text(["memory_pressure"])
    except Exception:
        return None
    m = re.search(r"System-wide memory free percentage:\s+(\d+)%", out)
    return int(m.group(1)) if m else None


def disk_stats():
    try:
        out = run_text(["df", "-k", str(ROOT)])
    except Exception:
        return {"available_gib": 0, "capacity": ""}
    lines = [line for line in out.splitlines() if line.strip()]
    if len(lines) < 2:
        return {"available_gib": 0, "capacity": ""}
    parts = lines[1].split()
    return {
        "available_gib": round(int(parts[3]) / 1024 / 1024, 2),
        "capacity": parts[4],
    }


def collect_stats():
    pid = launch_pid()
    swap = swap_stats()
    return {
        "server": process_stats(pid),
        "system": {
            "memory_free_percent": memory_free_percent(),
            "swap": swap,
            "swap_used_gib": swap["used_gib"],
            "disk": disk_stats(),
        },
        "model": {
            "expert_budget_gib": parse_gib(EXPERT_CACHE),
            "ctx": SERVER_CTX,
            "base_url": DS4_BASE,
        },
        "ts": time.time(),
    }


def note_chat_start():
    with STATUS_LOCK:
        STATUS_STATE["active_requests"] += 1
        STATUS_STATE["request_seq"] += 1
        STATUS_STATE["last_error"] = None
        return STATUS_STATE["request_seq"]


def note_chat_done(result):
    now = time.time()
    snapshot = {
        "ts": now,
        "tokens": int(result.get("tokens") or 0),
        "tok_per_s": float(result.get("tok_per_s") or 0),
        "elapsed_s": float(result.get("elapsed_s") or 0),
        "cached_tokens": int(result.get("cached_tokens") or 0),
        "cache_write_tokens": int(result.get("cache_write_tokens") or 0),
    }
    with STATUS_LOCK:
        STATUS_STATE["active_requests"] = max(0, STATUS_STATE["active_requests"] - 1)
        STATUS_STATE["last_chat"] = snapshot
        STATUS_STATE["last_error"] = None


def note_chat_end_without_usage(error=None):
    with STATUS_LOCK:
        STATUS_STATE["active_requests"] = max(0, STATUS_STATE["active_requests"] - 1)
        if error:
            STATUS_STATE["last_error"] = {"ts": time.time(), "message": str(error)}


def status_snapshot():
    with STATUS_LOCK:
        return {
            "active_requests": STATUS_STATE["active_requests"],
            "request_seq": STATUS_STATE["request_seq"],
            "last_chat": dict(STATUS_STATE["last_chat"] or {}),
            "last_error": dict(STATUS_STATE["last_error"] or {}),
        }


def expert_cache_activity(stats, snapshot=None):
    snapshot = snapshot or status_snapshot()
    last = snapshot["last_chat"] or {}
    active = int(snapshot["active_requests"] or 0)
    cached = int(last.get("cached_tokens") or 0)
    writes = int(last.get("cache_write_tokens") or 0)
    age_s = max(0.0, time.time() - float(last.get("ts") or 0)) if last else None
    recent_strength = 0 if age_s is None else max(0.0, 1.0 - min(age_s, 12.0) / 12.0)
    cpu = float(((stats.get("server") or {}).get("cpu_percent")) or 0)
    rss = float(((stats.get("server") or {}).get("rss_gib")) or 0)
    budget = float(((stats.get("model") or {}).get("expert_budget_gib")) or 0)
    pressure = min(1.0, rss / budget) if budget > 0 else 0.0
    active_slots = min(16, max(active * 4, int(round(min(cpu, 100.0) / 100.0 * 16))))
    read_slots = min(16, int(round(min(cached, 4096) / 4096 * 16))) if cached else 0
    write_slots = min(16, int(round(min(writes, 2048) / 2048 * 16))) if writes else 0
    if recent_strength > 0 and cached > 0:
        read_slots = max(1, read_slots)
    if recent_strength > 0 and writes > 0:
        write_slots = max(1, write_slots)
    nodes = []
    for idx in range(16):
        state = "idle"
        strength = pressure * 0.35
        if idx < write_slots and recent_strength > 0:
            state = "write"
            strength = max(strength, 0.55 + recent_strength * 0.45)
        elif idx < read_slots and recent_strength > 0:
            state = "read"
            strength = max(strength, 0.45 + recent_strength * 0.35)
        elif idx < active_slots:
            state = "active"
            strength = max(strength, 0.35 + min(cpu, 100.0) / 100.0 * 0.45)
        nodes.append({
            "id": f"cache-lane-{idx + 1:02d}",
            "label": f"Cache lane {idx + 1}",
            "state": state,
            "strength": round(min(1.0, strength), 3),
        })
    return {
        "exact_events": False,
        "source": "openai_usage_and_process_stats",
        "active_requests": active,
        "last_cached_tokens": cached,
        "last_cache_write_tokens": writes,
        "last_tokens": int(last.get("tokens") or 0),
        "last_tok_per_s": float(last.get("tok_per_s") or 0),
        "last_elapsed_s": float(last.get("elapsed_s") or 0),
        "last_age_s": None if age_s is None else round(age_s, 2),
        "pressure": round(pressure, 3),
        "nodes": nodes,
    }


def status_event():
    stats = collect_stats()
    snapshot = status_snapshot()
    return {
        "type": "status",
        "ts": time.time(),
        "stats": stats,
        "expert_cache": expert_cache_activity(stats, snapshot),
    }


def status_stream_events(interval=STATUS_INTERVAL):
    while True:
        yield status_event()
        time.sleep(max(float(interval), 0.2))


def normalize_messages(value):
    if isinstance(value, list):
        out = []
        for item in value:
            if not isinstance(item, dict):
                raise ValueError("message must be an object")
            role = item.get("role")
            content = item.get("content")
            if role not in ("system", "user", "assistant", "tool"):
                raise ValueError("unsupported message role")
            if not isinstance(content, str) or not content.strip():
                raise ValueError("message content must be non-empty text")
            out.append({"role": role, "content": content})
        if not out:
            raise ValueError("messages cannot be empty")
        return out
    prompt = str(value or "")
    if not prompt.strip():
        raise ValueError("empty prompt")
    return [{"role": "user", "content": prompt}]


def send_chat(messages, max_tokens=256, reasoning_effort="none"):
    payload = {
        "model": "deepseek-v4-flash",
        "messages": normalize_messages(messages),
        "max_tokens": int(max_tokens),
        "temperature": 0,
        "reasoning_effort": reasoning_effort,
        "stream": False,
    }
    req = urllib.request.Request(
        f"{DS4_BASE}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=1800) as resp:
        data = json.loads(resp.read())
    elapsed = max(time.perf_counter() - start, 0.001)
    content = data["choices"][0]["message"].get("content") or ""
    usage = data.get("usage") or {}
    details = usage.get("prompt_tokens_details") or {}
    tokens = int(usage.get("completion_tokens") or max(1, len(content.split())))
    return {
        "content": content,
        "elapsed_s": round(elapsed, 3),
        "tokens": tokens,
        "tok_per_s": round(tokens / elapsed, 2),
        "cached_tokens": int(details.get("cached_tokens") or 0),
        "cache_write_tokens": int(details.get("cache_write_tokens") or 0),
        "raw_usage": usage,
    }


def chat_request(messages, max_tokens=256, reasoning_effort="none", stream=False):
    payload = {
        "model": "deepseek-v4-flash",
        "messages": normalize_messages(messages),
        "max_tokens": int(max_tokens),
        "temperature": 0,
        "reasoning_effort": reasoning_effort,
        "stream": bool(stream),
    }
    if stream:
        payload["stream_options"] = {"include_usage": True}
    return urllib.request.Request(
        f"{DS4_BASE}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )


def parse_openai_sse(lines, elapsed_s):
    final_usage = None
    for raw in lines:
        if isinstance(raw, bytes):
            line = raw.decode("utf-8", "replace")
        else:
            line = raw
        line = line.strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        obj = json.loads(data)
        choices = obj.get("choices") or []
        if choices:
            delta = choices[0].get("delta") or {}
            content = delta.get("content")
            if content:
                yield {"type": "delta", "content": content}
        usage = obj.get("usage")
        if usage:
            final_usage = usage
    if final_usage is not None:
        details = final_usage.get("prompt_tokens_details") or {}
        tokens = int(final_usage.get("completion_tokens") or 0)
        elapsed_s = max(float(elapsed_s), 0.001)
        yield {
            "type": "done",
            "elapsed_s": round(elapsed_s, 3),
            "tokens": tokens,
            "tok_per_s": round(tokens / elapsed_s, 2),
            "cached_tokens": int(details.get("cached_tokens") or 0),
            "cache_write_tokens": int(details.get("cache_write_tokens") or 0),
            "raw_usage": final_usage,
        }


def openai_sse_events(messages, max_tokens=256, reasoning_effort="none"):
    req = chat_request(messages, max_tokens, reasoning_effort, stream=True)
    start = time.perf_counter()
    with urllib.request.urlopen(req, timeout=1800) as resp:
        for event in parse_openai_sse(resp, elapsed_s=0.001):
            if event["type"] == "done":
                event["elapsed_s"] = round(max(time.perf_counter() - start, 0.001), 3)
                if event["tokens"]:
                    event["tok_per_s"] = round(event["tokens"] / event["elapsed_s"], 2)
            yield event


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_ndjson(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for event in events:
            self.wfile.write(json.dumps(event).encode() + b"\n")
            self.wfile.flush()

    def send_sse(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        try:
            for event in events:
                self.wfile.write(b"data: " + json.dumps(event).encode() + b"\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return

    def do_GET(self):
        if self.path == "/api/stats":
            self.send_json(collect_stats())
            return
        if self.path == "/api/status-stream":
            self.send_sse(status_stream_events())
            return
        if self.path == "/":
            path = WEB / "index.html"
        else:
            path = (WEB / self.path.lstrip("/")).resolve()
            if WEB not in path.parents and path != WEB:
                self.send_error(404)
                return
        if not path.exists() or not path.is_file():
            self.send_error(404)
            return
        ctype = "text/html" if path.suffix == ".html" else "application/javascript" if path.suffix == ".js" else "text/css"
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path not in ("/api/chat", "/api/chat-stream"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
            messages = data.get("messages")
            if messages is None:
                messages = data.get("prompt")
            max_tokens = int(data.get("max_tokens") or 256)
            reasoning_effort = str(data.get("reasoning_effort") or "none")
            if self.path == "/api/chat-stream":
                def events():
                    final_seen = False
                    error = None
                    note_chat_start()
                    try:
                        for event in openai_sse_events(messages, max_tokens, reasoning_effort):
                            if event["type"] == "done":
                                note_chat_done(event)
                                final_seen = True
                            yield event
                    except Exception as exc:
                        error = exc
                        yield {"type": "error", "error": str(exc)}
                    finally:
                        if not final_seen:
                            note_chat_end_without_usage(error)
                self.send_ndjson(events())
                return
            note_chat_start()
            try:
                result = send_chat(messages, max_tokens=max_tokens, reasoning_effort=reasoning_effort)
                note_chat_done(result)
            except Exception as exc:
                note_chat_end_without_usage(exc)
                raise
            result["stats"] = collect_stats()
            self.send_json(result)
        except Exception as exc:
            self.send_json({"error": str(exc)}, status=500)


def main():
    httpd = ThreadingHTTPServer((DASHBOARD_HOST, DASHBOARD_PORT), Handler)
    print(f"dashboard listening on http://{DASHBOARD_HOST}:{DASHBOARD_PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
