#!/usr/bin/env bash
# Run on the Wazuh manager (oci1). Feeds the audit events gitlab-audit.service writes (gitlab-audit-samples.log, made
# from real GitLab log lines by test-gitlab-audit.py --write; one label per line in gitlab-audit-samples.labels)
# through the analysis engine and checks the rule that fires for each.
# Usage: sudo ./test-gitlab-wazuh-rules.sh   (the .log and .labels files must sit next to it)
set -euo pipefail
here=$(dirname "$0")
declare -A want=(
    ["failed sign-in"]=100401
    ["admin sign-in"]=100404
    ["rate limited request"]=100405
    ["API: project made public"]=100407
    ["API: token created"]=100410
    ["API: user created"]=100411
    ["web: project made public"]=100408
    ["web: token created"]=100409
    ["exception"]=100412
)
status=0
while IFS= read -r label && IFS= read -r line <&3; do
    got=$(printf '%s\n' "$line" | /var/ossec/bin/wazuh-logtest 2>&1 | awk '/^\*\*Phase 3/ {p=1} p && /^[ \t]*id: \x27[0-9]+\x27/ {gsub(/\x27/, "", $2); id=$2} END {print id}')
    if [ "$got" = "${want[$label]}" ]; then echo "ok    $label -> $got"; else echo "FAIL  $label -> ${got:-no rule}, wanted ${want[$label]}"; status=1; fi
done < "$here/gitlab-audit-samples.labels" 3< "$here/gitlab-audit-samples.log"
echo
[ "$status" = 0 ] && echo "GITLAB RULES BEHAVE" || echo "GITLAB RULES WRONG"
exit "$status"
