"""Fill a throwaway GitLab with what the public-door tests look at: a public project (README with an uploaded image,
docs, a second branch with a merge request, an issue, a tag, a CI file), a private project, a public group with a
project, a public snippet; sign-up off. Talks to GitLab directly on 127.0.0.1:8181. Needs TOK (an API token)."""
import base64, json, urllib.request, urllib.parse, uuid
B = "http://127.0.0.1:8181/api/v4"
import os
H = {"PRIVATE-TOKEN": os.environ["TOK"]}

def call(method, path, data=None, files=None):
    hdr = dict(H)
    body = None
    if files:
        bd = uuid.uuid4().hex
        parts = []
        for name, (fn, content) in files.items():
            parts.append(f'--{bd}\r\nContent-Disposition: form-data; name="{name}"; filename="{fn}"\r\nContent-Type: image/png\r\n\r\n'.encode() + content + b"\r\n")
        body = b"".join(parts) + f"--{bd}--\r\n".encode()
        hdr["Content-Type"] = f"multipart/form-data; boundary={bd}"
    elif data is not None:
        body = json.dumps(data).encode(); hdr["Content-Type"] = "application/json"
    req = urllib.request.Request(B + path, data=body, headers=hdr, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} -> {e.code} {e.read()[:200]}")

# 1x1 PNG
png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
print("sign-up off:", call("PUT", "/application/settings?signup_enabled=false&default_project_visibility=private")["signup_enabled"])

pub = call("POST", "/projects", {"name": "portfolio-site", "visibility": "public", "initialize_with_readme": False})
pid = pub["id"]; print("public project", pub["path_with_namespace"], pid)
up = call("POST", f"/projects/{pid}/uploads", files={"file": ("diagram.png", png)})
print("upload markdown:", up["markdown"])
call("POST", f"/projects/{pid}/repository/commits", {"branch": "main", "start_branch": "main", "commit_message": "first commit",
    "actions": [
      {"action": "create", "file_path": "README.md", "content": f"# Portfolio site\n\nA test project.\n\n{up['markdown']}\n\n- [notes](docs/notes.md)\n"},
      {"action": "create", "file_path": "docs/notes.md", "content": "# Notes\n\nSome notes with `code`.\n"},
      {"action": "create", "file_path": "src/app.py", "content": "print('hello')\n"},
      {"action": "create", "file_path": "LICENSE", "content": "MIT\n"},
      {"action": "create", "file_path": ".gitlab-ci.yml", "content": "test:\n  script: [echo ok]\n"}]})
call("POST", f"/projects/{pid}/repository/branches?branch=feature&ref=main")
call("POST", f"/projects/{pid}/repository/commits", {"branch": "feature", "commit_message": "change the app",
    "actions": [{"action": "update", "file_path": "src/app.py", "content": "print('hello, world')\n"}]})
mr = call("POST", f"/projects/{pid}/merge_requests", {"source_branch": "feature", "target_branch": "main", "title": "Change the app"})
iss = call("POST", f"/projects/{pid}/issues", {"title": "First issue", "description": "Something to track."})
call("POST", f"/projects/{pid}/repository/tags?tag_name=v1.0&ref=main&message=release")
print("mr iid", mr["iid"], "issue iid", iss["iid"])

priv = call("POST", "/projects", {"name": "secret-infra", "visibility": "private", "initialize_with_readme": True})
print("private project", priv["path_with_namespace"])
grp = call("POST", "/groups", {"name": "labs", "path": "labs", "visibility": "public"})
gp = call("POST", "/projects", {"name": "demo", "namespace_id": grp["id"], "visibility": "public", "initialize_with_readme": True})
print("group project", gp["path_with_namespace"])
sn = call("POST", "/snippets", {"title": "A snippet", "visibility": "public", "files": [{"file_path": "a.txt", "content": "hi"}]})
print("snippet", sn["id"])
