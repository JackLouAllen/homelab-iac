#!/usr/bin/env python3
"""Test the status-push runner (ansible/roles/status_push/files/status-push.py) against local servers.

    scripts/test-status-push.py

Standard library only. The TLS check needs the openssl command and is skipped without it.
"""
import http.server
import importlib.util
import json
import os
import pathlib
import shutil
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import urllib.parse

# Importing the runner would otherwise leave a bytecode cache next to it in the role
sys.dont_write_bytecode = True
root = pathlib.Path(__file__).resolve().parent.parent
script = root / "ansible/roles/status_push/files/status-push.py"
spec = importlib.util.spec_from_file_location("status_push", script)
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)
failures = []


def check(name, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + name + (f" ({detail})" if detail and not ok else ""))
    if not ok:
        failures.append(name)


class Server(http.server.ThreadingHTTPServer):
    """Answers every GET with the status in .status and remembers each request."""
    daemon_threads = True

    def __init__(self, status=200, ssl_context=None):
        self.status, self.requests, self.agents = status, [], []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(handler):  # noqa: N805
                self.requests.append(handler.path)
                self.agents.append(handler.headers.get("User-Agent"))
                handler.send_response(self.status)
                handler.send_header("Content-Length", "2")
                handler.end_headers()
                handler.wfile.write(b"{}")

            def log_message(handler, *args):  # noqa: N805
                pass

        super().__init__(("127.0.0.1", 0), Handler)
        if ssl_context:
            self.socket = ssl_context.wrap_socket(self.socket, server_side=True)
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def port(self):
        return self.server_address[1]


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


work = pathlib.Path(tempfile.mkdtemp())
try:
    # --- tcp
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    check("tcp: an open port is up", sp.check_tcp({"host": "127.0.0.1", "port": listener.getsockname()[1]}) is None)
    closed = free_port()
    message = sp.check_tcp({"host": "127.0.0.1", "port": closed})
    check("tcp: a closed port is down and named", bool(message) and str(closed) in message, message)

    # --- http
    web = Server(200)
    check("http: 200 is up", sp.check_http({"url": f"http://127.0.0.1:{web.port}/app/login"}) is None)
    web.status = 503
    message = sp.check_http({"url": f"http://127.0.0.1:{web.port}/"})
    check("http: 503 is down and says so", bool(message) and "503" in message, message)
    check("http: another expected status is honoured", sp.check_http({"url": f"http://127.0.0.1:{web.port}/", "status": 503}) is None)
    message = sp.check_http({"url": f"http://127.0.0.1:{closed}/"})
    check("http: nothing listening is down", bool(message) and "unreachable" in message, message)
    check("http: sends its own user agent, not Python's", set(web.agents) == {sp.USER_AGENT}, str(set(web.agents)))

    # --- disk
    here = str(work)
    check("disk: under the limit is up", sp.check_disk({"paths": [here], "max_percent": 100}) is None)
    message = sp.check_disk({"paths": [here], "max_percent": -1})
    check("disk: over the limit names the path", bool(message) and here in message and "% used" in message, message)
    message = sp.check_disk({"paths": [here, str(work / "missing")], "max_percent": 100})
    check("disk: a missing path is down", bool(message) and "missing" in message, message)
    df = subprocess.run(["df", "--output=pcent", here], capture_output=True, text=True, check=False).stdout.split()
    if len(df) == 2:
        check("disk: matches df's Use% to within a point", abs(sp.percent_used(here) - int(df[1].rstrip("%"))) <= 1, f"{sp.percent_used(here)} vs {df[1]}")
    else:
        print("skip  disk: df output not understood")

    # --- systemd, with a stand-in systemctl first on PATH
    fake = work / "bin"
    fake.mkdir()
    (fake / "systemctl").write_text('#!/bin/sh\n[ "$3" = good.service ] && exit 0\nexit 3\n')
    (fake / "systemctl").chmod((fake / "systemctl").stat().st_mode | stat.S_IEXEC)
    old_path = os.environ["PATH"]
    os.environ["PATH"] = f"{fake}:{old_path}"
    check("systemd: an active unit is up", sp.check_systemd({"unit": "good.service"}) is None)
    message = sp.check_systemd({"unit": "bad.service"})
    check("systemd: an inactive unit is down and named", bool(message) and "bad.service" in message, message)
    os.environ["PATH"] = old_path

    # --- a monitor is up only when every test passes
    up_test = {"kind": "tcp", "host": "127.0.0.1", "port": listener.getsockname()[1]}
    down_test = {"kind": "tcp", "host": "127.0.0.1", "port": closed}
    check("monitor: all tests passing is up", sp.run_monitor({"name": "a", "tests": [up_test, up_test]}) == (True, "OK"))
    up, message = sp.run_monitor({"name": "a", "tests": [up_test, down_test, down_test]})
    check("monitor: one failing test is down", not up and message.count(str(closed)) == 2, message)
    up, message = sp.run_monitor({"name": "a", "tests": [{"kind": "nonsense"}, up_test]})
    check("monitor: an unknown kind is down, not a crash", not up and "failed to run" in message, message)
    up, message = sp.run_monitor({"name": "a", "tests": [{"kind": "disk", "paths": [here], "max_percent": -1}] * 40})
    check("monitor: the message is cut to a size Kuma accepts", len(message) <= sp.MESSAGE_LIMIT, str(len(message)))

    # --- https verified against a given CA
    if shutil.which("openssl"):
        key, crt = work / "k.pem", work / "c.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1", "-keyout", str(key), "-out", str(crt)],
                       check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(crt, key)
        secure = Server(200, context)
        url = f"https://localhost:{secure.port}/app/login"
        check("https: verifies against the given CA", sp.check_http({"url": url, "cafile": str(crt)}) is None)
        message = sp.check_http({"url": url})
        check("https: refuses a certificate the system does not trust", bool(message) and "unreachable" in message, message)
        other = work / "other.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=other",
                        "-keyout", str(work / "ok.pem"), "-out", str(other)], check=True, capture_output=True)
        message = sp.check_http({"url": url, "cafile": str(other)})
        check("https: refuses a certificate from a different CA", bool(message) and "unreachable" in message, message)
    else:
        print("skip  https checks: no openssl command")

    # --- the whole run, as systemd would start it
    kuma = Server(200)
    secret_up, secret_down = "UPTOKEN12345678", "DOWNTOKEN1234567"
    config = work / "config.json"
    config.write_text(json.dumps({"base_url": f"http://127.0.0.1:{kuma.port}/", "monitors": [
        {"name": "fine", "tests": [up_test]},
        {"name": "broken", "tests": [down_test]},
        {"name": "untokened", "tests": [up_test]},
        {"name": "badtoken", "tests": [up_test]},
    ]}))
    creds = work / "creds"
    creds.mkdir()
    (creds / "tokens").write_text(json.dumps({"fine": secret_up, "broken": secret_down, "badtoken": "../x?y=z"}))
    env = {**os.environ, "STATUS_PUSH_CONFIG": str(config), "CREDENTIALS_DIRECTORY": str(creds)}
    run = subprocess.run([sys.executable, "-I", str(script)], env=env, capture_output=True, text=True, check=False)
    seen = {urllib.parse.urlsplit(p).path.rsplit("/", 1)[-1]: urllib.parse.parse_qs(urllib.parse.urlsplit(p).query) for p in kuma.requests}
    check("run: exits 0", run.returncode == 0, run.stderr)
    check("run: the up monitor is pushed up with its token", seen.get(secret_up, {}).get("status") == ["up"], str(seen))
    check("run: the failing monitor is pushed down with the reason", seen.get(secret_down, {}).get("status") == ["down"]
          and str(closed) in seen[secret_down]["msg"][0], str(seen))
    check("run: a monitor with no token is not pushed, and is named", "untokened: no usable token" in run.stderr, run.stderr)
    check("run: a token with odd characters is refused", len(kuma.requests) == 2 and "badtoken: no usable token" in run.stderr, run.stderr)
    check("run: the base URL's trailing slash does not double up", all(p.startswith("/api/push/") for p in kuma.requests), str(kuma.requests))
    check("run: pushes carry the runner's user agent", set(kuma.agents) == {sp.USER_AGENT}, str(set(kuma.agents)))

    # --- a push that cannot be delivered must not fail the run, and must not print the token
    kuma.shutdown()
    kuma.server_close()
    run = subprocess.run([sys.executable, "-I", str(script)], env=env, capture_output=True, text=True, check=False)
    check("unreachable Kuma: still exits 0", run.returncode == 0, run.stderr)
    check("unreachable Kuma: says the push failed", "push failed" in run.stderr, run.stderr)
    check("unreachable Kuma: no token in the output", secret_up not in run.stdout + run.stderr and secret_down not in run.stdout + run.stderr)

    # --- no credential directory is an error worth stopping for
    env.pop("CREDENTIALS_DIRECTORY")
    run = subprocess.run([sys.executable, "-I", str(script)], env=env, capture_output=True, text=True, check=False)
    check("no credential directory: exits non-zero", run.returncode != 0)

    # --- the monitors configured in group_vars must be ones the runner understands: a typo in a key would otherwise
    # make a monitor report down for the wrong reason, or never run
    try:
        import yaml
    except ImportError:
        yaml = None
        print("skip  group_vars monitors: no yaml module")
    if yaml:
        needs = {"systemd": {"unit"}, "tcp": {"host", "port"}, "http": {"url"}, "disk": {"paths", "max_percent"}}
        allowed = {"systemd": {"unit"}, "tcp": {"host", "port", "timeout"}, "http": {"url", "status", "cafile", "timeout"},
                   "disk": {"paths", "max_percent"}}
        for group in sorted((root / "ansible/inventory/group_vars").glob("*.yml")):
            monitors = (yaml.safe_load(group.read_text()) or {}).get("status_push_monitors", [])
            if not monitors:
                continue
            names = [m.get("name") for m in monitors]
            check(f"{group.name}: monitor names are present and unique", all(names) and len(set(names)) == len(names), str(names))
            check(f"{group.name}: monitor names are safe as token keys", all(isinstance(n, str) and n.replace("-", "").isalnum() for n in names), str(names))
            for monitor in monitors:
                tests = monitor.get("tests") or []
                check(f"{group.name}: {monitor.get('name')} has tests", bool(tests))
                for test in tests:
                    kind = test.get("kind")
                    keys = set(test) - {"kind"}
                    ok = kind in sp.CHECKS and needs[kind] <= keys and keys <= allowed[kind]
                    check(f"{group.name}: {monitor.get('name')} {kind} test is well formed", ok, f"{test}: needs {needs.get(kind)}, allows {allowed.get(kind)}")
finally:
    shutil.rmtree(work, ignore_errors=True)

sys.exit(1 if failures else 0)
