#!/usr/bin/env python3
import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


def redact_headers(headers):
    out = {}
    for key, value in headers.items():
        if key.lower() in {"authorization", "x-api-key", "api-key"}:
            out[key] = "<redacted>"
        else:
            out[key] = value
    return out


def summarize_body(body):
    if not isinstance(body, dict):
        return {"type": type(body).__name__}
    messages = body.get("messages") or []
    tools = body.get("tools") or []
    summary = {
        "model": body.get("model"),
        "stream": body.get("stream"),
        "max_tokens": body.get("max_tokens"),
        "temperature": body.get("temperature"),
        "reasoning_effort": body.get("reasoning_effort"),
        "message_count": len(messages),
        "tools_count": len(tools),
    }
    roles = []
    char_count = 0
    for message in messages:
        if isinstance(message, dict):
            roles.append(message.get("role"))
            content = message.get("content")
            if isinstance(content, str):
                char_count += len(content)
            elif isinstance(content, list):
                char_count += sum(len(str(item)) for item in content)
    summary["roles"] = roles
    summary["message_chars"] = char_count
    return summary


def make_handler(target_base, log_path):
    target_base = target_base.rstrip("/")
    log_path.parent.mkdir(parents=True, exist_ok=True)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            self.forward()

        def do_POST(self):
            self.forward()

        def forward(self):
            started = time.time()
            length = int(self.headers.get("content-length", "0") or "0")
            raw_body = self.rfile.read(length) if length else b""
            parsed_body = None
            if raw_body:
                try:
                    parsed_body = json.loads(raw_body)
                except json.JSONDecodeError:
                    parsed_body = raw_body.decode("utf-8", "replace")

            event = {
                "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "method": self.command,
                "path": self.path,
                "headers": redact_headers(dict(self.headers.items())),
                "summary": summarize_body(parsed_body),
                "body": parsed_body,
            }
            with log_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(event, ensure_ascii=False) + "\n")

            print(
                f"[{event['ts']}] {self.command} {self.path} "
                f"{json.dumps(event['summary'], ensure_ascii=False)}",
                flush=True,
            )

            target_url = target_base + self.path
            headers = {
                key: value
                for key, value in self.headers.items()
                if key.lower()
                not in {"host", "content-length", "connection", "accept-encoding"}
            }
            request = urllib.request.Request(
                target_url,
                data=raw_body if self.command not in {"GET", "HEAD"} else None,
                headers=headers,
                method=self.command,
            )

            try:
                with urllib.request.urlopen(request, timeout=None) as response:
                    self.send_response(response.status)
                    response_headers = response.headers
                    for key, value in response_headers.items():
                        if key.lower() in {"connection", "transfer-encoding"}:
                            continue
                        self.send_header(key, value)
                    self.send_header("Connection", "close")
                    self.end_headers()
                    while True:
                        chunk = response.read(64 * 1024)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
            except urllib.error.HTTPError as exc:
                body = exc.read()
                self.send_response(exc.code)
                for key, value in exc.headers.items():
                    if key.lower() in {"connection", "transfer-encoding"}:
                        continue
                    self.send_header(key, value)
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            except Exception as exc:
                payload = json.dumps({"error": str(exc)}, ensure_ascii=False).encode()
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
            finally:
                elapsed = time.time() - started
                print(f"[proxy] {self.command} {self.path} completed in {elapsed:.3f}s", flush=True)

    return Handler


def main():
    default_log = (
        Path(__file__).resolve().parents[1] / "run" / "openai-request-proxy.log"
    )
    parser = argparse.ArgumentParser(description="Log OpenAI-compatible requests and proxy them to ds4.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8010)
    parser.add_argument("--target", default="http://127.0.0.1:8000")
    parser.add_argument("--log", default=str(default_log))
    args = parser.parse_args()

    target = urlsplit(args.target)
    if target.scheme not in {"http", "https"} or not target.netloc:
        print(f"invalid --target: {args.target}", file=sys.stderr)
        return 2

    server = ThreadingHTTPServer((args.host, args.port), make_handler(args.target, Path(args.log)))
    print(f"logging proxy listening on http://{args.host}:{args.port} -> {args.target}", flush=True)
    print(f"request log: {args.log}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    raise SystemExit(main())
