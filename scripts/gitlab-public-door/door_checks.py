"""Attack and regression checks for GitLab's public, read-only door.

Talks to the door on 127.0.0.1:443 (Host git.jacklouallen.info) and, as a positive control, straight to GitLab
on 127.0.0.1:8181. Run inside the shared network namespace. Exits non-zero if any check fails.
"""
import http.client, json, os, re, ssl, sys, urllib.parse

HOST = "git.jacklouallen.info"
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
TOKEN = os.environ["TOK"]                       # root's token on the test instance
ROOT_PW = os.environ["ROOT_PW"]                  # set on the test instance by the harness
fails = []

def door(method, path, headers=None, body=None):
    c = http.client.HTTPSConnection("127.0.0.1", 443, context=CTX, timeout=60)
    h = {"Host": HOST}; h.update(headers or {})
    c.request(method, path, body=body, headers=h); r = c.getresponse(); data = r.read()
    return r.status, dict((k.lower(), v) for k, v in r.getheaders()), data

def direct(method, path, headers=None, body=None):
    c = http.client.HTTPConnection("127.0.0.1", 8181, timeout=60)
    h = {"Host": HOST, "X-Forwarded-Proto": "https"}; h.update(headers or {})
    c.request(method, path, body=body, headers=h); r = c.getresponse(); data = r.read()
    return r.status, dict((k.lower(), v) for k, v in r.getheaders()), data

def check(name, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + name + (f"   ({detail})" if detail else ""))
    if not ok: fails.append(name)

def expect(method, path, want, **kw):
    s, h, b = door(method, path, **kw)
    check(f"{method} {path[:70]} -> {s}", s in want, f"wanted {sorted(want)}")
    return s, h, b

print("== refused: sign-in, SSO, admin and settings are tailnet only")
for p in ["/users/sign_in", "/users/sign_up", "/users/auth/openid_connect", "/users/password/new", "/users/sign_in/",
          "/oauth/authorize", "/oauth/token", "/admin", "/admin/users", "/-/profile", "/-/user_settings/profile",
          "/-/ide/project/root/portfolio-site", "/-/cable", "/-/metrics", "/-/readiness", "/-/liveness", "/-/health_check",
          "/.well-known/openid-configuration", "/root/portfolio-site/-/network/main"]:
    expect("GET", p, {404})
s, h, b = door("GET", "/users/sign_in"); check("the sign-in refusal explains itself", b"private network" in b)
expect("POST", "/users/auth/openid_connect", {404, 405}); expect("POST", "/users/sign_in", {404, 405})
print("== refused: the same paths in other spellings")
for p in ["/Admin", "/ADMIN/users", "/%61dmin", "//admin", "/./admin", "/users/../admin", "/%75sers/sign_in", "/Users/Sign_In",
          "/oauth//authorize", "/-/%70rofile"]:
    s, h, b = door("GET", p); check(f"GET {p} -> {s} (not served)", s in (404, 400), "wanted 404 or 400")
print("== refused: the REST API outside one project's reads")
for p in ["/api/v4/version", "/api/v4/users", "/api/v4/user", "/api/v4/projects", "/api/v4/groups", "/api/v4/application/settings",
          "/api/v4/metadata", "/api/v4/projects/1/../../users"]:
    expect("GET", p, {404})
print("== refused: anything that is not a read")
for m in ["POST", "PUT", "PATCH", "DELETE", "OPTIONS"]:
    expect(m, "/root/portfolio-site", {405})
expect("POST", "/api/v4/projects/1/issues", {405}); expect("POST", "/root/portfolio-site.git/git-receive-pack", {405})
expect("GET", "/root/portfolio-site.git/info/refs?service=git-receive-pack", {404})
print("== refused: credentials in the URL")
for a in ["private_token", "access_token", "feed_token", "job_token", "rss_token"]:
    expect("GET", f"/api/v4/projects/1/repository/branches?{a}=not-a-real-token", {404})

print("== allowed: what an anonymous visitor needs")
expect("GET", "/explore", {200, 302}); expect("GET", "/root/portfolio-site", {200}); expect("GET", "/users/root/projects", {200})
s, h, b = expect("GET", "/api/v4/projects/1/repository/branches", {200}); check("  and it lists the branches", b"feature" in b)
expect("GET", "/api/v4/projects/1/repository/tags", {200})
expect("GET", "/root/portfolio-site.git/info/refs?service=git-upload-pack", {200})
expect("POST", "/-/collect_events", {204}, body=b"{}")
s, h, b = expect("GET", "/root/portfolio-site/-/archive/main/portfolio-site-main.zip", {200}); check("  and it is a zip", b[:2] == b"PK")
s, h, b = expect("GET", "/root/portfolio-site/-/raw/main/README.md", {200}); check("  and it is the README", b"Portfolio site" in b)
gq = lambda q: json.dumps({"query": q}).encode()
s, h, b = expect("POST", "/api/graphql", {200}, headers={"Content-Type": "application/json"}, body=gq('{ project(fullPath:"root/portfolio-site"){ name } }'))
check("  GraphQL reads the public project", b"portfolio-site" in b)
s, h, b = door("POST", "/api/graphql", headers={"Content-Type": "application/json"}, body=gq('{ project(fullPath:"root/secret-infra"){ name } }'))
check("  GraphQL cannot see the private project", b'"project":null' in b.replace(b" ", b""), b[:90].decode(errors="replace"))
s, h, b = door("POST", "/api/graphql", headers={"Content-Type": "application/json"}, body=gq('mutation { createIssue(input:{projectPath:"root/portfolio-site", title:"hacked"}) { issue { id } errors } }'))
check("  a GraphQL mutation from the public is refused by GitLab", b"hacked" not in b and (b"errors" in b or b"permission" in b), b[:110].decode(errors="replace"))
s, h, b = direct("GET", "/api/v4/projects/1/issues?search=hacked", headers={"PRIVATE-TOKEN": TOKEN}); check("  and no such issue exists", b == b"[]", b[:60].decode())

print("== credentials are stripped: a leaked token or session must not read private data from the internet")
s, h, b = direct("GET", "/api/v4/projects/2/repository/branches", headers={"PRIVATE-TOKEN": TOKEN})
check("control: the token reads the private project straight from GitLab", s == 200 and b"main" in b, str(s))
s, h, b = door("GET", "/api/v4/projects/2/repository/branches", headers={"PRIVATE-TOKEN": TOKEN}); check("PRIVATE-TOKEN header over the door is anonymous", s in (401, 404) and b"main" not in b, str(s))
s, h, b = door("GET", "/api/v4/projects/2/repository/branches", headers={"Authorization": "Bearer " + TOKEN}); check("Authorization: Bearer over the door is anonymous", s in (401, 404) and b"main" not in b, str(s))
import base64
basic = "Basic " + base64.b64encode(f"root:{TOKEN}".encode()).decode()
s, h, b = direct("GET", "/root/secret-infra.git/info/refs?service=git-upload-pack", headers={"Authorization": basic}); check("control: basic auth reads the private repo from GitLab", s == 200, str(s))
s, h, b = door("GET", "/root/secret-infra.git/info/refs?service=git-upload-pack", headers={"Authorization": basic}); check("basic auth over the door is anonymous", s in (401, 404), str(s))
# a real session cookie
s, h, b = direct("GET", "/users/sign_in"); cookie = re.search(r"_gitlab_session=[^;]+", h.get("set-cookie", "")).group(0)
tok = re.search(rb'name="authenticity_token" value="([^"]+)"', b).group(1).decode()
form = urllib.parse.urlencode({"authenticity_token": tok, "user[login]": "root", "user[password]": ROOT_PW}).encode()
s, h, b = direct("POST", "/users/sign_in", headers={"Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"}, body=form)
sess = re.search(r"_gitlab_session=[^;]+", h.get("set-cookie", ""))
check("setup: signed in as root on the test instance", s == 302 and sess is not None, str(s))
if sess:
    s, h, b = direct("GET", "/root/secret-infra", headers={"Cookie": sess.group(0)}); check("control: the session sees the private project from GitLab", s == 200 and b"secret-infra" in b, str(s))
    s, h, b = door("GET", "/root/secret-infra", headers={"Cookie": sess.group(0)}); check("the same session over the door is anonymous", s in (302, 404) and b"README" not in b, str(s))
    s, h, b = door("GET", "/dashboard/projects", headers={"Cookie": sess.group(0)}); check("and it has no dashboard there", s in (302, 404), str(s))

print("== rate limits")
from concurrent.futures import ThreadPoolExecutor
def flood(method, path, n, workers, **kw):
    with ThreadPoolExecutor(workers) as ex:
        return list(ex.map(lambda _: door(method, path, **kw)[0], range(n)))
codes = flood("GET", "/robots.txt", 300, 40)
check("a flood of 300 page requests, 40 at once, is partly limited", 429 in codes and any(c < 400 for c in codes), f"{codes.count(429)} of 300 refused with 429, {sum(c < 400 for c in codes)} served")
codes = flood("POST", "/api/graphql", 200, 40, headers={"Content-Type": "application/json"}, body=gq("{ currentUser { id } }"))
check("a flood of GraphQL calls is partly limited", 429 in codes and any(c < 400 for c in codes), f"{codes.count(429)} of 200 refused with 429, {sum(c < 400 for c in codes)} served")
codes = [door("GET", "/search?search=x")[0] for _ in range(14)]
check("search is limited much harder (archive/search class)", 429 in codes, f"{codes.count(429)} of 14 refused with 429")
codes = [door("GET", "/assets/application.css")[0] for _ in range(60)]
check("static files are not throttled at a normal page's rate", 429 not in codes, f"{codes.count(429)} of 60")

print(f"\n{len(fails)} failed" if fails else "\nall checks passed")
sys.exit(1 if fails else 0)
