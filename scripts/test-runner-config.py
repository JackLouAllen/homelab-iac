#!/usr/bin/env python3
"""Check the runner's config.toml template.

GitLab Runner loads a config with unknown settings without a word, so a misspelt limit would simply not exist. This
renders the role's template and checks every key against the runner's own source code at the version the role pins
(needs network: gitlab.com), then asserts the isolation settings are what the design says.

    scripts/test-runner-config.py
"""
import pathlib
import re
import sys
import tomllib
import urllib.request

import jinja2
import yaml

sys.dont_write_bytecode = True
repo = pathlib.Path(__file__).resolve().parent.parent
role = repo / "ansible/roles/runner"
v = yaml.safe_load((role / "defaults/main.yml").read_text())
v.update(runner_gitlab_address="100.73.97.17", runner_token="glrt-" + "x" * 24, inventory_hostname="oci1")
env = jinja2.Environment(loader=jinja2.FileSystemLoader(role / "templates"), undefined=jinja2.StrictUndefined, trim_blocks=True)
res = lambda x: env.from_string(x).render(**v) if isinstance(x, str) and "{{" in x else x
for _ in range(3):
    v = {k: res(x) for k, x in v.items()}
text = env.get_template("config.toml.j2").render(**v)
cfg = tomllib.loads(text)

tag = "v" + v["runner_version"].rsplit("-", 1)[0]
known = set()
for path in ("common/config.go", "helpers/docker/credentials.go"):
    url = f"https://gitlab.com/gitlab-org/gitlab-runner/-/raw/{tag}/{path}"
    with urllib.request.urlopen(url, timeout=60) as response:
        known |= set(re.findall(r'toml:"([a-z0-9_-]+)', response.read().decode()))


def keys(node):
    for key, value in node.items():
        yield key
        if isinstance(value, dict):
            yield from keys(value)
        if isinstance(value, list) and value and isinstance(value[0], dict):
            for item in value:
                yield from keys(item)


failures = []


def check(name, ok):
    print(("ok    " if ok else "FAIL  ") + name)
    if not ok:
        failures.append(name)


unknown = sorted(k for k in set(keys(cfg)) if k not in known and k not in ("runners", "docker"))
check(f"every setting in the config exists in the runner's code ({tag}, {len(known)} known names)", not unknown)
if unknown:
    print("      unknown:", unknown)
bogus = tomllib.loads(text.replace("privileged = false", "privileged = false\npids_limitt = 5"))
check("control: a misspelt setting is noticed", any(k not in known for k in keys(bogus) if k not in ("runners", "docker")))

d = cfg["runners"][0]["docker"]
check("not privileged", d["privileged"] is False)
check("one job at a time", cfg["concurrent"] == 1)
check("memory cap, and swap equal to it (so no swap)", d["memory"] == d["memory_swap"] and d["memory"].endswith("g"))
check("CPU cap", float(d["cpus"]) > 0)
check("no new privileges", "no-new-privileges" in d["security_opt"])
check("images only from fully qualified registries", all("/" in p and "." in p.split("/")[0] for p in d["allowed_images"]))
# The runner treats an empty allow-list as "everything allowed": none of them may be empty
for name in ("allowed_images", "allowed_services", "allowed_pull_policies"):
    check(f"{name} is never empty (empty would mean everything)", len(d[name]) > 0)
check("no service image can match", all(p.startswith("denied.invalid/") for p in d["allowed_services"]))
check("pull policy fixed to if-not-present", d["pull_policy"] == ["if-not-present"] == d["allowed_pull_policies"])
check("runner socket is the account's own", d["host"] == "unix:///run/user/2003/podman/podman.sock")
check("jobs find GitLab at the address the firewall allows", d["extra_hosts"] == ["git.jacklouallen.info:100.73.97.17"])
check("no volumes are mounted into jobs", "volumes" not in d)
check("the socket is not mounted into jobs", "podman.sock" not in str(d.get("volumes", "")))
sys.exit(1 if failures else 0)
