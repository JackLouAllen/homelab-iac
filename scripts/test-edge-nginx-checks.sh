#!/usr/bin/env bash
# Runs inside the container started by test-edge-nginx.sh.
fail=0
pub=http://127.0.0.1:8008

# check NAME EXPECTED_STATUS EXPECTED_BODY_SUBSTRING curl-args...
check() {
    local name=$1 want=$2 body=$3; shift 3
    local out code
    out=$(curl -s -o /tmp/body -w '%{http_code}' "$@"); code=$out
    if [[ $code == "$want" && $(cat /tmp/body) == *"$body"* ]]; then
        echo "ok    $name ($code)"
    else
        echo "FAIL  $name: got $code '$(head -c 80 /tmp/body)', want $want '$body'"; fail=1
    fi
}

# Allowed
check "login page path"          200 "UPSTREAM /realms/public/protocol/openid-connect/auth" -H "Host: auth.jacklouallen.info" "$pub/realms/public/protocol/openid-connect/auth?x=1"
check "realm metadata"           200 "UPSTREAM /realms/public/.well-known/openid-configuration" -H "Host: auth.jacklouallen.info" "$pub/realms/public/.well-known/openid-configuration"
check "theme assets"             200 "UPSTREAM /resources/abc/login/keycloak.v2/x.css" -H "Host: auth.jacklouallen.info" "$pub/resources/abc/login/keycloak.v2/x.css"
check "robots.txt"               200 "UPSTREAM /robots.txt" -H "Host: auth.jacklouallen.info" "$pub/robots.txt"
check "Host reaches upstream"    200 "host=auth.jacklouallen.info" -H "Host: auth.jacklouallen.info" "$pub/robots.txt"

# Blocked: master realm in every spelling we can think of
for p in /realms/master /realms/master/ /realms/master/protocol/openid-connect/auth \
         /realms/Master /realms/MASTER/account /realms/%6Daster /realms/ma%73ter/x \
         //realms/master /realms//master /realms/./master /resources/../realms/master \
         /realms/x/../master; do
    check "master blocked $p" 404 "" -H "Host: auth.jacklouallen.info" --path-as-is "$pub$p"
done
# A realm that merely starts with "master" is not the master realm
check "unlisted realm mastery refused" 404 "" -H "Host: auth.jacklouallen.info" "$pub/realms/mastery"

# Blocked: the private realms, on every path an attacker would try, including the login endpoints that the
# rate-limit rule once proxied for any realm
for r in homelab Homelab HOMELAB %68omelab; do
    for p in "/realms/$r" "/realms/$r/" "/realms/$r/.well-known/openid-configuration" \
             "/realms/$r/protocol/openid-connect/auth" "/realms/$r/protocol/openid-connect/token" \
             "/realms/$r/login-actions/authenticate" "/realms/$r/account/"; do
        check "homelab blocked $p" 404 "" -H "Host: auth.jacklouallen.info" --path-as-is "$pub$p"
    done
done
check "master token endpoint blocked" 404 "" -H "Host: auth.jacklouallen.info" -d a=b "$pub/realms/master/protocol/openid-connect/token"
check "public realm login endpoint allowed" 200 "UPSTREAM /realms/public/login-actions/authenticate" -H "Host: auth.jacklouallen.info" -d a=b "$pub/realms/public/login-actions/authenticate"

# Blocked: everything else
for p in / /admin /admin/master/console /metrics /health /health/ready /robots.txt/x /realms /resources \
         /js/keycloak.js /auth/realms/home /.git/config; do
    check "closed $p" 404 "" -H "Host: auth.jacklouallen.info" --path-as-is "$pub$p"
done

# Other names and verbs
check "unknown host"             404 "" -H "Host: nope.example" "$pub/realms/home"
check "POST token endpoint"      200 "UPSTREAM /realms/public/protocol/openid-connect/token" -H "Host: auth.jacklouallen.info" -d a=b "$pub/realms/public/protocol/openid-connect/token"

# Rate limit: burst 15 + 1 allowed immediately, then 429. Count outcomes.
codes=$(for i in $(seq 1 40); do curl -s -o /dev/null -w '%{http_code}\n' -H "Host: auth.jacklouallen.info" -d a=b "$pub/realms/public/protocol/openid-connect/token"; done | sort | uniq -c | tr -s ' ' | tr '\n' ';')
echo "info  40 token requests: $codes"
[[ $codes == *"429"* ]] && echo "ok    rate limit returns 429" || { echo "FAIL  rate limit never triggered"; fail=1; }
# The limit is on login paths only: the metadata path is still served while the token path is limited
check "metadata not limited"     200 "UPSTREAM" -H "Host: auth.jacklouallen.info" "$pub/realms/public/.well-known/openid-configuration"
check "theme not limited"        200 "UPSTREAM" -H "Host: auth.jacklouallen.info" "$pub/resources/a/b.css"

# Private admin name: whole site, including the master realm and the admin console
priv() { curl -sk --resolve auth-admin.vaultnet.xyz:443:127.0.0.2 "$@"; }
priv_login() { curl -sk --resolve auth.vaultnet.xyz:443:127.0.0.2 "$@"; }
for p in /admin/master/console/ /realms/master/protocol/openid-connect/auth /metrics; do
    body=$(priv -w ' %{http_code}' "https://auth-admin.vaultnet.xyz$p" | tr -d '\n')
    [[ $body == "UPSTREAM $p host=auth-admin.vaultnet.xyz 200" ]] && echo "ok    private $p" || { echo "FAIL  private $p: $body"; fail=1; }
done
# The new private login name serves everything, the homelab realm included
for p in /realms/homelab/protocol/openid-connect/auth /realms/homelab/account/; do
    body=$(priv_login -w ' %{http_code}' "https://auth.vaultnet.xyz$p" | tr -d '\n')
    [[ $body == "UPSTREAM $p host=auth.vaultnet.xyz 200" ]] && echo "ok    private login name $p" || { echo "FAIL  private login name $p: $body"; fail=1; }
done
# The private name is not served on the public listener
check "admin name on public port" 404 "" -H "Host: auth-admin.vaultnet.xyz" "$pub/admin/master/console/"
check "login name on public port"  404 "" -H "Host: auth.vaultnet.xyz" "$pub/realms/homelab/account/"

exit $fail
