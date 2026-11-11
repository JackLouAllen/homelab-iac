#!/usr/bin/env bash
# Render the portfolio role's nginx.conf with Uptime Kuma set as the status upstream and exercise it in a throwaway
# nginx container: only what a visitor to the status page needs reaches Kuma, and the admin interface, its socket,
# its metrics and every write are refused there. The admin interface is served on a separate tailnet listener, which
# is tested too (here 127.0.0.2 stands in for the Tailscale address). Needs docker, openssl and python3 with jinja2.
# Nothing touches a real host.
#
#   scripts/test-status-nginx.sh          starts the throwaway nginx container itself (needs docker)
#   scripts/test-status-nginx.sh --here   for a CI job whose own container is the nginx image: needs python3 with
#                                         jinja2, openssl and curl in that container. Do not run it on a real host.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 -I - "$repo" "$work" <<'PY'
import sys, jinja2
repo, work = sys.argv[1:3]
env = jinja2.Environment(loader=jinja2.FileSystemLoader(f"{repo}/ansible/roles/portfolio/templates"), keep_trailing_newline=True)
out = env.get_template("nginx.conf.j2").render(
    portfolio_port=8008, portfolio_zone="jacklouallen.info", portfolio_root="/srv/portfolio",
    portfolio_status_name="status.jacklouallen.info", portfolio_status_upstream="127.0.0.1:9000",
    portfolio_admin_enabled=True, portfolio_tailnet_ip="127.0.0.2", portfolio_admin_domain="ovh1.example.ts.net",
    portfolio_admin_cert_file="/etc/nginx/admin.crt", portfolio_admin_key_file="/etc/nginx/admin.key")
# The test container has no access log directory worth keeping, and its crypto policy is not RHEL's
out = out.replace("access_log /var/log/nginx/access.log;", "access_log off;")
out = out.replace("ssl_ciphers PROFILE=SYSTEM;", "ssl_ciphers DEFAULT;")
open(f"{work}/nginx.conf", "w").write(out)
PY

echo 'add_header X-Content-Type-Options nosniff always;' > "$work/security-headers.conf"
# Stand-in for the certificate Tailscale issues
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=ovh1.example.ts.net" \
    -keyout "$work/admin.key" -out "$work/admin.crt" 2>/dev/null
# Dummy upstream: echoes the method and path it was asked for, and whether the client asked to upgrade
cat > "$work/upstream.conf" <<'U'
pid /tmp/up.pid;
events {}
http {
    access_log off;
    server {
        listen 127.0.0.1:9000;
        location / { default_type text/plain; return 200 "UPSTREAM $request_method $uri upgrade=$http_upgrade\n"; }
    }
}
U

cat > "$work/checks.sh" <<'C'
#!/usr/bin/env bash
fail=0
base=http://127.0.0.1:8008
host="Host: status.jacklouallen.info"

# check NAME EXPECTED_STATUS EXPECTED_BODY_SUBSTRING curl-args...
check() {
    local name=$1 want=$2 body=$3; shift 3
    local code
    code=$(curl -s -o /tmp/body -w '%{http_code}' "$@")
    if [[ $code == "$want" && $(cat /tmp/body) == *"$body"* ]]; then
        echo "ok    $name ($code)"
    else
        echo "FAIL  $name: got $code '$(head -c 80 /tmp/body)', want $want '$body'"; fail=1
    fi
}

# What the status page needs
for p in / /api/entry-page /status/status /status/status/rss /api/status-page/status /api/status-page/heartbeat/status \
         /assets/index-abc123.js /upload/logo.png /icon.svg /favicon.ico /manifest.json /robots.txt; do
    check "served $p" 200 "UPSTREAM GET $p" -H "$host" "$base$p"
done
check "query string passes"    200 "UPSTREAM GET /status/status" -H "$host" "$base/status/status?x=1"
check "push by GET"            200 "UPSTREAM GET /api/push/abcdefghijklmnopqrstuvwxyz012345" -H "$host" "$base/api/push/abcdefghijklmnopqrstuvwxyz012345?status=up&msg=OK"
check "push by POST"           200 "UPSTREAM POST /api/push/abcdefghijklmnopqrstuvwxyz012345" -H "$host" -X POST "$base/api/push/abcdefghijklmnopqrstuvwxyz012345"

# The admin interface, its socket and everything else of Kuma's
for p in /dashboard /dashboard/1 /settings /settings/general /manage-status-page /add /edit/1 /maintenance /setup /setup-database \
         /setup-database-info /metrics /socket.io/ /api/badge/1/status /status /status-page /.well-known/change-password \
         /_e2e/take-sqlite-snapshot /api/push/ /api/push/abc/def /api/push/abc.def /serviceWorker.js.map /assets /upload; do
    check "refused $p" 404 "" -H "$host" "$base$p"
done
check "refused socket.io polling" 404 "" -H "$host" "$base/socket.io/?EIO=4&transport=polling"
# Paths that try to climb out of an allowed prefix
for p in /assets/../dashboard /status/../dashboard /api/status-page/../../dashboard /api/push/x/../../dashboard; do
    check "refused traversal $p" 404 "" -H "$host" --path-as-is "$base$p"
done
# nginx answers 400 itself when a path climbs above the root
check "refused traversal above the root" 400 "" -H "$host" --path-as-is "$base/upload/../../etc/passwd"
check "refused encoded traversal" 404 "" -H "$host" --path-as-is "$base/assets/%2e%2e/dashboard"

# Writes to the pages
for m in POST PUT DELETE PATCH; do
    check "$m refused on the page"     403 "" -H "$host" -X $m "$base/status/status"
    check "$m refused on the data"     403 "" -H "$host" -X $m "$base/api/status-page/status"
done
check "PUT refused on push"    403 "" -H "$host" -X PUT "$base/api/push/abcdefghijklmnopqrstuvwxyz012345"

# The other names on this host are untouched
check "apex is not Kuma"       404 "" -H "Host: jacklouallen.info" "$base/dashboard"
check "unknown name"           404 "" -H "Host: other.example" "$base/"

# Guessing push tokens is rate limited, with a status that says so
n=$(for _ in $(seq 1 40); do curl -s -o /dev/null -w '%{http_code}\n' -H "$host" "$base/api/push/abcdefghijklmnopqrstuvwxyz012345"; done | grep -c 429 || true)
if [[ $n -gt 0 ]]; then echo "ok    push rate limit answers 429 ($n of 40)"; else echo "FAIL  push rate limit never answered 429"; fail=1; fi


# --- The admin interface: its own listener on the tailnet address, under the host's tailnet name
admin=ovh1.example.ts.net
adm() { curl -sk --resolve "$admin:443:127.0.0.2" "$@"; }
check_admin() { local name=$1 want=$2 body=$3; shift 3
    local code; code=$(adm -o /tmp/body -w '%{http_code}' "$@")
    if [[ $code == "$want" && $(cat /tmp/body) == *"$body"* ]]; then echo "ok    $name ($code)"
    else echo "FAIL  $name: got $code '$(head -c 80 /tmp/body)', want $want '$body'"; fail=1; fi
}
for p in / /dashboard /dashboard/1 /settings/general /manage-status-page /socket.io/ /metrics /setup; do
    check_admin "admin serves $p" 200 "UPSTREAM GET $p" "https://$admin$p"
done
# Browsers open a WebSocket over HTTP/1.1; HTTP/2 has no Upgrade header
check_admin "admin passes WebSocket upgrades" 200 "upgrade=websocket" --http1.1 -H "Upgrade: websocket" -H "Connection: Upgrade" "https://$admin/socket.io/"
check_admin "admin sends HSTS" 200 "UPSTREAM" -D /tmp/hdr "https://$admin/"
if grep -qi '^strict-transport-security' /tmp/hdr; then echo "ok    admin sends HSTS header"; else echo "FAIL  no HSTS header on the admin name"; fail=1; fi

# A different name on the tailnet address gets no certificate and no page
code=$(curl -sk --resolve other.example:443:127.0.0.2 -o /dev/null -w '%{http_code}' --max-time 5 https://other.example/ || true)
if [[ $code == 000 ]]; then echo "ok    other names on the tailnet address are refused at the handshake"; else echo "FAIL  other name got $code"; fail=1; fi
# The admin interface is not on the loopback address, and the public listener does not know the name
code=$(curl -sk --resolve "$admin:443:127.0.0.1" -o /dev/null -w '%{http_code}' --max-time 5 "https://$admin/" || true)
if [[ $code == 000 ]]; then echo "ok    nothing listens for the admin name on loopback"; else echo "FAIL  loopback got $code"; fail=1; fi
check "public listener refuses the admin name" 404 "" -H "Host: $admin" "$base/dashboard"

exit $fail
C

if [ "${1:-}" = "--here" ]; then
    [ -x /usr/sbin/nginx ] || { echo "--here needs to run inside an nginx container" >&2; exit 2; }
    cp "$work/nginx.conf" /etc/nginx/nginx.conf
    cp "$work/security-headers.conf" /etc/nginx/security-headers.conf
    cp "$work/admin.crt" "$work/admin.key" /etc/nginx/
    nginx -t && nginx -c "$work/upstream.conf" && (nginx -g "daemon off;" 2> /dev/null &) && sleep 1 && bash "$work/checks.sh"
    exit
fi
docker run --rm \
    -v "$work/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$work/security-headers.conf:/etc/nginx/security-headers.conf:ro" \
    -v "$work/admin.crt:/etc/nginx/admin.crt:ro" -v "$work/admin.key:/etc/nginx/admin.key:ro" \
    -v "$work/upstream.conf:/upstream.conf:ro" \
    -v "$work/checks.sh:/checks.sh:ro" \
    nginx:stable bash -c 'nginx -t && nginx -c /upstream.conf && (nginx -g "daemon off;" 2>/dev/null &) && sleep 1 && bash /checks.sh'
