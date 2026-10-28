#!/usr/bin/env bash
# A throwaway Keycloak for developing and testing tofu/keycloak without touching oci1.
#
#   keycloak-bench.sh up [ENVFILE]   start Keycloak 26.8.1 (same image digest and hostname options
#                                    as the keycloak role), set the master realm's frontendUrl as
#                                    on oci1, create the "tofu" service-account client, and write
#                                    its credentials to ENVFILE (default $XDG_RUNTIME_DIR/kc-bench.env)
#   keycloak-bench.sh down           remove the container
#
# Everything here is a throwaway credential for a container on 127.0.0.1; none of it is a real secret.
set -euo pipefail

name=kc-bench
port=18081
image=quay.io/keycloak/keycloak@sha256:a78d6b79572168cb25886b80a8b5b8d4ed4390743e3eecb810538683e209dd6b
base=http://127.0.0.1:$port
admin_user=bench-admin
admin_pass=bench-throwaway-pw-123  # gitleaks:allow (throwaway password of a local test container)
public=https://auth.jacklouallen.info
admin=https://auth-admin.vaultnet.xyz

token() {
    curl -fsS -d client_id=admin-cli -d "username=$admin_user" -d "password=$admin_pass" \
        -d grant_type=password "$base/realms/master/protocol/openid-connect/token" |
        python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'
}

api() { # api METHOD PATH [JSON]
    local m=$1 p=$2 body=${3:-}
    curl -fsS -X "$m" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        ${body:+-d "$body"} "$base/admin$p"
}

case ${1:-} in
up)
    envfile=${2:-${XDG_RUNTIME_DIR:-/tmp}/kc-bench.env}
    docker rm -f "$name" > /dev/null 2>&1 || true
    docker run -d --name "$name" -p "127.0.0.1:$port:8080" \
        -e KC_BOOTSTRAP_ADMIN_USERNAME=$admin_user -e KC_BOOTSTRAP_ADMIN_PASSWORD=$admin_pass \
        -e KC_HTTP_ENABLED=true -e KC_PROXY_HEADERS=xforwarded \
        -e KC_HOSTNAME=$public -e KC_HOSTNAME_ADMIN=$admin \
        -e KC_LOG_CONSOLE_OUTPUT=json \
        "$image" start-dev > /dev/null
    for _ in $(seq 1 60); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' "$base/realms/master")" = 200 ] && break
        sleep 4
    done
    TOK=$(token)
    # Same state as oci1: the master realm lives on the admin name
    api PUT /realms/master "{\"attributes\":{\"frontendUrl\":\"$admin\"}}" > /dev/null
    TOK=$(token)
    api POST /realms/master/clients '{"clientId":"tofu","enabled":true,"publicClient":false,
        "serviceAccountsEnabled":true,"standardFlowEnabled":false,"directAccessGrantsEnabled":false,
        "clientAuthenticatorType":"client-secret"}' > /dev/null
    cid=$(api GET '/realms/master/clients?clientId=tofu' | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["id"])')
    secret=$(api GET "/realms/master/clients/$cid/client-secret" | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])')
    sa=$(api GET "/realms/master/clients/$cid/service-account-user" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
    role=$(api GET /realms/master/roles/admin)
    api POST "/realms/master/users/$sa/role-mappings/realm" "[$role]" > /dev/null
    umask 077
    {
        echo "export KEYCLOAK_URL=$base"
        echo "export KEYCLOAK_CLIENT_ID=tofu"
        echo "export KEYCLOAK_CLIENT_SECRET=$secret"
    } > "$envfile"
    echo "bench up on $base; credentials in $envfile"
    ;;
down)
    docker rm -f "$name" > /dev/null 2>&1 || true
    echo "bench removed"
    ;;
*)
    echo "usage: $0 up [ENVFILE] | down" >&2
    exit 2
    ;;
esac
