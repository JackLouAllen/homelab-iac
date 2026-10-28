#!/usr/bin/env python3
"""Render the edge role's nginx.conf from its defaults plus group_vars/oci.yml overrides.

Usage: render-edge-nginx.py [--templates DIR] [--set key=json ...] > nginx.conf
Used to diff the live config before and after a template change and to feed the container test.
"""
import argparse
import ast
import json
import pathlib

import jinja2
import yaml

root = pathlib.Path(__file__).resolve().parent.parent
role = root / "ansible/roles/edge"

ap = argparse.ArgumentParser()
ap.add_argument("--templates", type=pathlib.Path, default=role / "templates")
ap.add_argument("--set", action="append", default=[], metavar="KEY=JSON")
args = ap.parse_args()

vars_ = yaml.safe_load((role / "defaults/main.yml").read_text())
vars_.update(yaml.safe_load((root / "ansible/inventory/group_vars/oci.yml").read_text()))
vars_["edge_tailnet_ip"] = "100.64.0.1"
for item in args.set:
    key, value = item.split("=", 1)
    vars_[key] = json.loads(value)

# Resolve variables that reference other variables the way Ansible does, strings nested in lists
# and dicts included.
env = jinja2.Environment(undefined=jinja2.StrictUndefined, trim_blocks=True)


def resolve(value):
    if isinstance(value, str) and "{{" in value:
        out = env.from_string(value).render(**vars_)
        if out[:1] in "[{":  # Ansible turns a rendered list or dict back into one
            return ast.literal_eval(out)
        return out
    if isinstance(value, list):
        return [resolve(v) for v in value]
    if isinstance(value, dict):
        return {k: resolve(v) for k, v in value.items()}
    return value


vars_ = {k: resolve(v) for k, v in vars_.items()}
env = jinja2.Environment(
    loader=jinja2.FileSystemLoader(args.templates),
    undefined=jinja2.StrictUndefined,
    trim_blocks=True,
)
print(env.get_template("nginx.conf.j2").render(**vars_), end="")
