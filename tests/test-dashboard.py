#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT / "dashboard" / "server.py"


def load_server():
    spec = importlib.util.spec_from_file_location("dashboard_server", SERVER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DashboardTests(unittest.TestCase):
    def test_stats_shape_from_command_fixtures(self):
        server = load_server()

        def fake_run(argv):
            cmd = " ".join(argv)
            if argv[:2] == ["launchctl", "print"]:
                return "    pid = 1234\n"
            if argv[:2] == ["ps", "-o"]:
                return "  PID  %CPU %MEM    RSS COMMAND\n 1234   5.5 10.0 1048576 ds4-server\n"
            if argv[:1] == ["sysctl"]:
                return "vm.swapusage: total = 4096.00M  used = 1024.00M  free = 3072.00M  (encrypted)\n"
            if argv[:1] == ["memory_pressure"]:
                return "System-wide memory free percentage: 42%\n"
            if argv[:2] == ["df", "-k"]:
                return "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk 1000 400 600 40% /\n"
            if argv[:1] == ["vm_stat"]:
                return "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages active: 2000.\n"
            raise AssertionError(cmd)

        with mock.patch.object(server, "run_text", side_effect=fake_run):
            stats = server.collect_stats()

        self.assertEqual(stats["server"]["pid"], 1234)
        self.assertEqual(stats["server"]["rss_gib"], 1.0)
        self.assertEqual(stats["system"]["memory_free_percent"], 42)
        self.assertEqual(stats["system"]["swap_used_gib"], 1.0)
        self.assertEqual(stats["model"]["expert_budget_gib"], 24.0)

    def test_chat_uses_messages_and_reports_cache_tokens(self):
        server = load_server()
        body = json.dumps(
            {
                "choices": [{"message": {"content": "one two three"}}],
                "usage": {
                    "completion_tokens": 3,
                    "prompt_tokens_details": {
                        "cached_tokens": 7,
                        "cache_write_tokens": 5,
                    },
                },
            }
        ).encode()

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self):
                return body

        ticks = iter([100.0, 101.5])
        captured = {}

        def fake_urlopen(req, timeout):
            captured["payload"] = json.loads(req.data.decode())
            return FakeResponse()

        with mock.patch.object(server.urllib.request, "urlopen", side_effect=fake_urlopen):
            with mock.patch.object(server.time, "perf_counter", side_effect=lambda: next(ticks)):
                result = server.send_chat(
                    [{"role": "user", "content": "hello"}],
                    max_tokens=16,
                    reasoning_effort="none",
                )

        self.assertEqual(captured["payload"]["messages"], [{"role": "user", "content": "hello"}])
        self.assertEqual(result["content"], "one two three")
        self.assertEqual(result["tokens"], 3)
        self.assertAlmostEqual(result["tok_per_s"], 2.0)
        self.assertEqual(result["cached_tokens"], 7)
        self.assertEqual(result["cache_write_tokens"], 5)

    def test_static_index_references_dashboard_apis(self):
        html = (ROOT / "web" / "index.html").read_text()
        js = (ROOT / "web" / "app.js").read_text()
        self.assertIn("DeepSeek V4 Flash", html)
        self.assertIn("messages", html)
        self.assertIn("resetButton", html)
        self.assertIn("/api/stats", js)
        self.assertIn("/api/chat", js)
        self.assertIn("conversation", js)
        self.assertIn("cached_tokens", js)


if __name__ == "__main__":
    unittest.main()
