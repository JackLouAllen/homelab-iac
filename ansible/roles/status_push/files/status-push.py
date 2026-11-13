#!/usr/bin/python3 -I
"""Run the local health checks in the configuration and report each result to an Uptime Kuma push monitor.

Each monitor in the configuration has a name and a list of tests; it is up when every test passes. The result goes to
<base_url>/api/push/<token>?status=up|down&msg=..., where the token for the monitor's name is read from the systemd
credential "tokens" (a JSON object of name to token). A monitor with no token is skipped and said so, and a push that
fails is reported on stderr and does not fail the run: Kuma marks a push monitor down when the pushes stop, which is
the alarm for a dead host or a dead timer.

Tests (each a JSON object with a "kind"):
  systemd  unit                        the unit is active
  tcp      host, port                  a TCP connection is accepted
  http     url, [status], [cafile]     the URL answers with that status (default 200); cafile verifies an https
                                       certificate against that CA instead of the system store
  disk     paths, max_percent          every path is below that percentage used (df's own arithmetic)

The configuration path can be set with STATUS_PUSH_CONFIG (the tests do), and the credential directory is the one
systemd sets in CREDENTIALS_DIRECTORY.
"""
import concurrent.futures
import json
import math
import os
import re
import socket
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

CONFIG = os.environ.get("STATUS_PUSH_CONFIG", "/etc/status-push/config.json")
# Cloudflare sits in front of the push endpoint and refuses Python's default user agent (error 1010, a 403), so every
# request, including the local health checks, sends this one.
USER_AGENT = "status-push/1"
TOKEN = re.compile(r"[A-Za-z0-9]{8,128}")
MESSAGE_LIMIT = 200


def check_systemd(test):
    rc = subprocess.run(["systemctl", "is-active", "--quiet", test["unit"]], timeout=10, check=False).returncode
    return None if rc == 0 else f"{test['unit']} is not active"


def check_tcp(test):
    try:
        socket.create_connection((test["host"], int(test["port"])), timeout=test.get("timeout", 5)).close()
    except OSError as error:
        return f"{test['host']}:{test['port']} refused ({error.__class__.__name__})"
    return None


def check_http(test):
    want = int(test.get("status", 200))
    context = ssl.create_default_context(cafile=test["cafile"]) if test.get("cafile") else None
    request = urllib.request.Request(test["url"], headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=test.get("timeout", 8), context=context) as response:
            got = response.status
    except urllib.error.HTTPError as error:
        got = error.code
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, "reason", error)
        return f"{test['url']} unreachable ({reason.__class__.__name__})"
    return None if got == want else f"{test['url']} answered {got}, want {want}"


def percent_used(path):
    """What df prints in its Use% column: used / (used + available to ordinary users), rounded up."""
    stat = os.statvfs(path)
    used = stat.f_blocks - stat.f_bfree
    total = used + stat.f_bavail
    return 100 if total == 0 else math.ceil(100 * used / total)


def check_disk(test):
    full = []
    for path in test["paths"]:
        try:
            percent = percent_used(path)
        except OSError as error:
            full.append(f"{path} unreadable ({error.__class__.__name__})")
            continue
        if percent > test["max_percent"]:
            full.append(f"{path} {percent}% used")
    return "; ".join(full) if full else None


CHECKS = {"systemd": check_systemd, "tcp": check_tcp, "http": check_http, "disk": check_disk}


def run_monitor(monitor):
    """Return (up, message): every test must pass, and each failure is named."""
    failures = []
    for test in monitor["tests"]:
        try:
            problem = CHECKS[test["kind"]](test)
        except Exception as error:  # a broken check must report down, not stop the others
            problem = f"{test.get('kind')} check failed to run ({error.__class__.__name__})"
        if problem:
            failures.append(problem)
    return (not failures), ("OK" if not failures else "; ".join(failures))[:MESSAGE_LIMIT]


def push(base_url, token, up, message):
    query = urllib.parse.urlencode({"status": "up" if up else "down", "msg": message})
    request = urllib.request.Request(f"{base_url}/api/push/{token}?{query}", headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=10) as response:
        response.read()


def main():
    with open(CONFIG, encoding="utf-8") as handle:
        config = json.load(handle)
    credentials = os.environ.get("CREDENTIALS_DIRECTORY")
    if not credentials:
        print("CREDENTIALS_DIRECTORY is not set: the tokens come from a systemd credential", file=sys.stderr)
        return 1
    with open(os.path.join(credentials, "tokens"), encoding="utf-8") as handle:
        tokens = json.load(handle)
    base_url = config["base_url"].rstrip("/")

    def report(monitor):
        name = monitor["name"]
        up, message = run_monitor(monitor)
        token = tokens.get(name)
        if not token or not TOKEN.fullmatch(str(token)):
            print(f"{name}: no usable token, not reported ({'up' if up else 'DOWN: ' + message})", file=sys.stderr)
            return
        try:
            push(base_url, token, up, message)
        except (urllib.error.URLError, OSError) as error:
            # The error text can carry the address; say only what kind of failure it was
            print(f"{name}: push failed ({error.__class__.__name__})", file=sys.stderr)
            return
        print(f"{name}: {'up' if up else 'DOWN: ' + message}")

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(report, config["monitors"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
