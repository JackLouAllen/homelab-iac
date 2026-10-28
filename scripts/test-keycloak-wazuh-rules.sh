#!/usr/bin/env bash
# Run on the Wazuh manager (oci1). Feeds sample Keycloak journal lines through the analysis engine
# and prints which rule each one hits. Expected, in the order of the sample file:
#   1 master sign-in                  -> 100303
#   2 master failed sign-in           -> 100304
#   3 public-realm failed sign-in     -> 100301
#   4 admin action                    -> 100305
#   5 unrelated Keycloak line         -> no rule
# Usage: sudo ./test-keycloak-wazuh-rules.sh   (keycloak-wazuh-samples.log must sit next to it)
set -euo pipefail
samples=$(dirname "$0")/keycloak-wazuh-samples.log
/var/ossec/bin/wazuh-logtest < "$samples" 2>&1 | awk '
    function close_event() { if (n > 0 && !hit) print "no rule" }
    /^\*\*Phase 1/               { close_event(); n++; hit = 0; printf "event %d: ", n }
    /^\*\*Phase 3/               { phase3 = 1; next }
    /^\*\*Alert to be generated/ { phase3 = 0; next }
    /^\*\*Phase/                 { phase3 = 0 }
    phase3 && /id: /             { id = $2; gsub(/\x27/, "", id) }
    phase3 && /level: /          { lvl = $2; gsub(/\x27/, "", lvl) }
    phase3 && /description: /    { sub(/^[ \t]*description: /, ""); printf "rule %s (level %s) %s\n", id, lvl, $0; hit = 1 }
    END                          { close_event() }'
