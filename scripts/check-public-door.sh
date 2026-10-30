#!/usr/bin/env bash
# Look at GitLab's public door the way a stranger does: through Cloudflare, ignoring this machine's hosts file (which
# sends the name to the tailnet door). Read-only requests to the public name; no credentials.
#
#   scripts/check-public-door.sh [HOST] [PUBLIC_PROJECT_PATH]      e.g. check-public-door.sh git.jacklouallen.info jackl/door-test
#
# With a project path, it also runs "git ls-remote" and checks the project is visible and a private one is not.
set -uo pipefail
host=${1:-git.jacklouallen.info}
project=${2:-}
fails=0

# Cloudflare's address for the name, from a public resolver (DNS over HTTPS), not from /etc/hosts
ip=$(curl -s -m 15 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$host&type=A" |
    python3 -I -c 'import sys,json; print(next(a["data"] for a in json.load(sys.stdin).get("Answer", []) if a["type"] == 1))' 2> /dev/null)
[ -n "$ip" ] || { echo "could not resolve $host through a public resolver" >&2; exit 2; }
echo "$host is $ip in public DNS (what a visitor reaches)"
c() { curl -s -m 30 --resolve "$host:443:$ip" "$@"; }
check() { if [ "$2" = "$3" ]; then echo "ok    $1 ($3)"; else echo "FAIL  $1: wanted $2, got $3"; fails=$((fails + 1)); fi; }
status() { c -o /dev/null -w '%{http_code}' "$@"; }

check "arrives through Cloudflare" cloudflare "$(c -I "https://$host/explore" | tr -d '\r' | awk -F': ' 'tolower($1)=="server"{print tolower($2)}')"
check "Cloudflare is not challenging this client" none "$(c -I "https://$host/explore" | tr -d '\r' | grep -qi '^cf-mitigated' && echo challenged || echo none)"
s=$(status "https://$host/explore"); check "the public project list loads" 200 "$s"
check "/ sends a visitor to the public list" 302 "$(status "https://$host/")"
for p in /users/sign_in /users/sign_up /users/auth/openid_connect /admin /oauth/authorize /-/profile /-/ide /-/metrics /-/readiness /api/v4/users /api/v4/version /api/v4/projects /.well-known/openid-configuration; do
    check "GET $p is refused" 404 "$(status "https://$host$p")"
done
check "the refusal explains itself" 1 "$(c "https://$host/users/sign_in" | grep -c 'private network')"
check "POST is refused" 405 "$(status -X POST "https://$host/explore")"
check "tokens in the URL are refused" 404 "$(status "https://$host/api/v4/projects/1/repository/branches?private_token=x")"
check "GraphQL answers" 200 "$(status -X POST -H 'Content-Type: application/json' -d '{"query":"{ metadata { version } }"}' "https://$host/api/graphql")"
if [ -n "$project" ]; then
    check "the public project page loads" 200 "$(status "https://$host/$project")"
    git -c http.curloptResolve="$host:443:$ip" ls-remote "https://$host/$project.git" > /dev/null 2>&1 && r=works || r=failed
    check "git ls-remote of the public project" works "$r"
    check "a made-up private project is not found" 302 "$(status "https://$host/$project-does-not-exist")"
fi
echo; [ "$fails" = 0 ] && echo "PUBLIC DOOR LOOKS RIGHT FROM OUTSIDE" || echo "$fails check(s) failed"
[ "$fails" = 0 ]
