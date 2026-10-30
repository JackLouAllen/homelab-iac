#!/usr/bin/env python3
"""Check the shape of .gitlab-ci.yml: what a typo or a hurried edit would quietly break.

    scripts/test-pipeline.py [FILE]       FILE defaults to .gitlab-ci.yml (tests use it to try a broken one)
"""
import pathlib
import re
import sys

import yaml

root = pathlib.Path(__file__).resolve().parent.parent
ci = yaml.safe_load((pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / ".gitlab-ci.yml").read_text())
jobs = {name: job for name, job in ci.items() if isinstance(job, dict) and not name.startswith(".") and name not in ("default", "variables", "workflow")}
templates = {name: job for name, job in ci.items() if name.startswith(".") and isinstance(job, dict)}
failures = []


def check(name, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + name + (f" ({detail})" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def image_of(job):
    base = {}
    for parent in ([job["extends"]] if isinstance(job.get("extends"), str) else job.get("extends", [])):
        base = {**base, **templates[parent]}
    image = job.get("image", base.get("image"))
    return image["name"] if isinstance(image, dict) else image


for name, job in jobs.items():
    image = image_of(job)
    check(f"{name}: image pinned by digest", bool(image) and re.search(r"@sha256:[0-9a-f]{64}$", image), image)
    check(f"{name}: has a script", bool(job.get("script")))
    for line in job.get("script", []):
        for path in re.findall(r"(?:^|\s)(scripts/[\w./-]+)", line):
            check(f"{name}: {path} exists", (root / path).exists())
    for line in job.get("script", []):
        if re.search(r"\bpip install\b", line):
            packages = [word for word in line.split("pip install", 1)[1].split() if not word.startswith("-")]
            check(f"{name}: pip packages are pinned ({len(packages)})", bool(packages) and all("==" in word for word in packages), line)
        if re.search(r"\bapt-get install\b", line) and "git" not in line and "python3" not in line:
            check(f"{name}: unexpected apt-get install", False, line)

check("secrets scan reads the whole history", jobs["secrets-scan"]["variables"]["GIT_DEPTH"] == "0")
check("a branch push starts a pipeline", any("CI_COMMIT_BRANCH" in r["if"] for r in ci["workflow"]["rules"]))
check("no job uses privileged services", not any("services" in job for job in jobs.values()))
sys.exit(1 if failures else 0)
