#!/usr/bin/env bash
# Check the runner role's systemd units for ordering cycles against a RHEL-compatible image's real units.
# A cycle makes systemd delete a start job at boot without any failed unit (GitLab's audit service had one).
# The control builds that exact fault (a unit wanted by multi-user.target and ordered after a unit that is itself
# ordered after multi-user.target, like gitlab-runsvdir.service) and the check must report it.
#
#   scripts/test-runner-units.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 -I - "$repo" "$work" << 'PY'
import sys, pathlib, yaml, jinja2
repo, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
role = repo / "ansible/roles/runner"
v = yaml.safe_load((role / "defaults/main.yml").read_text())
v.update(runner_gitlab_address="100.73.97.17")
env = jinja2.Environment(loader=jinja2.FileSystemLoader(role / "templates"), undefined=jinja2.StrictUndefined, trim_blocks=True)
res = lambda x: env.from_string(x).render(**v) if isinstance(x, str) and "{{" in x else x
for _ in range(3):
    v = {k: res(x) for k, x in v.items()}
for name in ("runner-egress.service", "user-manager.conf", "user-slice-limits.conf"):
    (work / name).write_text(env.get_template(name + ".j2").render(**v))
PY

cat > "$work/inside.sh" << 'INSIDE'
set -eu
dnf -q -y install systemd nftables > /dev/null 2>&1
d=/etc/systemd/system
mkdir -p $d/user@2003.service.d $d/user-2003.slice.d
cp /w/runner-egress.service $d/runner-egress.service
cp /w/user-manager.conf $d/user@2003.service.d/runner-egress.conf
cp /w/user-slice-limits.conf $d/user-2003.slice.d/limits.conf
ln -s $d/runner-egress.service $d/multi-user.target.wants/runner-egress.service 2> /dev/null || { mkdir -p $d/multi-user.target.wants; ln -s $d/runner-egress.service $d/multi-user.target.wants/runner-egress.service; }

echo "-- the role's units"
out=$(systemd-analyze verify multi-user.target user@2003.service runner-egress.service 2>&1 || true)
echo "$out" | grep -iE "cycle|ordering" && { echo "FAIL  ordering cycle in the role's units"; exit 1; } || echo "ok    no ordering cycle"
# anything else the verifier says about our own units (it also grumbles about the container)
echo "$out" | grep -E "runner-egress|user-2003" | grep -v "Failed to create\|Cannot add dependency\|unit-name\|ExecStart.*nft" || echo "ok    nothing else to report about them"

echo "-- the control: the fault GitLab's audit service had"
cat > $d/fake-vendor.service << 'U'
[Unit]
Description=stand-in for a vendor unit ordered after multi-user.target
After=multi-user.target
[Service]
ExecStart=/bin/true
[Install]
WantedBy=basic.target
U
cat > $d/faulty.service << 'U'
[Unit]
Description=wanted by multi-user.target, ordered after the vendor unit
After=fake-vendor.service
Requires=fake-vendor.service
[Service]
ExecStart=/bin/true
[Install]
WantedBy=multi-user.target
U
ln -s $d/faulty.service $d/multi-user.target.wants/faulty.service
ln -s $d/fake-vendor.service $d/multi-user.target.wants/fake-vendor.service 2> /dev/null || true
control=$(systemd-analyze verify multi-user.target faulty.service 2>&1 || true)
if echo "$control" | grep -qi "cycle"; then echo "ok    the check does report a cycle when there is one"; else echo "FAIL  the check did not notice the control fault"; echo "$control" | head -5; exit 1; fi
INSIDE

docker run --rm -v "$work:/w:ro" almalinux:10 bash /w/inside.sh
