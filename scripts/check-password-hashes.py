#!/usr/bin/env python3
"""Fail if a tracked text file holds a password hash (crypt $6$/$y$/$5$ or a GRUB PBKDF2 hash).

The pattern is the `no-password-hashes` hook's in .pre-commit-config.yaml, read from there so the laptop hook and the
pipeline can never disagree. Prints file and line, never the matching text.

    scripts/check-password-hashes.py            scan the files git tracks
    scripts/check-password-hashes.py FILE...    scan those files
"""
import pathlib
import re
import subprocess
import sys

import yaml

root = pathlib.Path(__file__).resolve().parent.parent
config = yaml.safe_load((root / ".pre-commit-config.yaml").read_text())
pattern = next(h["entry"] for r in config["repos"] for h in r["hooks"] if h["id"] == "no-password-hashes")
regex = re.compile(pattern)

if len(sys.argv) > 1:
    files = [pathlib.Path(a) for a in sys.argv[1:]]
else:
    try:
        listed = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], check=True, capture_output=True).stdout
        files = [root / name for name in listed.decode().split("\0") if name]
    except (FileNotFoundError, subprocess.CalledProcessError):
        # No git (a CI container only has the checked-out files): walk the tree, leaving out .git
        files = [path for path in root.rglob("*") if path.is_file() and ".git" not in path.relative_to(root).parts]

found = 0
scanned = 0
for path in files:
    try:
        data = path.read_bytes()
    except OSError:
        continue
    if b"\0" in data[:8192]:  # binary: the hook only looks at text
        continue
    scanned += 1
    for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
        if regex.search(line):
            print(f"{path}:{number}: looks like a password hash")
            found += 1
print(f"{scanned} text files scanned, {found} possible password hashes")
sys.exit(1 if found else 0)
