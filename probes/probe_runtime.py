"""Boundary validation and best-effort teardown for the disposable probe."""
import os
import shutil
import subprocess
from urllib.parse import urlsplit


def validate_endpoint(endpoint):
    url = urlsplit(endpoint)
    if (url.scheme != 'ws' or url.hostname != '127.0.0.1' or url.port is None
            or url.port == 0 or url.username is not None or url.password is not None
            or url.path or url.query or url.fragment):
        raise ValueError('credential-free loopback WebSocket endpoint required')


def cleanup(proxies, desktop, master, name, env, results, run=subprocess.run):
    errors = []
    def attempt(label, action):
        try:
            return action()
        except Exception as exc:
            errors.append(label + ': ' + type(exc).__name__)
    def stop(p):
        if p.poll() is None:
            p.terminate()
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=5)
    for p in proxies:
        attempt('proxy', lambda p=p: stop(p))
    if name:
        results['owned_amx_session'] = name
        killed = attempt('amx kill', lambda: run([shutil.which('amx'), 'kill', name], env=env, capture_output=True, timeout=10))
        results['amx_kill_exit'] = killed.returncode if killed else None
        listed = attempt('amx list', lambda: run([shutil.which('amx'), 'list', '--short'], env=env, capture_output=True, timeout=10))
        results['amx_absent'] = (name not in listed.stdout.decode()) if listed and listed.returncode == 0 else None
    if desktop:
        attempt('desktop', lambda: stop(desktop))
    if master is not None:
        attempt('pty', lambda: os.close(master))
    results['cleanup_errors'] = errors
