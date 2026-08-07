#!/usr/bin/env python3
import json
import os
import re
import subprocess
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


def send_chat(prompt, max_tokens=256, reasoning_effort="none"):
    payload = {
        "model": "deepseek-v4-flash",
        "messages": [{"role": "user", "content": prompt}],
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
    tokens = int(usage.get("completion_tokens") or max(1, len(content.split())))
    return {
        "content": content,
        "elapsed_s": round(elapsed, 3),
        "tokens": tokens,
        "tok_per_s": round(tokens / elapsed, 2),
        "raw_usage": usage,
    }


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

    def do_GET(self):
        if self.path == "/api/stats":
            self.send_json(collect_stats())
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
        if self.path != "/api/chat":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
            prompt = str(data.get("prompt") or "")
            if not prompt.strip():
                raise ValueError("empty prompt")
            result = send_chat(
                prompt,
                max_tokens=int(data.get("max_tokens") or 256),
                reasoning_effort=str(data.get("reasoning_effort") or "none"),
            )
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
