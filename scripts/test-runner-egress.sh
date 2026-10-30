#!/usr/bin/env bash
# Prove what the runner's firewall ruleset allows and blocks, for real: in a throwaway privileged container (its own
# network namespace, so nothing on this machine changes), stand-in addresses for the instance metadata service /
# DNS resolver, the rest of the tailnet, the VCN, loopback services and the internet, then connect as the runner's
# user ID and as a bystander. The ruleset is the role's own template.
#
#   scripts/test-runner-egress.sh
#   WITHOUT_RULES=1 scripts/test-runner-egress.sh     the control: must FAIL (the blocked checks have nothing blocking)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 -I - "$repo" "$work/egress.nft" << 'PY'
import sys, jinja2
repo, out = sys.argv[1:3]
env = jinja2.Environment(loader=jinja2.FileSystemLoader(f"{repo}/ansible/roles/runner/templates"), undefined=jinja2.StrictUndefined, trim_blocks=True)
open(out, "w").write(env.get_template("runner-egress.nft.j2").render(runner_uid=2003, runner_gitlab_address="100.73.97.17", runner_dns_servers=["169.254.169.254"]))
PY

cat > "$work/inside.sh" << 'INSIDE'
set -eu
apk add --no-cache nftables python3 iproute2 > /dev/null
adduser -D -u 2003 runner
adduser -D -u 2999 bystander
# Stand-ins, all local to this container's namespace
for ip in 100.73.97.17 100.64.1.5 169.254.169.254 10.10.1.5 192.168.7.7 203.0.113.50; do ip addr add "$ip/32" dev lo; done
python3 - << 'PY' &
import socket, threading, time
def serve(ip, port):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((ip, port)); s.listen(64)
    while True:
        c, _ = s.accept(); c.close()
for ip, port in [("203.0.113.50", 80), ("100.73.97.17", 443), ("100.73.97.17", 22), ("100.73.97.17", 8181), ("100.64.1.5", 22), ("100.64.1.5", 80),
                 ("169.254.169.254", 53), ("169.254.169.254", 80), ("10.10.1.5", 80), ("192.168.7.7", 80), ("127.0.0.1", 8181), ("127.0.0.1", 9200)]:
    threading.Thread(target=serve, args=(ip, port), daemon=True).start()
time.sleep(3600)
PY
sleep 1
nft -c -f /w/egress.nft
# WITHOUT_RULES=1 is the control: with nothing loaded, the "blocked" checks must fail, or the test proves nothing
if [ "${WITHOUT_RULES:-0}" != 1 ]; then
    nft -f /w/egress.nft
    nft -f /w/egress.nft   # loading it again must be harmless (the unit reloads it)
fi

status=0
try() { # try USER IP PORT -> open|blocked
    if su -s /bin/sh "$1" -c "python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(2); s.connect((sys.argv[1], int(sys.argv[2])))' $2 $3" > /dev/null 2>&1; then echo open; else echo blocked; fi
}
expect() { # expect USER open|blocked IP PORT description
    got=$(try "$1" "$3" "$4")
    if [ "$got" = "$2" ]; then echo "ok    $1 $5 ($3:$4 $got)"; else echo "FAIL  $1 $5 ($3:$4 wanted $2, got $got)"; status=1; fi
}
echo "-- the runner's user ID"
expect runner open    203.0.113.50    80   "reaches the internet"
expect runner open    100.73.97.17    443  "reaches the git door"
expect runner open    169.254.169.254 53   "can ask the DNS resolver"
expect runner blocked 169.254.169.254 80   "cannot reach the instance metadata service"
expect runner blocked 100.73.97.17    22   "cannot reach SSH on this host's tailnet address"
expect runner blocked 100.73.97.17    8181 "cannot reach other ports on this host's tailnet address"
expect runner blocked 100.64.1.5      22   "cannot reach another tailnet device (ssh)"
expect runner blocked 100.64.1.5      80   "cannot reach another tailnet device (web)"
expect runner blocked 10.10.1.5       80   "cannot reach the VCN"
expect runner blocked 192.168.7.7     80   "cannot reach a private network"
expect runner blocked 127.0.0.1       8181 "cannot reach GitLab on loopback"
expect runner blocked 127.0.0.1       9200 "cannot reach the Wazuh indexer on loopback"
echo "-- anyone else is untouched"
for target in "203.0.113.50 80" "100.73.97.17 443" "100.73.97.17 22" "100.64.1.5 22" "169.254.169.254 80" "10.10.1.5 80" "127.0.0.1 8181" "127.0.0.1 9200"; do
    set -- $target; expect bystander open "$1" "$2" "is not affected"
done
echo "-- the drops are counted"
nft list chain inet runner_egress output | grep -c 'counter packets [1-9]' | sed 's/^/rules that dropped something: /'
[ "$status" = 0 ] && echo "EGRESS TEST PASSED" || echo "EGRESS TEST FAILED"
exit "$status"
INSIDE

docker run --rm --privileged -e WITHOUT_RULES="${WITHOUT_RULES:-0}" -v "$work:/w:ro" alpine:3 sh /w/inside.sh
