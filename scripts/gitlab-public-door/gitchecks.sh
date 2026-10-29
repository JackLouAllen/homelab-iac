#!/usr/bin/env bash
# git clone and push through the public door, with a control for every refusal. Runs on the host; each git command
# runs inside the test GitLab container, against the door on :443 (resolved to 127.0.0.1) or, as a control, straight
# to GitLab on :8181. Needs TOK (an API token of the test GitLab) and GL_CONTAINER. Exits non-zero if anything differs.
TOKEN=${TOK:?TOK (an API token of the test GitLab) is required}
CT=${GL_CONTAINER:?GL_CONTAINER is required}
fails=0
dg() { docker exec -e GIT_TERMINAL_PROMPT=0 "$CT" git -c http.sslVerify=false -c http.curloptResolve=git.jacklouallen.info:443:127.0.0.1 "$@"; }
direct() { docker exec -e GIT_TERMINAL_PROMPT=0 "$CT" git "$@"; }
exists() { docker exec "$CT" test -d "$1" && echo YES || echo no; }
api_status() { docker exec "$CT" curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $TOKEN" "http://127.0.0.1:8181/api/v4/$1"; }
check() { # check DESCRIPTION WANT GOT
    if [ "$2" = "$3" ]; then echo "ok    $1 ($3)"; else echo "FAIL  $1: wanted $2, got $3"; fails=$((fails + 1)); fi
}
docker exec "$CT" rm -rf /tmp/c1 /tmp/c2 /tmp/c3 /tmp/c4

dg clone -q https://git.jacklouallen.info/root/portfolio-site.git /tmp/c1 > /dev/null 2>&1
check "anonymous clone of the public project through the door" YES "$(exists /tmp/c1)"
check "  it has the files" "LICENSE README.md docs src" "$(docker exec "$CT" ls /tmp/c1 2> /dev/null | tr '\n' ' ' | sed 's/ $//')"

dg clone -q https://git.jacklouallen.info/root/secret-infra.git /tmp/c2 > /dev/null 2>&1
check "anonymous clone of the private project is refused" no "$(exists /tmp/c2)"

direct clone -q "http://root:$TOKEN@127.0.0.1:8181/root/secret-infra.git" /tmp/c3 > /dev/null 2>&1
check "control: the token clones the private project straight from GitLab" YES "$(exists /tmp/c3)"
dg clone -q "https://root:$TOKEN@git.jacklouallen.info/root/secret-infra.git" /tmp/c4 > /dev/null 2>&1
check "the same token through the door is refused (credentials are stripped)" no "$(exists /tmp/c4)"

docker exec "$CT" sh -c "cd /tmp/c1 && git config user.email a@b.c && git config user.name t && echo direct > direct.txt && git add . && git commit -qm direct && git push -q http://root:$TOKEN@127.0.0.1:8181/root/portfolio-site.git HEAD:main" > /dev/null 2>&1
check "control: a push straight to GitLab arrives" 200 "$(api_status 'projects/1/repository/files/direct.txt?ref=main')"
docker exec "$CT" sh -c "cd /tmp/c1 && echo viadoor > viadoor.txt && git add . && git commit -qm viadoor" > /dev/null 2>&1
dg -C /tmp/c1 push -q "https://root:$TOKEN@git.jacklouallen.info/root/portfolio-site.git" HEAD:main > /dev/null 2>&1
check "the same push through the door does not arrive" 404 "$(api_status 'projects/1/repository/files/viadoor.txt?ref=main')"

echo "$fails git check(s) failed"
[ "$fails" = 0 ]
