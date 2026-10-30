#!/usr/bin/env python3
"""Check that the mirror of a repository is the same as its source.

GitLab pushes `main` to GitHub after every change. If that push breaks (an expired token, a refused ref, someone
pushing to GitHub directly), nothing says so: the GitHub copy just goes stale. This compares the branch's commit on
both sides. Both repositories are public, so no credentials are involved. A difference is given a grace period (the
mirror pushes within a minute or two of a change) and only counts if it is still there afterwards.

    gitlab_mirror_check.py [--grace SECONDS] SOURCE_URL MIRROR_URL BRANCH

Exit 0: identical. Exit 1: a difference that lasted, or a side that cannot be reached.
"""
import argparse
import os
import subprocess
import sys
import time


class RemoteError(Exception):
    pass


def remote_sha(url, branch):
    """The commit a branch points to on a remote, without cloning it."""
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="true")
    try:
        run = subprocess.run(["git", "ls-remote", "--exit-code", url, f"refs/heads/{branch}"],
                             capture_output=True, text=True, timeout=90, env=env)
    except subprocess.TimeoutExpired:
        raise RemoteError(f"{url} did not answer within 90 seconds")
    except FileNotFoundError:
        raise RemoteError("git is not installed")
    if run.returncode != 0:
        raise RemoteError(f"{url} has no readable branch {branch} ({(run.stderr.strip().splitlines() or ['no message'])[-1]})")
    return run.stdout.split()[0]


def check(source, mirror, branch, grace, fetch=remote_sha, sleep=time.sleep):
    """(ok, message). A difference is checked again once after the grace period."""
    for attempt in (1, 2):
        try:
            theirs, ours = fetch(source, branch), fetch(mirror, branch)
        except RemoteError as problem:
            return False, str(problem)
        if theirs == ours:
            return True, f"{branch} is {ours[:12]} on both"
        if attempt == 1:
            sleep(grace)
    return False, f"{branch} differs: source {theirs[:12]}, mirror {ours[:12]} (still after {grace}s)"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--grace", type=int, default=180)
    parser.add_argument("source")
    parser.add_argument("mirror")
    parser.add_argument("branch")
    args = parser.parse_args(argv)
    ok, message = check(args.source, args.mirror, args.branch, args.grace)
    print(("ok: " if ok else "MIRROR PROBLEM: ") + message)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
