#!/usr/bin/env python3
"""Print a realm's configuration as sorted, stable JSON, so two snapshots can be diffed.

    keycloak-realm-snapshot.py REALM > before.json
    tofu apply
    keycloak-realm-snapshot.py REALM > after.json
    diff before.json after.json

Why: writing a realm replaces whatever the OpenTofu provider does not know about (an attribute set by
hand and not in code is deleted on apply), and a plan cannot show what the provider cannot see. The
snapshot reads the server's own view of the realm, its authentication flows, required actions, event
settings and default roles.

Needs KEYCLOAK_URL, KEYCLOAK_CLIENT_ID and KEYCLOAK_CLIENT_SECRET (the tofu service account).
Client secrets and user credentials are not part of the output.
"""
import json
import os
import sys
import urllib.parse
import urllib.request

realm = sys.argv[1] if len(sys.argv) == 2 else sys.exit(__doc__)
base = os.environ["KEYCLOAK_URL"].rstrip("/")


def call(url, data=None, token=None):
    req = urllib.request.Request(url, data=data)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


token = call(
    base + "/realms/master/protocol/openid-connect/token",
    urllib.parse.urlencode(
        {
            "grant_type": "client_credentials",
            "client_id": os.environ["KEYCLOAK_CLIENT_ID"],
            "client_secret": os.environ["KEYCLOAK_CLIENT_SECRET"],
        }
    ).encode(),
)["access_token"]


def get(path):
    return call(f"{base}/admin/realms/{urllib.parse.quote(realm)}{path}", token=token)


snap = {"realm": get("")}
snap["realm"].pop("id", None)  # differs between instances
snap["events_config"] = get("/events/config")
snap["required_actions"] = sorted(get("/authentication/required-actions"), key=lambda a: a["alias"])
snap["flows"] = {
    f["alias"]: {
        "flow": {k: v for k, v in f.items() if k != "id"},
        "executions": [
            {k: v for k, v in e.items() if k not in ("id", "flowId")}
            for e in get("/authentication/flows/" + urllib.parse.quote(f["alias"]) + "/executions")
        ],
    }
    for f in sorted(get("/authentication/flows"), key=lambda f: f["alias"])
}
snap["default_roles"] = sorted(r["name"] for r in get("/roles/default-roles-" + realm.lower() + "/composites"))

print(json.dumps(snap, indent=2, sort_keys=True))
