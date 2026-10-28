#!/usr/bin/env python3
"""Show what changed between two keycloak-realm-snapshot.py files, one setting per line.

    keycloak-snapshot-diff.py before.json after.json
"""
import json
import sys


def flat(d, prefix=""):
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(flat(v, f"{prefix}.{k}" if prefix else k))
    else:
        out[prefix] = d
    return out


if len(sys.argv) != 3:
    sys.exit(__doc__)
before, after = (json.load(open(p)) for p in sys.argv[1:])

changes = 0
for section in ("realm", "events_config", "default_roles", "required_actions"):
    b, a = flat(before[section], section), flat(after[section], section)
    for key in sorted(set(b) | set(a)):
        if b.get(key) != a.get(key):
            changes += 1
            print(f"{key}: {repr(b.get(key))[:70]} -> {repr(a.get(key))[:70]}")
for name in sorted(set(after["flows"]) - set(before["flows"])):
    changes += 1
    print(f"flow added: {name}")
for name in sorted(set(before["flows"]) - set(after["flows"])):
    changes += 1
    print(f"flow REMOVED: {name}")
print(f"{changes} difference(s)")
