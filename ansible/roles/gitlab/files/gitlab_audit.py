#!/usr/bin/env python3
"""Turn GitLab's JSON logs into a short, flat audit log for Wazuh.

GitLab writes one JSON object per line, with dozens of fields whose names and types vary by request. Wazuh stores
every field of a decoded line, and the index fixes a field's type from the first value it sees. One date-like
value in data.params.value made every later alert with ordinary text there unindexable, silently. So only the
events worth an alert are written, with a fixed set of short string fields, and any value that could be read as a
date is marked so it cannot pick the type.

    gitlab_audit.py follow LOG_DIR OUT_FILE STATE_FILE    run as a service
    gitlab_audit.py convert SOURCE < lines                print the events for lines of one log (used by tests)
"""
import json
import os
import re
import sys
import time

SOURCES = ("application_json", "auth", "api_json", "production_json", "exceptions_json")

# What Elasticsearch's dynamic mapping reads as a date: strict_date_optional_time starts with a year, and a bare
# year counts. A value like that gets a "~" in front.
DATE_LIKE = re.compile(r"^\d{4}(?:[-/]|$)")
TOKEN_PATH = re.compile(r"^/api/v4/(?:users?/(?:\d+/)?personal_access_tokens|(?:projects|groups)/[^/]+/(?:access_tokens|deploy_tokens))")
EXPOSING = {"public", "20"}


def clean(value, limit=120):
    """A short, single-line string that the index cannot mistake for a date."""
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(value if value is not None else "")).strip()[:limit]
    return "~" + text if DATE_LIKE.match(text) else text


def client_ip(d):
    ip = d.get("remote_ip") or d.get("meta.remote_ip") or ""
    return str(ip).split(",")[0].strip()


def visibilities(node):
    """Every visibility value in a params structure, wherever it is nested."""
    found = set()
    if isinstance(node, dict):
        if "key" in node and "value" in node and node["key"] in ("visibility", "visibility_level"):
            found.add(str(node["value"]))
        for key, value in node.items():
            if key in ("visibility", "visibility_level") and not isinstance(value, (dict, list)):
                found.add(str(value))
            found |= visibilities(value)
    elif isinstance(node, list):
        for item in node:
            found |= visibilities(item)
    return found


def event(name, d, **fields):
    # No timestamp: Wazuh stamps each alert itself, and a date-typed field of ours could only cause refusals
    out = {"src": "gitlab", "event": name}
    out.update({key: clean(value) for key, value in fields.items()})
    return out


def convert(source, d):
    """The audit event for one log line, or None when it is not worth an alert."""
    if source == "application_json":
        message = str(d.get("message", ""))
        m = re.match(r"Failed Login: username=(.*) ip=(\S+)$", message)
        if m:
            return event("login_failed", d, user=m[1], ip=m[2])
        m = re.match(r"Successful Login: username=(.*) ip=(\S+) method=(\S+) admin=(true|false)$", message)
        if m:
            return event("login_ok", d, user=m[1], ip=m[2], via=m[3], admin="yes" if m[4] == "true" else "no")
    elif source == "auth":
        if d.get("message") == "Application_Rate_Limiter_Request":
            return event("rate_limited", d, ip=client_ip(d), limit=d.get("env"), path=str(d.get("path", "")).split("?")[0])
    elif source == "production_json":
        controller, action, status = str(d.get("controller")), d.get("action"), d.get("status")
        who = dict(user=d.get("username"), ip=client_ip(d), path=str(d.get("path", "")).split("?")[0])
        if controller in ("ProjectsController", "GroupsController") and action in ("create", "update") \
                and status in (200, 302) and visibilities(d.get("params")) & EXPOSING:
            return event("made_public", d, via="web", **who)
        if controller == "UserSettings::PersonalAccessTokensController" and action == "create" and status in (200, 201, 302):
            return event("token_created", d, via="web", **who)
    elif source == "api_json":
        method, path, status = d.get("method"), str(d.get("path", "")), d.get("status")
        who = dict(user=d.get("username"), ip=client_ip(d), path=path.split("?")[0])
        if method in ("POST", "PUT") and re.match(r"^/api/v4/(?:projects|groups)(?:/[^/]+)?$", path) \
                and status in (200, 201) and visibilities(d.get("params")) & EXPOSING:
            return event("made_public", d, via="api", **who)
        if method == "POST" and TOKEN_PATH.match(path) and status == 201:
            return event("token_created", d, via="api", **who)
        if method == "POST" and path == "/api/v4/users" and status == 201:
            return event("user_created", d, via="api", **who)
    elif source == "exceptions_json":
        if d.get("exception.class"):
            return event("exception", d, kind=d.get("exception.class"), ip=client_ip(d))
    return None


def convert_line(source, line):
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        d = json.loads(line)
    except ValueError:
        return None
    return convert(source, d) if isinstance(d, dict) else None


class Tailer:
    """Follows one log file: complete lines only, survives rotation and truncation, remembers its place."""

    def __init__(self, path, position=None):
        self.path, self.fh, self.inode, self.buffer = path, None, None, b""
        self.start = position  # (inode, offset) saved by an earlier run, or None for a first run

    def _open(self, at_start):
        self.fh = open(self.path, "rb")
        self.inode = os.fstat(self.fh.fileno()).st_ino
        self.buffer = b""
        if not at_start:
            self.fh.seek(0, os.SEEK_END)

    def _drain(self):
        lines = []
        while True:
            chunk = self.fh.read(1 << 20)
            if not chunk:
                break
            self.buffer += chunk
            *whole, self.buffer = self.buffer.split(b"\n")
            lines += [part.decode("utf-8", "replace") for part in whole]
        return lines

    def poll(self):
        lines = []
        if self.fh is None:
            if not os.path.exists(self.path):
                return lines
            first = self.start is None
            self._open(at_start=not first)
            if not first and self.start[0] == self.inode:
                self.fh.seek(min(self.start[1], os.fstat(self.fh.fileno()).st_size))
            self.start = (self.inode, 0)
            if first:
                return lines
        lines += self._drain()
        try:
            on_disk = os.stat(self.path)
        except FileNotFoundError:
            return lines
        if on_disk.st_ino != self.inode:  # rotated: finish the old file, then start the new one from its top
            lines += self._drain()
            self.fh.close()
            self._open(at_start=True)
            lines += self._drain()
        elif on_disk.st_size < self.fh.tell():  # truncated in place
            self.fh.seek(0)
            self.buffer = b""
            lines += self._drain()
        return lines

    def close(self):
        if self.fh:
            self.fh.close()

    def position(self):
        return [self.inode, self.fh.tell() - len(self.buffer)] if self.fh else None


def load_state(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, path)


def follow(log_dir, out_file, state_file, interval=1.0, stop=lambda: False):
    saved = load_state(state_file)
    tailers = {name: Tailer(os.path.join(log_dir, name + ".log"), tuple(saved[name]) if saved.get(name) else None)
               for name in SOURCES}
    try:
        while not stop():
            out, positions = [], {}
            for name, tailer in tailers.items():
                for line in tailer.poll():
                    found = convert_line(name, line)
                    if found:
                        out.append(json.dumps(found, separators=(",", ":")))
                if tailer.position():
                    positions[name] = tailer.position()
            if out:
                with open(out_file, "a") as fh:
                    fh.write("\n".join(out) + "\n")
            if positions != saved:
                save_state(state_file, positions)
                saved = positions
            time.sleep(interval)
    finally:
        for tailer in tailers.values():
            tailer.close()


def main(argv):
    if len(argv) == 5 and argv[1] == "follow":
        follow(argv[2], argv[3], argv[4])
    elif len(argv) == 3 and argv[1] == "convert" and argv[2] in SOURCES:
        for line in sys.stdin:
            found = convert_line(argv[2], line)
            if found:
                print(json.dumps(found, separators=(",", ":")))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
