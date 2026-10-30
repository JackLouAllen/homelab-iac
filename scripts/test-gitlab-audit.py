#!/usr/bin/env python3
"""Tests for the GitLab audit log converter (ansible/roles/gitlab/files/gitlab_audit.py).

    scripts/test-gitlab-audit.py            run the tests
    scripts/test-gitlab-audit.py --write    also regenerate scripts/gitlab-audit-samples.{log,labels}: the converter's
                                            output for the real samples, which test-gitlab-wazuh-rules.sh feeds to Wazuh
"""
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True  # importing the role file must not leave a __pycache__ in the role
HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("gitlab_audit", HERE.parent / "ansible/roles/gitlab/files/gitlab_audit.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

# label of a real sample -> (log it came from, event it must produce or None)
SAMPLES = {
    "failed sign-in": ("application_json", "login_failed"),
    "admin sign-in": ("application_json", "login_ok"),
    "rate limited request": ("auth", "rate_limited"),
    "API: project made public": ("api_json", "made_public"),
    "API: project made private (no alert)": ("api_json", None),
    "API: token created": ("api_json", "token_created"),
    "API: user created": ("api_json", "user_created"),
    "web: project made public": ("production_json", "made_public"),
    "web: project made private (no alert)": ("production_json", None),
    "web: token created": ("production_json", "token_created"),
    "web: token form rejected (no alert)": ("production_json", None),
    "exception": ("exceptions_json", "exception"),
    "an ordinary page view (no alert)": ("production_json", None),
}


def samples():
    lines = (HERE / "gitlab-raw-samples.log").read_text().splitlines()
    labels = (HERE / "gitlab-raw-samples.labels").read_text().splitlines()
    assert len(lines) == len(labels), "one label per sample line"
    return list(zip(labels, lines))


class RealSamples(unittest.TestCase):
    def test_every_sample_gives_the_intended_event(self):
        for label, line in samples():
            source, want = SAMPLES[label]
            got = audit.convert_line(source, line)
            self.assertEqual(got["event"] if got else None, want, label)

    def test_events_are_flat_short_strings(self):
        for label, line in samples():
            got = audit.convert_line(SAMPLES[label][0], line)
            if got:
                for key, value in got.items():
                    self.assertIsInstance(value, str, f"{label}: {key}")
                    self.assertLessEqual(len(value), 120, f"{label}: {key}")

    def test_no_secret_shaped_values_get_through(self):
        for label, line in samples():
            got = audit.convert_line(SAMPLES[label][0], line)
            self.assertNotIn("glpat-", json.dumps(got), label)


class Synthetic(unittest.TestCase):
    def web(self, controller, action, params, status=302):
        return {"time": "2026-10-30T05:00:00.000Z", "controller": controller, "action": action, "status": status,
                "username": "jackl", "remote_ip": "100.64.0.9", "path": "/jackl/x", "params": params}

    def test_new_public_project_counts(self):
        d = self.web("ProjectsController", "create", [{"key": "project", "value": {"visibility_level": "20"}}])
        self.assertEqual(audit.convert("production_json", d)["event"], "made_public")

    def test_group_made_public(self):
        d = self.web("GroupsController", "update", [{"key": "group", "value": {"visibility_level": "20"}}])
        self.assertEqual(audit.convert("production_json", d)["event"], "made_public")

    def test_private_and_internal_do_not_alert(self):
        for level in ("0", "10"):
            d = self.web("ProjectsController", "update", [{"key": "project", "value": {"visibility_level": level}}])
            self.assertIsNone(audit.convert("production_json", d))

    def test_deploy_and_project_tokens_count(self):
        for path in ("/api/v4/projects/7/access_tokens", "/api/v4/groups/3/deploy_tokens", "/api/v4/user/personal_access_tokens"):
            d = {"time": "t", "method": "POST", "path": path, "status": 201, "username": "jackl", "remote_ip": "1.2.3.4"}
            self.assertEqual(audit.convert("api_json", d)["event"], "token_created", path)

    def test_a_failed_request_does_not_alert(self):
        d = {"time": "t", "method": "POST", "path": "/api/v4/users", "status": 403, "username": "x", "remote_ip": "1.2.3.4"}
        self.assertIsNone(audit.convert("api_json", d))

    def test_date_like_values_cannot_set_a_field_to_a_date(self):
        for value in ("2026-12-01", "2026", "2026/10/30 05:00:00 +0000", "2026-10-30T05:00:00Z"):
            d = {"time": "t", "message": f"Failed Login: username={value} ip=1.2.3.4"}
            self.assertTrue(audit.convert("application_json", d)["user"].startswith("~"), value)
        d = {"time": "t", "message": "Failed Login: username=jackl ip=1.2.3.4"}
        self.assertEqual(audit.convert("application_json", d)["user"], "jackl")

    def test_control_characters_and_length_are_dealt_with(self):
        self.assertEqual(audit.clean("a\nb\x00c"), "a b c")
        self.assertEqual(len(audit.clean("x" * 500)), 120)

    def test_only_the_first_address_of_a_forwarded_list_is_kept(self):
        self.assertEqual(audit.client_ip({"remote_ip": "203.0.113.7, 203.0.113.7"}), "203.0.113.7")

    def test_a_username_with_spaces_is_still_recorded(self):
        d = {"time": "t", "message": "Failed Login: username=two words ip=1.2.3.4"}
        got = audit.convert("application_json", d)
        self.assertEqual((got["user"], got["ip"]), ("two words", "1.2.3.4"))

    def test_garbage_lines_are_ignored(self):
        for line in ("", "# Logfile created", "{not json", "[1,2]", "null"):
            self.assertIsNone(audit.convert_line("production_json", line))


class Tailing(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "a.log")

    def tearDown(self):
        self.dir.cleanup()

    def tail(self, *args):
        t = audit.Tailer(*args)
        self.addCleanup(t.close)
        return t

    def add(self, text, mode="a"):
        with open(self.path, mode) as fh:
            fh.write(text)

    def test_first_run_starts_at_the_end_then_follows(self):
        self.add("old\n")
        t = self.tail(self.path)
        self.assertEqual(t.poll(), [])
        self.add("new1\nnew2\n")
        self.assertEqual(t.poll(), ["new1", "new2"])

    def test_waits_for_the_rest_of_a_partial_line(self):
        t = self.tail(self.path)
        self.add("")
        t.poll()
        self.add("half")
        self.assertEqual(t.poll(), [])
        self.add(" done\n")
        self.assertEqual(t.poll(), ["half done"])

    def test_rotation_finishes_the_old_file_and_reads_the_new_one(self):
        self.add("")
        t = self.tail(self.path)
        t.poll()
        self.add("before\n")
        os.rename(self.path, self.path + ".1")
        self.add("after\n", "w")
        self.assertEqual(t.poll(), ["before", "after"])

    def test_truncation_in_place_starts_again(self):
        self.add("")
        t = self.tail(self.path)
        t.poll()
        self.add("one\ntwo\nthree\n")
        t.poll()
        self.add("fresh\n", "w")
        self.assertEqual(t.poll(), ["fresh"])

    def test_restart_resumes_where_it_stopped_and_misses_nothing(self):
        self.add("")
        t = self.tail(self.path)
        t.poll()
        self.add("a\n")
        t.poll()
        saved = tuple(t.position())
        self.add("b\nc\n")  # written while the service is down
        t2 = self.tail(self.path, saved)
        self.assertEqual(t2.poll(), ["b", "c"])

    def test_restart_after_rotation_reads_the_new_file_from_its_top(self):
        self.add("")
        t = self.tail(self.path)
        t.poll()
        self.add("a\n")
        t.poll()
        saved = tuple(t.position())
        os.rename(self.path, self.path + ".1")
        self.add("x\ny\n", "w")
        self.assertEqual(self.tail(self.path, saved).poll(), ["x", "y"])

    def test_a_file_that_appears_later_is_followed_from_its_start_on_a_resume(self):
        t = self.tail(self.path)
        self.assertEqual(t.poll(), [])
        self.add("hello\n")
        self.assertEqual(t.poll(), [])  # first-ever open starts at the end by design


class Startup(unittest.TestCase):
    def test_fails_loudly_when_it_finds_none_of_the_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit) as caught:
                audit.follow(tmp, os.path.join(tmp, "out"), os.path.join(tmp, "state"), stop=lambda: True)
            self.assertIn("none of the GitLab logs", str(caught.exception))

    def test_the_role_points_at_the_directory_gitlab_really_writes_to(self):
        defaults = (HERE.parent / "ansible/roles/gitlab/defaults/main.yml").read_text()
        self.assertIn("gitlab_audit_source_dir: /var/log/gitlab/gitlab-rails", defaults)
        unit = (HERE.parent / "ansible/roles/gitlab/templates/gitlab-audit.service.j2").read_text()
        self.assertIn("follow {{ gitlab_audit_source_dir }}", unit)


class EndToEnd(unittest.TestCase):
    """The service loop: five logs in, one flat audit file out, nothing lost or repeated across a restart."""

    def run_follow(self, log_dir, out, state, until):
        import threading
        import time
        stop = threading.Event()
        thread = threading.Thread(target=audit.follow, args=(log_dir, out, state), kwargs={"interval": 0.02, "stop": stop.is_set})
        thread.start()
        deadline = time.time() + 5
        while time.time() < deadline and not until():
            time.sleep(0.05)
        time.sleep(0.2)
        stop.set()
        thread.join()

    def test_real_samples_flow_through_once_even_across_a_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            logs, out, state = os.path.join(tmp, "logs"), os.path.join(tmp, "audit.json"), os.path.join(tmp, "state.json")
            os.mkdir(logs)
            for name in audit.SOURCES:
                open(os.path.join(logs, name + ".log"), "w").close()
            pairs = samples()
            first, second = pairs[:7], pairs[7:]

            def append(batch):
                for label, line in batch:
                    with open(os.path.join(logs, SAMPLES[label][0] + ".log"), "a") as fh:
                        fh.write(line + "\n")

            def written():
                if not os.path.exists(out):
                    return []
                with open(out) as fh:
                    return [json.loads(line)["event"] for line in fh]

            import threading
            t = threading.Timer(0.3, append, args=(first,))
            t.start()
            self.run_follow(logs, out, state, until=lambda: not t.is_alive() and len(written()) >= sum(1 for l, _ in first if SAMPLES[l][1]))
            append(second)  # written while the service is down
            self.run_follow(logs, out, state, until=lambda: len(written()) >= sum(1 for l, _ in pairs if SAMPLES[l][1]))
            want = sorted(SAMPLES[l][1] for l, _ in pairs if SAMPLES[l][1])
            self.assertEqual(sorted(written()), want)


def write_samples():
    events, labels = [], []
    for label, line in samples():
        got = audit.convert_line(SAMPLES[label][0], line)
        if got:
            events.append(json.dumps(got, separators=(",", ":")))
            labels.append(label)
    (HERE / "gitlab-audit-samples.log").write_text("\n".join(events) + "\n")
    (HERE / "gitlab-audit-samples.labels").write_text("\n".join(labels) + "\n")
    print(f"wrote {len(events)} audit samples")


if __name__ == "__main__":
    write = "--write" in sys.argv
    sys.argv = [a for a in sys.argv if a != "--write"]
    result = unittest.main(exit=False, verbosity=1).result
    if write and result.wasSuccessful():
        write_samples()
    sys.exit(0 if result.wasSuccessful() else 1)
