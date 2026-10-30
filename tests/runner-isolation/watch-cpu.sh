#!/usr/bin/env bash
# Run on oci1 while the stress-cpu job runs. Every 3 seconds: how many CPUs the runner account is using (from its
# slice's CPU time and the clock), and how fast GitLab answers on loopback. The cap is 2 CPUs: the first column must
# stay at or just under 2.0 while the busy loops run, and GitLab's time must stay close to normal.
#
#   ./watch-cpu.sh            (no sudo needed)
set -euo pipefail
slice=user-2003.slice
cpu_ns() { systemctl show "$slice" -p CPUUsageNSec --value; }
prev_ns=$(cpu_ns); prev_t=$(date +%s.%N)
printf '%-9s %-12s %s\n' time "runner CPUs" "GitLab readiness (loopback)"
for _ in $(seq 1 30); do
    sleep 3
    ns=$(cpu_ns); t=$(date +%s.%N)
    cpus=$(awk -v a="$prev_ns" -v b="$ns" -v s="$prev_t" -v e="$t" 'BEGIN { printf "%.2f", (b - a) / 1e9 / (e - s) }')
    ready=$(curl -s -o /dev/null -m 5 -w '%{time_total}s %{http_code}' http://127.0.0.1:8181/-/readiness || echo "no answer")
    printf '%-9s %-12s %s\n' "$(date +%T)" "$cpus" "$ready"
    prev_ns=$ns; prev_t=$t
done
