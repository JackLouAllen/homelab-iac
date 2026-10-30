#!/usr/bin/env bash
# Run on the Wazuh manager (oci1). Feeds real GitLab log lines (gitlab-wazuh-samples.log, with one label per line in
# gitlab-wazuh-samples.labels) through the analysis engine and checks the rule that fires for each.
# Usage: sudo ./test-gitlab-wazuh-rules.sh   (the .log and .labels files must sit next to it)
set -euo pipefail
here=$(dirname "$0")
declare -A want=(
    ["failed sign-in"]=100401
    ["admin sign-in"]=100404
    ["rate limited request"]=100405
    ["API: project made public"]=100407
    ["API: project made private (no alert)"]=100400
    ["API: token created"]=100410
    ["API: user created"]=100411
    ["web: project made public"]=100408
    ["web: project made private (no alert)"]=100400
    ["web: token created"]=100409
    ["web: token form rejected (no alert)"]=100400
    ["exception"]=100412
    ["an ordinary page view (no alert)"]=100400
)
status=0
while IFS= read -r label && IFS= read -r line <&3; do
    got=$(printf '%s\n' "$line" | /var/ossec/bin/wazuh-logtest 2>&1 | awk '/^\*\*Phase 3/ {p=1} p && /id: / {gsub(/\x27/, "", $2); id=$2} END {print id}')
    if [ "$got" = "${want[$label]}" ]; then echo "ok    $label -> $got"; else echo "FAIL  $label -> ${got:-no rule}, wanted ${want[$label]}"; status=1; fi
done < "$here/gitlab-wazuh-samples.labels" 3< "$here/gitlab-wazuh-samples.log"
echo
[ "$status" = 0 ] && echo "GITLAB RULES BEHAVE" || echo "GITLAB RULES WRONG"
exit "$status"
