# Runner isolation test

A pipeline of jobs that try what a hostile job would try, run against the CI runner on oci1. The design is in
`docs/GITLAB_RUNNER_DESIGN.md`; the settings it checks are in `ansible/roles/runner`.

## Run it

It needs a project the runner serves, and nothing else on the branch it runs from (so it cannot be confused with a
real pipeline). 
```bash
git remote add gitlab https://git.jacklouallen.info/jackl/homelab-iac.git   # once
git switch --orphan runner-isolation-test
git show main:tests/runner-isolation/.gitlab-ci.yml > .gitlab-ci.yml
# the repository's pre-commit hook needs a config this branch does not have; the file holds no secrets
git add .gitlab-ci.yml && PRE_COMMIT_ALLOW_NO_CONFIG=1 git commit -m "Runner isolation test"
git push gitlab runner-isolation-test
git switch main
```

Delete the branch afterwards.

## Read the result

| Stage | Jobs | Must |
|---|---|---|
| `hold` | sanity, user-namespace, capabilities, no-host-sockets, network-allowed, network-blocked, limits-are-set, fork-bomb, memory-bomb | all **pass**: each asserts a limit and fails when it is missing |
| `refused` | refused-unqualified-image, refused-unlisted-registry, refused-pull-always, refused-service | all **fail**, with the runner's own refusal in the log (they are `allow_failure`, so the pipeline shows warnings) |
| `stress` | stress-cpu (manual) | see below |

A refused job that **passes** is a hole: the runner ran something it should have refused.

## The CPU stress job

Four busy loops for a minute on a runner capped at two CPUs. Start it by hand and, while it runs, from another
machine check that the rest of the stack does not notice:

```bash
while sleep 2; do curl -s -o /dev/null -w '%{time_total}s %{http_code}\n' https://git.jacklouallen.info/-/readiness; done
```

(over the tailnet; readiness answers on the private door only). Latency should stay close to normal and the status 200.
On oci1, `systemctl status user-2003.slice` shows the account's CPU and memory use against the caps.

## When a "must hold" job fails

Read the line starting `FAIL`. Network jobs failing means the firewall (`runner-egress`) is not doing its job or the
job reached the host another way: do not widen a rule to make it pass, find out which path it took. Limit jobs
failing means `config.toml`, `containers.conf` or the slice drifted from the role.
