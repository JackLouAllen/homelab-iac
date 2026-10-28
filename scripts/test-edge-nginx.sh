#!/usr/bin/env bash
# Render the edge role's nginx.conf with upstreams set and exercise it in a throwaway nginx
# container: the auth allow-list, the master-realm block, the rate limit and the private name.
# Needs docker, openssl, python3 with jinja2 and yaml. Nothing touches a real host.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Self-signed wildcard stand-in at the path the template expects
mkdir -p "$work/le/vaultnet.xyz"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=*.vaultnet.xyz" \
    -keyout "$work/le/vaultnet.xyz/privkey.pem" -out "$work/le/vaultnet.xyz/fullchain.pem" 2>/dev/null

# The container's own loopback stands in for the tailnet address; both auth sites get the dummy upstream
python3 -I - "$repo" "$work" <<'PY'
import json, subprocess, sys, yaml
repo, work = sys.argv[1:3]
defaults = yaml.safe_load(open(f"{repo}/ansible/roles/edge/defaults/main.yml"))
# One public realm ("public") is listed so its paths can be tested; homelab and master must stay refused
sites = [dict(s, upstream="127.0.0.1:9000", allow_realms=["public"]) for s in defaults["edge_public_sites"] if s["host"].startswith("auth.")]
priv = [dict(s, upstream="127.0.0.1:9000") for s in defaults["edge_private_sites"] if s["host"].startswith("auth")]
out = subprocess.run(
    ["python3", "-I", f"{repo}/scripts/render-edge-nginx.py",
     "--set", 'edge_tailnet_ip="127.0.0.2"',
     "--set", "edge_public_sites=" + json.dumps(sites),
     "--set", "edge_private_sites=" + json.dumps(priv)],
    check=True, capture_output=True, text=True).stdout
# PROFILE=SYSTEM is RHEL's crypto policy; the Debian test image does not know it
out = out.replace("ssl_ciphers PROFILE=SYSTEM;", "ssl_ciphers DEFAULT;")
out = out.replace("access_log /var/log/nginx/access.log;", "access_log off;")
open(f"{work}/nginx.conf", "w").write(out)
PY

cat > "$work/security-headers.conf" <<'H'
add_header X-Content-Type-Options nosniff always;
H
# Dummy upstream: echoes the path it was asked for and the Host it saw
cat > "$work/upstream.conf" <<'U'
pid /tmp/up.pid;
events {}
http {
    access_log off;
    server {
        listen 127.0.0.1:9000;
        location / { default_type text/plain; return 200 "UPSTREAM $uri host=$host\n"; }
    }
}
U

cp "$repo/scripts/test-edge-nginx-checks.sh" "$work/checks.sh"
docker run --rm \
    -v "$work/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$work/security-headers.conf:/etc/nginx/security-headers.conf:ro" \
    -v "$work/le:/etc/letsencrypt/live:ro" \
    -v "$work/upstream.conf:/upstream.conf:ro" \
    -v "$work/checks.sh:/checks.sh:ro" \
    nginx:stable bash -c 'nginx -t && nginx -c /upstream.conf && (nginx -g "daemon off;" 2>/dev/null &) && sleep 1 && bash /checks.sh'
