"""Visit pages as an anonymous visitor (a fresh browser with no cookies) and record what happens.

usage: probe.py URLS_FILE OUT_JSON      (one path per line; # comments allowed)
Maps git.jacklouallen.info to 127.0.0.1, so the page's own absolute links work against the test server.
"""
import json, re, sys
from collections import defaultdict
from playwright.sync_api import sync_playwright

HOST = "https://git.jacklouallen.info"
paths = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
requests = []        # every request the browser made while viewing the pages
pages = []           # one entry per page visited

def norm(path):      # group requests that differ only by ids and hashes
    path = re.sub(r"\?.*", "", path)
    path = re.sub(r"/[0-9a-f]{20,}", "/:hash", path)
    path = re.sub(r"/\d+(?=/|$)", "/:id", path)
    return path

with sync_playwright() as p:
    browser = p.chromium.launch(args=["--host-resolver-rules=MAP git.jacklouallen.info 127.0.0.1"])
    ctx = browser.new_context(ignore_https_errors=True, viewport={"width": 1280, "height": 900})
    page = ctx.new_page()
    current = {"path": None}

    def on_response(r):
        u = r.url
        if not u.startswith(HOST):
            requests.append({"page": current["path"], "method": r.request.method, "path": u[len(HOST):] or "/",
                             "status": r.status, "type": r.request.resource_type, "external": True})
            return
        requests.append({"page": current["path"], "method": r.request.method, "path": u[len(HOST):],
                         "status": r.status, "type": r.request.resource_type, "external": False})
    page.on("response", on_response)
    errors = []
    page.on("console", lambda m: errors.append(m.text[:160]) if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append("pageerror: " + str(e)[:160]))
    page.on("requestfailed", lambda r: requests.append({"page": current["path"], "method": r.method, "path": r.url[:120],
                                                        "status": "FAILED", "type": r.resource_type, "external": not r.url.startswith(HOST)}))

    for path in paths:
        current["path"] = path
        errors.clear()
        try:
            resp = page.goto(HOST + path, wait_until="networkidle", timeout=45000)
            status = resp.status if resp else None
        except Exception as e:  # downloads and timeouts
            status = "ERR " + str(e)[:80]
        body = ""
        try:
            body = page.inner_text("body")[:4000]
        except Exception:
            pass
        pages.append({"path": path, "status": status, "final": page.url.replace(HOST, "") or "/",
                      "title": page.title()[:70] if status not in (None,) and not str(status).startswith("ERR") else "",
                      "chars": len(body), "text": body[:120].replace("\n", " "), "console_errors": list(errors)})
    browser.close()

json.dump({"pages": pages, "requests": requests}, open(sys.argv[2], "w"), indent=1)

print("== pages")
for pg in pages:
    redirected = f" -> {pg['final']}" if pg["final"] != pg["path"] else ""
    print(f"  {str(pg['status']):>4}  {pg['path']}{redirected}  [{pg['title']}]  text={pg['chars']}  errors={len(pg['console_errors'])}")
print("== distinct requests (method, pattern, statuses, count)")
agg = defaultdict(lambda: [set(), 0, set()])
for r in requests:
    key = (r["method"], norm(r["path"]) if not r["external"] else "EXTERNAL " + r["path"][:70])
    agg[key][0].add(str(r["status"])); agg[key][1] += 1; agg[key][2].add(r["type"])
for (m, pth), (st, n, ty) in sorted(agg.items(), key=lambda kv: (kv[0][1], kv[0][0])):
    if pth.startswith("/assets/") or pth.startswith("/-/webpack/"):
        continue          # static files, summarised below
    print(f"  {m:5} {pth[:90]:90} {','.join(sorted(st)):10} x{n}")
assets = [r for r in requests if r["path"].startswith(("/assets/", "/-/webpack/"))]
print(f"== static assets: {len(assets)} requests, statuses {sorted({str(r['status']) for r in assets})}")
