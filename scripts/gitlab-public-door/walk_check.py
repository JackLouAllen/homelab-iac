"""Judge the browser walk made through the public door (probe.py's JSON output).

The door may refuse exactly four of the walked pages, on purpose. Everything else must load with content, nothing
may be requested from another site, and the only console errors allowed are the three kinds that are understood.
"""
import json
import sys

walk = json.load(open(sys.argv[1]))
REFUSED_ON_PURPOSE = {
    "/users/sign_in",                              # sign-in is tailnet only
    "/root/secret-infra",                          # a private project: anonymous visitors end up at the refused sign-in
    "/root/secret-infra/-/blob/main/README.md",
    "/root/portfolio-site/-/network/main",         # loads avatars from a third party even with Gravatar off
}
fails = []

for page in walk["pages"]:
    path = page["path"]
    refused = path in REFUSED_ON_PURPOSE
    want = 404 if refused else 200
    if page["status"] != want:
        fails.append(f"{path}: HTTP {page['status']}, wanted {want}; the page says: {page.get('text', '')[:100]!r}")
    if not refused and page["chars"] < 100:
        fails.append(f"{path}: loaded but nearly empty ({page['chars']} characters)")
    for error in page["console_errors"]:
        understood = (
            "/-/cable" in error                                                    # live-update WebSocket, refused on purpose
            or (refused and "Failed to load resource" in error)                    # the refused page itself
            or (path.startswith("/search") and "429" in error)                     # GitLab's own search throttle
        )
        if not understood:
            fails.append(f"{path}: unexpected console error: {error[:100]}")

other_sites = [r for r in walk["requests"] if r["external"]]
if other_sites:
    fails.append(f"{len(other_sites)} requests went to other sites, for example {other_sites[0]['path'][:60]}")
broken = [r for r in walk["requests"] if not r["external"] and str(r["status"]) in {"403", "405", "500", "502", "503", "504"}]
for r in broken[:5]:
    fails.append(f"{r['method']} {r['path'][:70]} answered {r['status']} on {r['page']}")

served = sum(1 for p in walk["pages"] if p["path"] not in REFUSED_ON_PURPOSE)
print(f"walk: {len(walk['pages'])} pages, {served} served, {len(REFUSED_ON_PURPOSE)} refused on purpose, "
      f"{len(walk['requests'])} requests, {len(other_sites)} to other sites")
for f in fails:
    print("FAIL  " + f)
print("walk passed" if not fails else f"{len(fails)} problem(s)")
sys.exit(1 if fails else 0)
