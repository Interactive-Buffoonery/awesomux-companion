"""Fixture-only HTTPS endpoint for Watch diagnostics; never opens user sessions."""
import argparse
import base64
from collections import deque
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
from pathlib import Path
import secrets
import signal
import sys
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlencode, urlsplit
import uuid

ROOT = Path(__file__).parent
LIMIT = 256 * 1024


class Fixture:
    def __init__(self, binary, directory):
        self.binary = str(Path(binary).resolve())
        self.directory = Path(directory)
        self.env = dict(os.environ, ZMX_DIR=str(directory), ZMX_SESSION_PREFIX="")
        self.env.pop("ZMX_SESSION", None)
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.run_id = str(uuid.uuid4())
        self.sequence = 0
        self.events = deque(maxlen=256)
        self.leader = None
        self.injector = None
        self.thread = None
        try:
            self.command("run", "fixture", "-d", "/bin/sh", "-c", "sleep 86400")
            for _ in range(100):
                if (self.directory / "fixture").exists():
                    break
                time.sleep(0.05)
            self.leader = self.connect()
            self.send(self.leader, 7, struct.pack("<HH", 6, 20))
            self.leader.settimeout(0.3)
            try:
                while True:
                    self.receive(self.leader)
            except TimeoutError:
                pass
            self.leader.settimeout(2)
            self.injector = self.connect()
            self.emit(b"\x1b[999;999H")
            probe = self.snapshot_bytes()
            positions = re.findall(rb"\x1b\[(\d+);(\d+)H", probe)
            if not positions or tuple(map(int, positions[-1])) != (6, 20):
                raise ValueError("zmx did not independently restore the requested source grid")
            self.rows, self.columns = map(int, positions[-1])
            (self.directory / "grid-probe.bin").write_bytes(probe)
            self.emit((ROOT / "input.bin").read_bytes() + (ROOT / "away.bin").read_bytes())
            self.thread = threading.Thread(target=self.tick, daemon=True)
        except BaseException:
            self.close()
            raise

    def command(self, *args):
        return subprocess.run([self.binary, *args], env=self.env,
                              capture_output=True, check=args[0] != "kill", timeout=10)

    def connect(self):
        client = socket.socket(socket.AF_UNIX)
        client.settimeout(2)
        client.connect(str(self.directory / "fixture"))
        return client

    @staticmethod
    def send(client, tag, data):
        client.sendall(struct.pack("<Q", tag | (len(data) << 8)) + data)

    @staticmethod
    def exact(client, count):
        data = bytearray()
        while len(data) < count:
            part = client.recv(count - len(data))
            if not part:
                raise ConnectionError("zmx closed before complete frame")
            data.extend(part)
        return bytes(data)

    @classmethod
    def receive(cls, client):
        for _ in range(32):
            header = struct.unpack("<Q", cls.exact(client, 8))[0]
            size = (header >> 8) & 0xffffffff
            if size > LIMIT:
                raise ValueError("oversized zmx fixture frame")
            body = cls.exact(client, size)
            if header & 255 == 1:
                return body
        raise ValueError("too many non-output zmx frames")

    def emit(self, data):
        self.send(self.injector, 1, data)
        for client in (self.leader, self.injector):
            received = bytearray()
            while len(received) < len(data):
                received.extend(self.receive(client))
            if received != data:
                raise ValueError("fixture live output differs from injected output")
        self.sequence += 1
        event = {"sequence": self.sequence,
                 "dataBase64": base64.b64encode(data).decode()}
        self.events.append(event)
        with (self.directory / "events.jsonl").open("a") as capture:
            capture.write(json.dumps(event) + "\n")

    def tick(self):
        while not self.stop.wait(1):
            with self.lock:
                try:
                    number = self.sequence + 1
                    self.emit((f"\r\nSEQ {number:06d}\r\n" + "W" * 35 +
                               f"\r\nprogress {number}%\rprogress DONE\x1b[K").encode())
                except Exception:
                    # Invalidate under the same lock as the terminal/sequence cut.
                    self.stop.set()
                    print("Fixture producer failed; serving stopped", file=sys.stderr)

    def snapshot_bytes(self):
        client = self.connect()
        try:
            self.send(client, 7, struct.pack("<HH", 6, 20))
            return self.receive(client)
        finally:
            client.close()

    def response(self, path):
        parsed = urlsplit(path)
        with self.lock:
            if self.stop.is_set():
                return 503, {"error": "fixture stopped"}
            common = {"schemaVersion": 1, "runID": self.run_id,
                      "columns": self.columns, "rows": self.rows}
            if parsed.path == "/snapshot" and not parsed.query:
                data = self.snapshot_bytes()
                response = dict(common, kind="snapshot", sequence=self.sequence,
                                dataBase64=base64.b64encode(data).decode())
                # Synthetic bytes only, useful for matching the phone evidence.
                (self.directory / "latest-snapshot.json").write_text(json.dumps(response))
                return 200, response
            if parsed.path == "/events":
                query = parse_qs(parsed.query)
                try:
                    after = int(query["after"][0])
                    run_id = query["runID"][0]
                except (KeyError, ValueError):
                    return 400, {"error": "runID and integer after required"}
                if (run_id != self.run_id or after < 0 or after > self.sequence or
                        after < self.events[0]["sequence"] - 1):
                    return 409, {"error": "fresh snapshot required"}
                return 200, dict(common, kind="events",
                                 events=[e for e in self.events if e["sequence"] > after])
            return 404, {"error": "fixture route not found"}

    def close(self):
        self.stop.set()
        if self.thread and self.thread.is_alive():
            self.thread.join(timeout=3)
        for client in (self.leader, self.injector):
            if client:
                client.close()
        try:
            self.command("kill", "fixture")
        except (OSError, subprocess.SubprocessError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zmx", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--advertise-host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8769)
    parser.add_argument("--duration", type=int, default=3600, help="stop after this many seconds (default: one hour)")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if args.duration <= 0:
        parser.error("--duration must be positive")
    directory = Path(tempfile.mkdtemp(prefix="watch-fixture-", dir="/tmp"))
    os.chmod(directory, 0o700)
    key = directory / "key.pem"
    cert = directory / "cert.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
                    "ec_paramgen_curve:P-256", "-nodes", "-keyout", str(key),
                    "-out", str(cert), "-days", "2", "-subj", "/CN=Watch Fixture"],
                   check=True, capture_output=True)
    os.chmod(key, 0o600)
    der = ssl.PEM_cert_to_DER_cert(cert.read_text())
    pin = hashlib.sha256(der).hexdigest()
    token = secrets.token_urlsafe(32)
    fixture = Fixture(args.zmx, directory)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        timeout = 5

        def setup(self):
            self.request.settimeout(self.timeout)
            self.request.do_handshake()
            super().setup()

        def do_GET(self):
            if not hmac.compare_digest(self.headers.get("Authorization", "").encode("latin-1"), ("Bearer " + token).encode("ascii")):
                status, body = 401, {"error": "unauthorized"}
            else:
                try:
                    status, body = fixture.response(self.path)
                except Exception:
                    status, body = 503, {"error": "fixture unavailable"}
            data = json.dumps(body).encode()
            if len(data) > LIMIT:
                status, data = 503, b'{"error":"fixture response too large"}'
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_):
            pass

    try:
        server = ThreadingHTTPServer((args.host, args.port), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
        server.socket.settimeout(5)
        url = f"https://{args.advertise_host}:{server.server_port}"
        config = {"url": url, "token": token, "pin": pin}
        config["deepLink"] = "awesomuxdiagnostics://fixture?" + urlencode(config)
        config_path = directory / "connection.json"
        config_path.write_text(json.dumps(config, indent=2) + "\n")
        os.chmod(config_path, 0o600)
        (directory / "provenance.json").write_text(json.dumps({
            "runID": fixture.run_id, "binarySHA256": hashlib.sha256(Path(args.zmx).read_bytes()).hexdigest(),
            "fixtureSHA256": hashlib.sha256((ROOT / "input.bin").read_bytes() + (ROOT / "away.bin").read_bytes()).hexdigest()
        }, indent=2))
        print(f"Fixture endpoint: {url}\nPrivate connection configuration: {config_path}", flush=True)
        fixture.thread.start()
        timer = threading.Timer(args.duration, server.shutdown)
        timer.daemon = True
        timer.start()
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        fixture.close()
        if "timer" in locals():
            timer.cancel()
        if "server" in locals():
            server.server_close()


if __name__ == "__main__":
    main()
