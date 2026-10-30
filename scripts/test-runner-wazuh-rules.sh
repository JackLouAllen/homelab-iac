#!/usr/bin/env bash
# Run on the Wazuh manager (oci1). Feeds real firewall log lines from the CI runner (runner-wazuh-samples.log) through
# the analysis engine and checks they hit rule 100420.
# Usage: sudo ./test-runner-wazuh-rules.sh   (runner-wazuh-samples.log must sit next to it)
set -euo pipefail
here=$(dirname "$0")
status=0
n=0
while IFS= read -r line; do
    n=$((n + 1))
    got=$(printf '%s\n' "$line" | /var/ossec/bin/wazuh-logtest 2>&1 | awk '/^\*\*Phase 3/ {p=1} p && /^[ \t]*id: \x27[0-9]+\x27/ {gsub(/\x27/, "", $2); id=$2} END {print id}')
    if [ "$got" = 100420 ]; then echo "ok    sample $n -> $got"; else echo "FAIL  sample $n -> ${got:-no rule}, wanted 100420"; status=1; fi
done < "$here/runner-wazuh-samples.log"
# an ordinary kernel line must not alert
quiet=$(printf '%s\n' 'Oct 30 08:30:00 oci1 kernel: IPv6: ADDRCONF(NETDEV_CHANGE): enp0s6: link becomes ready' | /var/ossec/bin/wazuh-logtest 2>&1 | awk '/^\*\*Phase 3/ {p=1} p && /^[ \t]*id: \x27[0-9]+\x27/ {gsub(/\x27/, "", $2); id=$2} END {print id}')
if [ "$quiet" = 100420 ]; then echo "FAIL  an ordinary kernel line alerts"; status=1; else echo "ok    an ordinary kernel line does not alert (${quiet:-no rule})"; fi
echo
[ "$status" = 0 ] && echo "RUNNER RULES BEHAVE" || echo "RUNNER RULES WRONG"
exit "$status"
