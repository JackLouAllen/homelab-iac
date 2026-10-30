#!/usr/bin/env python3
"""Tests for the mirror check (ansible/roles/gitlab/files/gitlab_mirror_check.py), then the real thing.

    scripts/test-gitlab-mirror-check.py           unit tests, plus a run against the real repositories (needs network)
    scripts/test-gitlab-mirror-check.py --offline unit tests only
"""
import importlib.util
import pathlib
import shutil
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent / "ansible/roles/gitlab/files/gitlab_mirror_check.py"
spec = importlib.util.spec_from_file_location("gitlab_mirror_check", SCRIPT)
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)

A, B = "a" * 40, "b" * 40


def fetcher(answers):
    """Answers per URL, one per call: a string is a commit, an exception is raised."""
    calls = {url: list(values) for url, values in answers.items()}

    def fetch(url, branch):
        value = calls[url].pop(0) if len(calls[url]) > 1 else calls[url][0]
        if isinstance(value, Exception):
            raise value
        return value
    return fetch


class Logic(unittest.TestCase):
    def run_check(self, answers, grace=7):
        slept = []
        ok, message = mirror.check("src", "mir", "main", grace, fetch=fetcher(answers), sleep=slept.append)
        return ok, message, slept

    def test_identical_is_fine_and_does_not_wait(self):
        ok, message, slept = self.run_check({"src": [A], "mir": [A]})
        self.assertTrue(ok)
        self.assertEqual(slept, [])

    def test_a_difference_that_clears_during_the_grace_period_is_fine(self):
        ok, message, slept = self.run_check({"src": [B], "mir": [A, B]})
        self.assertTrue(ok)
        self.assertEqual(slept, [7])

    def test_a_difference_that_lasts_is_a_problem(self):
        ok, message, slept = self.run_check({"src": [B], "mir": [A]})
        self.assertFalse(ok)
        self.assertIn("differs", message)
        self.assertIn(B[:12], message)
        self.assertIn(A[:12], message)

    def test_a_mirror_ahead_of_its_source_is_a_problem_too(self):
        ok, message, _ = self.run_check({"src": [A], "mir": [B]})
        self.assertFalse(ok)

    def test_an_unreachable_mirror_is_a_problem_at_once(self):
        ok, message, slept = self.run_check({"src": [A], "mir": [mirror.RemoteError("mir has no readable branch main")]})
        self.assertFalse(ok)
        self.assertEqual(slept, [])

    def test_an_unreachable_source_is_a_problem_at_once(self):
        ok, message, _ = self.run_check({"src": [mirror.RemoteError("src did not answer")], "mir": [A]})
        self.assertFalse(ok)
        self.assertIn("src", message)

    def test_a_remote_that_fails_on_the_second_look_is_a_problem(self):
        ok, message, _ = self.run_check({"src": [B], "mir": [A, mirror.RemoteError("gone")]})
        self.assertFalse(ok)


@unittest.skipUnless(shutil.which("git"), "needs git (the pipeline's Python image has none; the logic tests above cover the same code)")
class Command(unittest.TestCase):
    def test_exit_codes_and_a_missing_branch(self):
        # A local repository stands in for a remote: file:// URLs work with ls-remote
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            repo = pathlib.Path(tmp, "r")
            subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.test", "commit", "-q", "--allow-empty", "-m", "x"], check=True)
            url = f"file://{repo}"
            same = subprocess.run([sys.executable, "-I", str(SCRIPT), "--grace", "0", url, url, "main"], capture_output=True, text=True)
            self.assertEqual(same.returncode, 0, same.stdout)
            missing = subprocess.run([sys.executable, "-I", str(SCRIPT), "--grace", "0", url, url, "nope"], capture_output=True, text=True)
            self.assertEqual(missing.returncode, 1)
            self.assertIn("MIRROR PROBLEM", missing.stdout)
            gone = subprocess.run([sys.executable, "-I", str(SCRIPT), "--grace", "0", url, "file:///nonexistent/repo", "main"], capture_output=True, text=True)
            self.assertEqual(gone.returncode, 1)


class Units(unittest.TestCase):
    def test_the_service_is_started_by_its_timer_only(self):
        # A unit wanted by multi-user.target and ordered after GitLab's unit deadlocks at boot (the audit service did)
        text = (HERE.parent / "ansible/roles/gitlab/templates/gitlab-mirror-check.service.j2").read_text()
        unit = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))  # comments may mention both
        self.assertNotIn("[Install]", unit)
        self.assertNotIn("gitlab-runsvdir", unit)


if __name__ == "__main__":
    offline = "--offline" in sys.argv
    sys.argv = [a for a in sys.argv if a != "--offline"]
    result = unittest.main(exit=False, verbosity=1).result
    ok = result.wasSuccessful()
    if ok and not offline:
        print("\n-- the real repositories")
        real = subprocess.run([sys.executable, "-I", str(SCRIPT), "--grace", "5", "https://git.jacklouallen.info/jackl/homelab-iac.git",
                               "https://github.com/JackLouAllen/homelab-iac.git", "main"], capture_output=True, text=True)
        print(real.stdout.strip() or real.stderr.strip())
        ok = real.returncode == 0
        print("-- control: a mirror that is a different repository must be reported")
        wrong = subprocess.run([sys.executable, "-I", str(SCRIPT), "--grace", "1", "https://git.jacklouallen.info/jackl/homelab-iac.git",
                                "https://github.com/astral-sh/ruff.git", "main"], capture_output=True, text=True)
        print(wrong.stdout.strip() or wrong.stderr.strip())
        ok = ok and wrong.returncode == 1
    sys.exit(0 if ok else 1)
