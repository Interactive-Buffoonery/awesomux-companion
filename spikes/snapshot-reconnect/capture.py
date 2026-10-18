"""Capture zmx attach reconstruction using a private, disposable session."""
import hashlib
import json
import os
import re
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1]).resolve())
out = Path(__file__).parent
private = tempfile.mkdtemp(prefix="zmx17-", dir="/tmp")
env = dict(os.environ, ZMX_DIR=private, ZMX_SESSION_PREFIX="")
env.pop("ZMX_SESSION", None)

def run(*args):
    return subprocess.run([binary, *args], env=env, capture_output=True, check=True)

def connect():
    client = socket.socket(socket.AF_UNIX)
    client.connect(private + "/probe")
    return client

def send(client, tag, data):
    client.sendall(struct.pack("<Q", tag | (len(data) << 8)) + data)

def receive(client):
    client.settimeout(0.3)
    data = bytearray()
    while True:
        try:
            part = client.recv(65536)
            if not part:
                break
            data.extend(part)
        except TimeoutError:
            break
    result = bytearray()
    while data:
        header = struct.unpack("<Q", data[:8])[0]
        size = (header >> 8) & 0xffffffff
        if len(data) < 8 + size:
            raise ValueError("incomplete zmx IPC frame")
        if header & 255 == 1:
            result.extend(data[8:8 + size])
        del data[:8 + size]
    return bytes(result)

try:
    run("run", "probe", "-d", "/bin/sh", "-c", "sleep 120")
    for attempt in range(50):
        if Path(private + "/probe").exists():
            break
        time.sleep(0.1)
    first = connect()
    send(first, 7, struct.pack("<HH", 6, 20))
    receive(first)
    fixture = (b"\x1b[3J\x1b[2J\x1b[H\x1b]133;A\x07$ \x1b]133;B\x07demo\r\n"
               b"\x1b]133;C\x07progress 10%\rprogress 90%\x1b[K\r\n"
               b"\x1b]133;D;7\x07" + b"W" * 35 + b"\r\n" +
               b"".join(b"line-%02d\r\n" % i for i in range(10)))
    injector = connect()
    send(injector, 1, b"\x1b[999;999H")
    receive(first)
    probe_client = connect()
    send(probe_client, 7, struct.pack("<HH", 6, 20))
    probe = receive(probe_client)
    probe_client.close()
    positions = re.findall(rb"\x1b\[(\d+);(\d+)H", probe)
    if not positions or tuple(map(int, positions[-1])) != (6, 20):
        raise ValueError("source grid readback did not match requested20x6")
    observed_rows, observed_cols = map(int, positions[-1])
    (out / "grid-probe.bin").write_bytes(probe)
    send(injector, 1, fixture)
    live = receive(first)
    (out / "input.bin").write_bytes(fixture)
    (out / "live.bin").write_bytes(live)
    first.close()
    away = b"AWAY\r\n\x1b]133;A\x07$ \x1b]133;B\x07next\x1b]133;C\x07\r\n\x1b]133;D;3\x07FINAL"
    send(injector, 1, away)
    receive(injector)
    injector.close()
    second = connect()
    send(second, 7, struct.pack("<HH", 6, 20))
    restored = receive(second)
    second.close()
    (out / "away.bin").write_bytes(away)
    (out / "reattach.bin").write_bytes(restored)
    report = {"binary": binary, "sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
              "version": run("version").stdout.decode().strip(), "requestedSize": {"rows": 6, "cols": 20},
              "size": {"rows": observed_rows, "cols": observed_cols},
              "sizeReadback": "CUP999;999 clamp serialized as CUP6;20 before fixture reset",
              "live_equals_input": live == fixture,
              "reattach_bytes": len(restored),
              "reattach_osc133": restored.count(b"\x1b]133;"),
              "away_survives": b"AWAY" in restored,
              "final_survives": b"FINAL" in restored,
              "overwritten_progress_absent": b"10%" not in restored,
              "final_progress_survives": b"90%" in restored}
    (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    (out / "reattach-escaped.txt").write_text(repr(restored) + "\n")
    print(json.dumps(report, indent=2))
finally:
    subprocess.run([binary, "kill", "probe"], env=env, capture_output=True, check=False)
