"""Repeatable helper-to-HTTP checks; no awesoMux or Simulator required."""

import http.client
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from glance_relay import GlanceRelay, make_server, notification_payload


STAMP = "2026-10-17T12:00:00Z"


def agent(pane="pane-1", **changes):
    value = dict(
        paneID=pane, workspaceID="workspace-1", workspaceName="awesomux",
        provider="Claude Code", executionLocation="local", availability="attached",
        state="running", attentionReason=None, unreadCount=0, observedAt=STAMP,
    )
    return value | changes


def event(identifier="event-1", **changes):
    return dict(
        id=identifier, attentionID="alert-1", change="raised", paneID="pane-1",
        workspaceID="workspace-1", provider="Claude Code", occurredAt=STAMP,
        reason="permissionPrompt", resolvedAt=None,
    ) | changes


def page(events=(), status="current", cursor="cursor-1", more=False):
    return {"attentionEvents": dict(
        events=list(events), cursorStatus=status, nextCursor=cursor, hasMore=more,
        currentStateRecoveryRequired=status in
        ("app_restarted", "history_gap", "access_changed"),
    )}


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.helper = self.directory / "fake-helper"
        self.helper.write_text(
            "#!" + sys.executable + "\n"
            "import json, pathlib, sys\n"
            "root = pathlib.Path(__file__).parent\n"
            "args = sys.argv[1:]\n"
            "assert args[:4] == ['--profile', 'development', '--credential-handle', "
            "'01234567-89ab-cdef-0123-456789abcdef']\n"
            "with (root / 'calls.jsonl').open('a') as f:\n"
            "    f.write(json.dumps(args) + '\\n')\n"
            "op = args[4]\n"
            "if op == 'get_attention_events':\n"
            "    assert args[5:7] == ['--limit', '100']\n"
            "    cursor = args[8] if len(args) > 7 else 'initial'\n"
            "    fixture = root / ('events-' + cursor + '.json')\n"
            "else:\n"
            "    assert op == 'list_agents'\n"
            "    fixture = root / 'agents.json'\n"
            "value = json.loads(fixture.read_text())\n"
            "print(value.get('raw', json.dumps(value.get('response', value))))\n"
            "sys.exit(value.get('exit', 0))\n"
        )
        self.helper.chmod(0o700)
        self.pushes = []
        self.relay = GlanceRelay(
            str(self.helper), "development", "01234567-89ab-cdef-0123-456789abcdef",
            host_name="test-mac", push_sender=self.pushes.append,
        )
        self.addCleanup(self.relay.close)
        self.fixture("events-initial", page(status="initial"))
        self.fixture("events-cursor-1", page())
        self.fixture("agents", {"agents": [agent()], "capturedAt": STAMP})

    def fixture(self, name, value):
        (self.directory / (name + ".json")).write_text(json.dumps(value))

    def poll(self):
        self.relay.poll_once()
        self.relay.push_queue.join()
        return self.relay.snapshot()

    def test_initial_history_and_pagination_do_not_notify(self):
        self.fixture("events-initial", page([event()], "initial", more=True))
        self.fixture("events-cursor-1", page(
            [event("event-2", attentionID="alert-2")], cursor="cursor-2"))
        snapshot = self.poll()
        self.assertEqual(len(self.relay.open_alerts), 2)
        self.assertEqual(snapshot["agents"][0]["group"], "needsYou")
        self.assertEqual(self.pushes, [])
        self.assertEqual(self.relay.cursor, "cursor-2")

    def test_later_raise_once_and_resolution(self):
        self.poll()
        self.fixture("events-cursor-1", page([event()]))
        snapshot = self.poll()
        self.poll()
        self.assertEqual(self.pushes, [{
            "aps": {"alert": {"title": "Claude Code needs permission", "body": "awesomux"},
                    "sound": "default", "thread-id": "pane-1", "content-available": 1},
            "paneID": "pane-1", "attentionID": "alert-1",
        }])
        self.assertEqual(snapshot["agents"][0]["reason"], "permissionPrompt")
        self.fixture("events-cursor-1", page([
            event("resolved-1", change="resolved", resolvedAt=STAMP)]))
        self.fixture("agents", {"agents": [agent(state="done")]})
        self.assertEqual(self.poll()["agents"][0]["group"], "done")
        self.assertEqual(self.relay.open_alerts, {})

    def test_recovery_clears_alerts_and_refetches(self):
        for status in ("app_restarted", "history_gap", "access_changed"):
            with self.subTest(status=status):
                self.relay.open_alerts["stale"] = event()
                current = self.relay.cursor or "initial"
                self.fixture("events-" + current, page(status=status, cursor=status))
                self.fixture("agents", {"agents": [agent(state="idle")]})
                self.assertEqual(self.poll()["agents"][0]["group"], "done")
                self.assertEqual(self.relay.open_alerts, {})
                self.assertEqual(self.relay.cursor, status)
        self.fixture("events-access_changed", page([event()], cursor="fresh"))
        self.poll()
        self.assertEqual(len(self.pushes), 1)

    def test_failures_retain_last_good_agents_and_time(self):
        good = self.poll()
        for fixture in (
            {"exit": 1, "response": {"error": "access_disabled"}},
            {"exit": 1, "raw": "not JSON"},
            {"raw": "[]"},
        ):
            with self.subTest(fixture=fixture):
                self.fixture("agents", fixture)
                failed = self.poll()
                self.assertFalse(failed["connected"])
                self.assertEqual(failed["error"],
                                 "access_disabled" if "response" in fixture else "helper_failed")
                self.assertEqual(failed["agents"], good["agents"])
                self.assertEqual(failed["updatedAt"], good["updatedAt"])
        self.fixture("agents", {"agents": [agent()]})
        self.assertTrue(self.poll()["connected"])
        self.fixture("events-cursor-1", {"exit": 1, "response": {"error": "app_unavailable"}})
        self.assertEqual(self.poll()["error"], "app_unavailable")

    def test_groups_order_and_unavailable(self):
        self.fixture("events-initial", page([event(paneID="alert")], "initial"))
        self.fixture("agents", {"agents": [
            agent("idle", state="idle"), agent("running"),
            agent("new", state="waiting", observedAt="2026-10-17T13:00:00Z"),
            agent("alert"), agent("reason", attentionReason="bell"),
            agent("unknown", state="error", observedAt=None),
            agent("thinking", state="thinking", availability="awaitingHydration"),
            agent("output", state="output", executionLocation="user@host"),
            agent("attention", state="needsAttention"), agent("done", state="done"),
            agent("hidden", availability="unavailable"),
        ]})
        agents = self.poll()["agents"]
        self.assertEqual([a["id"] for a in agents], [
            "alert", "reason", "attention", "new", "unknown", "running",
            "thinking", "output", "idle", "done",
        ])
        self.assertEqual([a["group"] for a in agents],
                         ["needsYou"] * 5 + ["working"] * 3 + ["done"] * 2)
        self.assertEqual(agents[0]["since"], STAMP)
        self.assertEqual(agents[7]["location"], "user@host")

    def test_notification_reason_titles(self):
        phrases = {
            "permissionPrompt": "needs permission", "userInputRequired": "has a question",
            "waitingForInput": "is waiting for you", "processError": "hit an error",
            "agentError": "hit an error", "bell": "wants your attention",
        }
        for reason, phrase in phrases.items():
            self.assertEqual(notification_payload(event(reason=reason), "project")
                             ["aps"]["alert"],
                             {"title": "Claude Code " + phrase, "body": "project"})

    def test_push_is_async_and_failure_does_not_break_polling(self):
        entered = threading.Event()
        release = threading.Event()
        self.addCleanup(release.set)

        def slow_push(payload):
            entered.set()
            release.wait(5)
            raise RuntimeError("delivery failed")

        self.relay.push_sender = slow_push
        self.poll()
        self.fixture("events-cursor-1", page([event()]))
        self.relay.poll_once()
        self.assertTrue(entered.wait(2))
        self.assertTrue(self.relay.snapshot()["connected"])
        self.relay.poll_once()
        release.set()
        self.relay.push_queue.join()
        self.assertTrue(self.poll()["connected"])

    def test_http_security_and_snapshot(self):
        self.poll()
        server = make_server(self.relay, "test-token")
        worker = threading.Thread(target=server.serve_forever)
        worker.start()

        def cleanup():
            server.shutdown()
            server.server_close()
            worker.join()

        self.addCleanup(cleanup)

        def request(path="/v1/glance", token="test-token", extra=()):
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
            connection.putrequest("GET", path, skip_host=True)
            connection.putheader("Host", "127.0.0.1:" + str(server.server_port))
            connection.putheader("Authorization", "Bearer " + token)
            for name, value in extra:
                connection.putheader(name, value)
            connection.endheaders()
            response = connection.getresponse()
            body = json.loads(response.read())
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            self.assertEqual(response.getheader("Connection"), "close")
            self.assertEqual(response.getheader("Content-Type"), "application/json")
            connection.close()
            return response.status, body

        self.assertEqual(request(), (200, self.relay.snapshot()))
        self.assertEqual(request(token="bad")[0], 401)
        self.assertEqual(request(extra=[("Authorization", "Bearer test-token")])[0], 401)
        self.assertEqual(request(extra=[("Origin", "")])[0], 403)
        self.assertEqual(request(extra=[("Host", "evil.example")])[0], 403)
        self.assertEqual(request(path="/other")[0], 404)

    def test_cli_pairing_and_signal_shutdown(self):
        private = self.directory / "private"
        private.mkdir(mode=0o700)
        command = [sys.executable, str(Path(__file__).with_name("glance_relay.py")),
                   "--helper", str(self.helper), "--profile", "development",
                   "--credential-handle", "01234567-89ab-cdef-0123-456789abcdef",
                   "--private-directory", str(private), "--poll-interval", "0.05",
                   "--host-name", "cli-mac"]
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                target = private / str(signum)
                target.mkdir(mode=0o700)
                args = command.copy()
                args[args.index("--private-directory") + 1] = str(target)
                process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    client_file = target / "client.json"
                    deadline = time.monotonic() + 5
                    while not client_file.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    client = json.loads(client_file.read_text())
                    self.assertEqual(client_file.stat().st_mode & 0o777, 0o600)
                    self.assertTrue(client["endpoint"].startswith("http://127.0.0.1:"))
                    self.assertGreaterEqual(len(client["token"]), 43)
                    time.sleep(0.1)
                    process.send_signal(signum)
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, 0, stderr.decode())
                    self.assertEqual(stdout, b"")
                    self.assertIn(client["endpoint"].encode(), stderr)
                    self.assertNotIn(client["token"].encode(), stderr)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()


if __name__ == "__main__":
    unittest.main()
