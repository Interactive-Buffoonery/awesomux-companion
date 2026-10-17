"""Read-only, loopback Glance relay for the awesoMux agent helper."""

import argparse
import copy
from datetime import datetime, timezone
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import queue
import secrets
import signal
import socket
import subprocess
import sys
import threading
import uuid

from private_files import write_private_json


RECOVERY_STATUSES = {"history_gap", "app_restarted", "access_changed"}


def log(message):
    print(" ".join(message.splitlines()), file=sys.stderr, flush=True)


def timestamp_key(value):
    if value is None:
        return float("inf")
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def notification_payload(event, workspace_name):
    phrase = {
        "permissionPrompt": "needs permission",
        "userInputRequired": "has a question",
        "waitingForInput": "is waiting for you",
        "processError": "hit an error",
        "agentError": "hit an error",
    }.get(event["reason"], "wants your attention")
    return {
        "aps": {
            "alert": {"title": event["provider"] + " " + phrase, "body": workspace_name},
            "sound": "default",
            "thread-id": event["paneID"],
            "content-available": 1,
        },
        "paneID": event["paneID"],
        "attentionID": event["attentionID"],
    }


def simulator_sender(device, bundle_id):
    def send(payload):
        subprocess.run(
            ["xcrun", "simctl", "push", device, bundle_id, "-"],
            input=json.dumps(payload), text=True, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=10, check=True,
        )

    return send


class HelperFailure(Exception):
    pass


class GlanceRelay:
    def __init__(self, helper, profile, credential_handle, *, host_name=None,
                 poll_interval=2.0, push_sender=None):
        self.command = [helper, "--profile", profile, "--credential-handle", credential_handle]
        self.poll_interval = poll_interval
        self.push_sender = push_sender
        self.cursor = None
        self.open_alerts = {}
        self.seen_events = set()
        self.pending_pushes = []
        self.workspace_names = {}
        self.reading_initial_history = True
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.worker = None
        self.push_queue = queue.Queue()
        self.push_worker = threading.Thread(target=self._send_pushes, daemon=True)
        self.push_worker.start()
        self._snapshot = {
            "schemaVersion": 1,
            "hostName": host_name if host_name is not None else socket.gethostname().split(".")[0],
            "connected": False,
            "error": "helper_failed",
            "updatedAt": None,
            "agents": [],
        }

    def read_helper(self, operation, *arguments):
        try:
            result = subprocess.run(
                self.command + [operation, *arguments], capture_output=True,
                text=True, timeout=10, check=False,
            )
            response = json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            raise HelperFailure("helper_failed") from None
        if not isinstance(response, dict):
            raise HelperFailure("helper_failed")
        error = response.get("error")
        if result.returncode != 0 or error is not None:
            raise HelperFailure(error if isinstance(error, str) and error else "helper_failed")
        return response

    def snapshot(self):
        with self.lock:
            return copy.deepcopy(self._snapshot)

    def _publish(self, *, error=None, agents=None, captured_at=None):
        connected = error is None
        with self.lock:
            changed = self._snapshot["connected"] != connected
            self._snapshot["connected"] = connected
            self._snapshot["error"] = error
            if connected:
                self._snapshot["agents"] = agents
                self._snapshot["updatedAt"] = captured_at
        if changed:
            log("Glance connected" if connected else "Glance disconnected")

    def _agents(self, roster):
        alerts_by_pane = {}
        for alert in self.open_alerts.values():
            pane = alert["paneID"]
            previous = alerts_by_pane.get(pane)
            if (previous is None
                    or timestamp_key(alert["occurredAt"]) < timestamp_key(previous["occurredAt"])):
                alerts_by_pane[pane] = alert
        agents = []
        for source in roster:
            if source["availability"] == "unavailable":
                continue
            alert = alerts_by_pane.get(source["paneID"])
            state = source["state"]
            if alert is not None or source.get("attentionReason") is not None or state in {
                "waiting", "needsAttention", "error",
            }:
                group = "needsYou"
            elif state in {"running", "thinking", "output"}:
                group = "working"
            else:
                group = "done"
            agents.append({
                "id": source["paneID"],
                "workspaceName": source["workspaceName"],
                "provider": source["provider"],
                "group": group,
                "state": state,
                "reason": alert["reason"] if alert else source.get("attentionReason"),
                "location": source["executionLocation"],
                "since": alert["occurredAt"] if alert else source.get("observedAt"),
            })
        order = {"needsYou": 0, "working": 1, "done": 2}
        agents.sort(key=lambda item: (
            order[item["group"]],
            timestamp_key(item["since"]) if item["group"] == "needsYou" else 0,
        ))
        return agents

    def poll_once(self):
        try:
            while not self.stop.is_set():
                arguments = ["--limit", "100"]
                if self.cursor is not None:
                    arguments += ["--cursor", self.cursor]
                page = self.read_helper("get_attention_events", *arguments)["attentionEvents"]
                if self.stop.is_set():
                    return
                status = page["cursorStatus"]
                if status not in RECOVERY_STATUSES | {"initial", "current"}:
                    raise HelperFailure("helper_failed")
                next_cursor = page["nextCursor"]
                if not isinstance(next_cursor, str) or not next_cursor:
                    raise HelperFailure("helper_failed")
                if page["currentStateRecoveryRequired"] or status in RECOVERY_STATUSES:
                    self.open_alerts.clear()
                    # Alerts queued before an access change must not leak out after it.
                    self.pending_pushes.clear()
                    # Keep the old cursor until recovery succeeds so a failed roster
                    # read retries recovery rather than skipping its required capture.
                    response = self.read_helper("list_agents")
                    self._capture(response)
                    self.cursor = next_cursor
                    self.reading_initial_history = False
                    return
                for event in page["events"]:
                    identifier = event["id"]
                    if identifier in self.seen_events:
                        continue
                    if event["change"] == "raised":
                        # Validate notification fields before recording the page.
                        notification_payload(event, "")
                        timestamp_key(event["occurredAt"])
                        if not isinstance(event["workspaceID"], str):
                            raise HelperFailure("helper_failed")
                        self.open_alerts[event["attentionID"]] = event
                        if status != "initial" and not self.reading_initial_history:
                            self.pending_pushes.append(event)
                    elif event["change"] == "resolved":
                        self.open_alerts.pop(event["attentionID"], None)
                    else:
                        raise HelperFailure("helper_failed")
                    self.seen_events.add(identifier)
                if page["hasMore"] and next_cursor == self.cursor:
                    raise HelperFailure("helper_failed")
                self.cursor = next_cursor
                if not page["hasMore"]:
                    self.reading_initial_history = False
                    break
            if not self.stop.is_set():
                self._capture(self.read_helper("list_agents"))
        except HelperFailure as error:
            self._publish(error=str(error))
        except (KeyError, TypeError, ValueError, AttributeError):
            self._publish(error="helper_failed")

    def _capture(self, response):
        roster = response["agents"]
        if not isinstance(roster, list):
            raise HelperFailure("helper_failed")
        agents = self._agents(roster)
        names = {source["workspaceID"]: source["workspaceName"] for source in roster}
        self.workspace_names.update(names)
        captured_at = response.get("capturedAt") or (
            datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        )
        self._publish(agents=agents, captured_at=captured_at)
        for event in self.pending_pushes:
            if self.push_sender is not None:
                name = self.workspace_names.get(event["workspaceID"], "")
                self.push_queue.put(notification_payload(event, name))
        self.pending_pushes.clear()

    def _send_pushes(self):
        while True:
            payload = self.push_queue.get()
            try:
                if payload is None:
                    return
                if self.stop.is_set():
                    continue
                try:
                    self.push_sender(payload)
                    log("Glance push sent: " + payload["aps"]["alert"]["title"])
                except Exception:
                    log("Glance push failed")
            finally:
                self.push_queue.task_done()

    def _poll(self):
        while not self.stop.is_set():
            self.poll_once()
            self.stop.wait(self.poll_interval)

    def start(self):
        self.worker = threading.Thread(target=self._poll, daemon=True)
        self.worker.start()

    def close(self):
        self.stop.set()
        if self.worker is not None:
            self.worker.join(timeout=11)
        self.push_queue.put(None)
        self.push_worker.join(timeout=11)


class LocalServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def handle_error(self, request, client_address):
        pass


def make_server(state, token):
    capability = token.encode("ascii")

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def log_message(self, *arguments):
            pass

        def reply(self, status, value):
            data = json.dumps(value, separators=(",", ":")).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            self.wfile.write(data)

        def do_GET(self):
            authorization = self.headers.get_all("Authorization", [])
            if (len(authorization) != 1 or not authorization[0].startswith("Bearer ")
                    or not hmac.compare_digest(authorization[0][7:].encode("utf-8"), capability)):
                self.reply(401, {"error": "unauthorized"})
                return
            if (self.headers.get_all("Origin") is not None
                    or self.headers.get_all("Host", []) != ["127.0.0.1:" + str(self.server.server_port)]):
                self.reply(403, {"error": "forbidden"})
                return
            if self.path != "/v1/glance":
                self.reply(404, {"error": "not_found"})
                return
            self.reply(200, state.snapshot())

    return LocalServer(("127.0.0.1", 0), Handler)


def positive_interval(value):
    interval = float(value)
    if not math.isfinite(interval) or interval <= 0:
        raise argparse.ArgumentTypeError("poll interval must be finite and positive")
    return interval


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--credential-handle", required=True, type=uuid.UUID)
    parser.add_argument("--private-directory", required=True)
    parser.add_argument("--poll-interval", default=2.0, type=positive_interval)
    parser.add_argument("--simulator-push", metavar="BUNDLE_ID")
    # "booted" is ambiguous once a second Simulator is running.
    parser.add_argument("--simulator-device", metavar="UDID")
    parser.add_argument("--host-name", default=socket.gethostname().split(".")[0])
    args = parser.parse_args()
    if args.simulator_push and not args.simulator_device:
        parser.error("--simulator-push needs --simulator-device")
    sender = simulator_sender(args.simulator_device, args.simulator_push) if args.simulator_push else None
    relay = GlanceRelay(args.helper, args.profile, str(args.credential_handle),
                        host_name=args.host_name, poll_interval=args.poll_interval,
                        push_sender=sender)
    token = secrets.token_urlsafe(32)
    server = make_server(relay, token)
    stop = threading.Event()
    worker = None
    previous_signals = {}
    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous_signals[signum] = signal.signal(signum, lambda *_: stop.set())
        endpoint = "http://127.0.0.1:" + str(server.server_port)
        write_private_json(args.private_directory, "client.json", {
            "endpoint": endpoint, "token": token,
        })
        log(endpoint)
        relay.start()
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        stop.wait()
    finally:
        relay.stop.set()
        if worker is not None:
            server.shutdown()
            worker.join()
        server.server_close()
        relay.close()
        for signum, handler in previous_signals.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    main()
