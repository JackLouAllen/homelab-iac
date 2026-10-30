#!/usr/bin/env python3
"""Check the runner's image allow-list with the runner's own matching library.

The runner matches `allowed_images` with doublestar (`*` stays inside one path segment, `**` crosses them). A pattern that
looks right can match nothing (`ghcr.io/*` never matches `ghcr.io/org/name:tag`), and a pipeline then fails with
"disallowed image". This runs doublestar at the version the runner pins (needs docker and network) against the role's
real patterns: every image the pipeline uses must be allowed, and look-alikes and other registries must not be.

    scripts/test-runner-allowlist.py
"""
import json
import pathlib
import subprocess
import sys
import tempfile

import yaml

root = pathlib.Path(__file__).resolve().parent.parent
defaults = yaml.safe_load((root / "ansible/roles/runner/defaults/main.yml").read_text())
patterns = defaults["runner_allowed_images"]

ci = yaml.safe_load((root / ".gitlab-ci.yml").read_text())
templates = {k: v for k, v in ci.items() if k.startswith(".") and isinstance(v, dict)}
pipeline_images = []
for name, job in ci.items():
    if isinstance(job, dict) and "script" in job:
        base = {}
        for parent in ([job["extends"]] if isinstance(job.get("extends"), str) else job.get("extends", [])):
            base.update(templates[parent])
        image = job.get("image", base.get("image"))
        pipeline_images.append(image["name"] if isinstance(image, dict) else image)

digest = "@sha256:" + "0" * 64
should_allow = sorted(set(pipeline_images)) + [
    "ghcr.io/org/name:1.2.3", "ghcr.io/org/name" + digest, "ghcr.io/org/team/name:latest",
    "quay.io/org/name:1", "docker.io/library/python:3.13-slim", "registry.access.redhat.com/ubi10/ubi-minimal:latest",
]
should_refuse = [
    "alpine:3", "python:3.13", "registry.example.org/anything/at-all:1", "docker.io/someuser/image:1",
    "ghcr.io.evil.example/org/name:1", "quay.io.attacker.net/a/b:1", "evil.example/ghcr.io/org/name:1",
    "registry.access.redhat.com.evil.example/ubi10/ubi:1", "docker.io/library", "docker.io/library/", "ghcr.io", "ghcr.io/", "quay.io", "registry.access.redhat.com", "",
]
version = subprocess.run(["curl", "-s", "-m", "60", "https://gitlab.com/gitlab-org/gitlab-runner/-/raw/v" + defaults["runner_version"].rsplit("-", 1)[0] + "/go.mod"],
                         capture_output=True, text=True, check=True).stdout
doublestar = next(line.split()[1] for line in version.splitlines() if "bmatcuk/doublestar/v4" in line)

program = '''package main

import (
	"encoding/json"
	"os"

	"github.com/bmatcuk/doublestar/v4"
)

type input struct {
	Patterns []string `json:"patterns"`
	Images   []string `json:"images"`
}

func main() {
	var in input
	_ = json.NewDecoder(os.Stdin).Decode(&in)
	out := map[string]bool{}
	for _, image := range in.Images {
		allowed := false
		for _, p := range in.Patterns {
			if ok, _ := doublestar.Match(p, image); ok {
				allowed = true
			}
		}
		out[image] = allowed
	}
	_ = json.NewEncoder(os.Stdout).Encode(out)
}
'''
with tempfile.TemporaryDirectory() as tmp:
    pathlib.Path(tmp, "main.go").write_text(program)
    payload = json.dumps({"patterns": patterns, "images": should_allow + should_refuse})
    script = f"cd /src && go mod init allowlist >/dev/null 2>&1 && go get github.com/bmatcuk/doublestar/v4@{doublestar} >/dev/null 2>&1 && go run ."
    run = subprocess.run(["docker", "run", "--rm", "-i", "-v", f"{tmp}:/src", "docker.io/library/golang:1.24", "sh", "-c", script],
                         input=payload, capture_output=True, text=True)
if run.returncode != 0:
    sys.exit("could not run the matcher:\n" + run.stderr[-600:])
result = json.loads(run.stdout)

failures = 0
print(f"patterns: {patterns}  (doublestar {doublestar})")
for image in should_allow:
    ok = result[image]
    failures += not ok
    print(("ok    allowed  " if ok else "FAIL  not allowed, but must be: ") + image[:100])
for image in should_refuse:
    ok = not result[image]
    failures += not ok
    print(("ok    refused  " if ok else "FAIL  allowed, but must be refused: ") + (image[:100] or "(empty name)"))
sys.exit(1 if failures else 0)
