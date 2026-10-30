#!/usr/bin/env bash
# Rehearse a GitLab upgrade: build a throwaway GitLab of the OLD version with content in it, stop it, start the NEW
# version on the same data (which is what the package upgrade does to the database: migrations run), and check that
# nothing was lost and the new version works.
#
#   scripts/gitlab-upgrade-test.sh 19.5.1 19.5.3
#
# Uses the role's own gitlab.rb (single sign-on off: there is no Keycloak here). Needs docker, python3 with jinja2
# and yaml, openssl; about 3 GB of memory and 10 to 15 minutes. Touches no real host. Run it before changing
# gitlab_version in the role; then take a backup on the host and apply.
set -euo pipefail

from=${1:?usage: gitlab-upgrade-test.sh OLD_VERSION NEW_VERSION}
to=${2:?usage: gitlab-upgrade-test.sh OLD_VERSION NEW_VERSION}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
role=$repo/ansible/roles/gitlab
browser=mcr.microsoft.com/playwright/python:v1.56.0-noble
work=$(mktemp -d)
ns=gl-upgrade-ns gl=gl-upgrade
# The data directories are written by root inside the container: remove them the same way
cleanup() {
    docker rm -f "$gl" "$ns" > /dev/null 2>&1 || true
    docker run --rm -v "$work:/w" alpine sh -c 'rm -rf /w/*' > /dev/null 2>&1 || true
    rmdir "$work" 2> /dev/null || true
}
trap cleanup EXIT
mkdir -p "$work/etc" "$work/data" "$work/log"

TOK=glpat-$(openssl rand -base64 40 | tr -dc 'A-Za-z0-9' | head -c 26)
export TOK

python3 -I - "$repo" "$work/etc/gitlab.rb" << 'PY'
import pathlib, sys, yaml, jinja2
repo, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
role = repo / "ansible/roles/gitlab"
v = yaml.safe_load((role / "defaults/main.yml").read_text())
v["gitlab_oidc_enabled"] = False
env = jinja2.Environment(loader=jinja2.FileSystemLoader(role / "templates"), undefined=jinja2.StrictUndefined, trim_blocks=True)
res = lambda x: env.from_string(x).render(**v) if isinstance(x, str) and "{{" in x else x
for _ in range(3):
    v = {k: (res(x) if not isinstance(x, dict) else {a: res(b) for a, b in x.items()}) for k, x in v.items()}
out.write_text(env.get_template("gitlab.rb.j2").render(**v))
PY

docker run -d --name "$ns" alpine sleep infinity > /dev/null
start() { # start VERSION
    docker rm -f "$gl" > /dev/null 2>&1 || true
    docker run -d --name "$gl" --network container:"$ns" --shm-size 256m \
        -e GITLAB_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 26)" \
        -v "$work/etc:/etc/gitlab" -v "$work/data:/var/opt/gitlab" -v "$work/log:/var/log/gitlab" \
        "gitlab/gitlab-ce:$1-ce.0" > /dev/null
    echo "waiting for GitLab $1 to configure itself (migrations can take several minutes)..."
    for _ in $(seq 1 300); do
        logs=$(docker logs "$gl" 2>&1 || true)
        grep -q "gitlab Reconfigured!" <<< "$logs" && break
        grep -qiE "Chef Infra Client failed|FATAL:" <<< "$logs" && { echo "GitLab $1 failed to configure:"; grep -iE "error|fatal" <<< "$logs" | tail -5; exit 2; }
        sleep 3
    done
    for _ in $(seq 1 120); do
        [ "$(docker exec "$gl" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8181/-/readiness 2> /dev/null || true)" = 200 ] && return 0
        sleep 5
    done
    echo "GitLab $1 never became ready" >&2; exit 2
}
api() { docker exec "$gl" curl -s -H "PRIVATE-TOKEN: $TOK" "http://127.0.0.1:8181/api/v4/$1"; }
version() { docker exec "$gl" head -1 /opt/gitlab/version-manifest.txt; }
snapshot() { # one line of facts that an upgrade must not change
    python3 -I - "$(api 'projects?per_page=50&order_by=id&sort=asc')" "$(api 'projects/1/repository/commits/main')" \
        "$(api 'projects/1/issues')" "$(api 'projects/1/merge_requests')" "$(api 'projects/1/repository/tags')" << 'PY'
import json, sys
projects, commit, issues, mrs, tags = (json.loads(a) for a in sys.argv[1:6])
print(json.dumps({"projects": [p["path_with_namespace"] for p in projects], "main commit": commit["id"][:12],
                  "issues": [i["title"] for i in issues], "merge requests": [m["title"] for m in mrs],
                  "tags": [t["name"] for t in tags]}, sort_keys=True))
PY
}

start "$from"
echo "old: $(version)"
docker exec -e TOK="$TOK" "$gl" gitlab-rails runner "
u = User.find_by_username('root')
t = u.personal_access_tokens.build(name: 'upgrade-test', scopes: [:api], expires_at: 30.days.from_now, organization_id: u.organization_id)
t.set_token(ENV['TOK']); t.save!" > /dev/null 2>&1
docker run --rm --network container:"$ns" -v "$repo/scripts/gitlab-public-door:/w:ro" -e TOK "$browser" python3 /w/seed.py | sed 's/^/  seed: /'
before=$(snapshot)
echo "before the upgrade: $before"

echo "stopping GitLab $from and starting $to on the same data..."
docker stop -t 120 "$gl" > /dev/null
start "$to"
echo "new: $(version)"
after=$(snapshot)
echo "after the upgrade:  $after"

status=0
check() { if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1"; status=1; fi; }
check "the version changed to $to" "gitlab-ce $to" "$(version | awk '{print $1" "$2}')"
check "projects, the main commit, issues, merge requests and tags are exactly as before" "$before" "$after"
check "the old API token still works" 200 "$(docker exec "$gl" curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $TOK" http://127.0.0.1:8181/api/v4/user)"
check "an anonymous visitor still sees the public project" 200 "$(docker exec "$gl" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8181/root/portfolio-site)"
check "and not the private one" 302 "$(docker exec "$gl" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8181/root/secret-infra)"
docker exec "$gl" rm -rf /tmp/clone
docker exec -e GIT_TERMINAL_PROMPT=0 "$gl" git clone -q http://127.0.0.1:8181/root/portfolio-site.git /tmp/clone > /dev/null 2>&1 || true
check "an anonymous clone still works" "LICENSE README.md docs src" "$(docker exec "$gl" ls /tmp/clone 2> /dev/null | tr '\n' ' ' | sed 's/ $//')"
failures=$(docker exec "$gl" gitlab-rake gitlab:doctor:secrets 2>&1 | grep "failures: " | grep -vc "failures: 0" || true)
check "every encrypted value still decrypts (gitlab:doctor:secrets)" 0 "$failures"
echo
[ "$status" = 0 ] && echo "UPGRADE TEST PASSED ($from to $to)" || echo "UPGRADE TEST FAILED"
exit "$status"
