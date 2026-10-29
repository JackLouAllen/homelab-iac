#!/usr/bin/env bash
# Does GitLab's public, read-only door still do its job? Builds a throwaway GitLab of the pinned version from the
# role's own gitlab.rb and settings, seeds it, puts nginx in front of it rendered from the edge role's own templates,
# and runs three things against that door:
#   door_checks.py   attacks and regressions (refusals, credential stripping with controls, rate limits)
#   gitchecks.sh     git clone and push, with controls
#   probe.py + walk_check.py   a headless browser walking 44 pages as an anonymous visitor
#
#   scripts/gitlab-public-door/run.sh [GITLAB_VERSION]      (default: gitlab_version in the gitlab role)
#
# Needs docker, python3 with jinja2 and yaml, openssl; about 4 GB of memory and 10 to 15 minutes. Touches no real host.
# Run it after every GitLab upgrade and after any change to nginx-gitlab-readonly-*.conf.j2.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
role=$repo/ansible/roles/gitlab
templates=$repo/ansible/roles/edge/templates
version=${1:-$(sed -n 's/^gitlab_version: \([0-9.]*\)-ce.*/\1/p' "$role/defaults/main.yml")}
image=gitlab/gitlab-ce:${version}-ce.0
browser=mcr.microsoft.com/playwright/python:v1.56.0-noble
work=$(mktemp -d)
ns=gldoor-ns gl=gldoor-gitlab nx=gldoor-nginx
cleanup() { docker rm -f "$nx" "$gl" "$ns" > /dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
cleanup; mkdir -p "$work"; trap cleanup EXIT

TOK=glpat-$(openssl rand -base64 40 | tr -dc 'A-Za-z0-9' | head -c 26)
ROOT_PW=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 26)
export TOK ROOT_PW
echo "GitLab $version"

# 1. Render what the real hosts would run, from the repository's own templates
python3 -I - "$repo" "$work" << 'PY'
import json, pathlib, sys, yaml, jinja2
repo, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
role = repo / "ansible/roles/gitlab"
v = yaml.safe_load((role / "defaults/main.yml").read_text())
v["gitlab_oidc_enabled"] = False          # no Keycloak in this test
env = jinja2.Environment(loader=jinja2.FileSystemLoader(role / "templates"), undefined=jinja2.StrictUndefined, trim_blocks=True)
res = lambda x: env.from_string(x).render(**v) if isinstance(x, str) and "{{" in x else x
for _ in range(3):
    v = {k: (res(x) if not isinstance(x, dict) else {a: res(b) for a, b in x.items()}) for k, x in v.items()}
(work / "gitlab.rb").write_text(env.get_template("gitlab.rb.j2").render(**v))
(work / "settings.json").write_text(json.dumps(v["gitlab_application_settings"]))
t = jinja2.Environment(loader=jinja2.FileSystemLoader(repo / "ansible/roles/edge/templates"), undefined=jinja2.StrictUndefined, trim_blocks=True)
site = {"upstream": "127.0.0.1:8181", "host": "git.jacklouallen.info"}
http = t.get_template("nginx-gitlab-readonly-http.conf.j2").render(site=site)
server = t.get_template("nginx-gitlab-readonly-server.conf.j2").render(site=site)
(work / "nginx.conf").write_text(f"""events {{}}
http {{
    access_log /var/log/nginx/access.log;
{http}
    server {{
        listen 443 ssl;
        server_name git.jacklouallen.info;
        ssl_certificate /certs/cert.pem;
        ssl_certificate_key /certs/key.pem;
{server}
    }}
}}
""")
PY
mkdir -p "$work/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=git.jacklouallen.info" -addext "subjectAltName=DNS:git.jacklouallen.info" \
    -keyout "$work/certs/key.pem" -out "$work/certs/cert.pem" 2> /dev/null
docker run --rm -v "$work/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$work/certs:/certs:ro" nginx:stable nginx -t 2>&1 | tail -1

# 2. One network namespace for GitLab, nginx and the browser: they behave as one host
docker run -d --name "$ns" alpine sleep infinity > /dev/null
docker run -d --name "$gl" --network container:"$ns" --shm-size 256m -e GITLAB_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 26)" \
    -v "$work/gitlab.rb:/etc/gitlab/gitlab.rb" "$image" > /dev/null
echo "waiting for GitLab to configure itself (about 3 minutes)..."
for _ in $(seq 1 200); do
    logs=$(docker logs "$gl" 2>&1 || true)
    grep -q "gitlab Reconfigured!" <<< "$logs" && break
    grep -qiE "Chef Infra Client failed|FATAL:" <<< "$logs" && { echo "GitLab failed to configure" >&2; exit 2; }
    sleep 3
done
for _ in $(seq 1 120); do
    [ "$(docker exec "$gl" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8181/-/readiness 2> /dev/null || true)" = 200 ] && break
    sleep 5
done

# 3. The role's own settings script, then a token, a root password and the seed data
docker cp "$role/files/apply_settings.rb" "$gl:/tmp/apply_settings.rb"
echo "application settings: $(docker exec -e GITLAB_SETTINGS="$(cat "$work/settings.json")" "$gl" gitlab-rails runner /tmp/apply_settings.rb 2>&1 | tail -1)"
docker exec -e TOK="$TOK" -e ROOT_PW="$ROOT_PW" "$gl" gitlab-rails runner "
u = User.find_by_username('root'); u.password = ENV['ROOT_PW']; u.password_confirmation = ENV['ROOT_PW']; u.save!
t = u.personal_access_tokens.build(name: 'door-test', scopes: [:api], expires_at: 30.days.from_now, organization_id: u.organization_id)
t.set_token(ENV['TOK']); t.save!" > /dev/null 2>&1
pw() { docker run --rm --init --ipc=host --network container:"$ns" -v "$here:/w:ro" -v "$work:/out" -e TOK -e ROOT_PW -e GL_CONTAINER="$gl" "$browser" "$@"; }
pw python3 /w/seed.py | sed 's/^/  seed: /'
sha=$(docker exec "$gl" curl -s -H "PRIVATE-TOKEN: $TOK" http://127.0.0.1:8181/api/v4/projects/1/repository/commits/main | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["id"])')
sed "s/__SHA__/$sha/" "$here/urls.txt" > "$work/urls.txt"

# 4. The door
docker run -d --name "$nx" --network container:"$ns" -v "$work/nginx.conf:/etc/nginx/nginx.conf:ro" -v "$work/certs:/certs:ro" nginx:stable > /dev/null
sleep 2
status=0
# The order matters. The attack suite floods pages, GraphQL and search on purpose, and GitLab keeps its own
# per-address limits (for anonymous search, for example), which nginx restarting does not clear. So the suites
# that behave like a visitor run first and the flooding one runs last; nginx restarts in between to clear its counters.
echo; echo "######## a browser walking 44 pages as an anonymous visitor (probe.py, walk_check.py)"
pw sh -c 'pip install -q playwright==1.56.0 2>&1 | grep -v -i -E "notice|warning"; python3 /w/probe.py /out/urls.txt /out/walk.json > /out/probe.log 2>&1; tail -n 1 /out/probe.log'
python3 -I "$here/walk_check.py" "$work/walk.json" || status=1
docker restart "$nx" > /dev/null; sleep 2
echo; echo "######## git clone and push (gitchecks.sh)"
GL_CONTAINER=$gl bash "$here/gitchecks.sh" || status=1
docker restart "$nx" > /dev/null; sleep 2
echo; echo "######## attacks and regressions (door_checks.py)"
pw python3 /w/door_checks.py > "$work/door.log" 2>&1 || status=1
grep -v '^ok' "$work/door.log" || true
echo "($(grep -c '^ok' "$work/door.log") checks passed)"
echo
[ "$status" = 0 ] && echo "PUBLIC DOOR TEST PASSED" || echo "PUBLIC DOOR TEST FAILED"
exit "$status"
