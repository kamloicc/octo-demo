#!/usr/bin/env python3
"""Upload logos/*.png as project logos. Usage: python3 upload-logos.py (needs OCTOPUS_URL / OCTOPUS_API_KEY)."""
import json, os, sys, uuid, urllib.request, urllib.error

URL = os.environ.get("OCTOPUS_URL", "").rstrip("/")
KEY = os.environ.get("OCTOPUS_API_KEY", "")
SPACE = os.environ.get("OCTOPUS_SPACE", "SE Industry Demos")
HERE = os.path.dirname(os.path.abspath(__file__))


def call(method, path, data=None, ctype="application/json"):
    req = urllib.request.Request(URL + path, data=data, method=method,
                                 headers={"X-Octopus-ApiKey": KEY, "Content-Type": ctype})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
        return json.loads(raw) if raw and r.headers.get_content_type() == "application/json" else raw


def multipart(field, filename, content):
    b = uuid.uuid4().hex
    body = (f"--{b}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{filename}\"\r\n"
            f"Content-Type: image/png\r\n\r\n").encode() + content + f"\r\n--{b}--\r\n".encode()
    return body, f"multipart/form-data; boundary={b}"


def upload(space_id, project_id, path):
    content = open(path, "rb").read()
    errors = []
    # Octopus versions differ slightly; try the known variants
    for method in ("POST", "PUT"):
        for field in ("fileToUpload", "file"):
            body, ctype = multipart(field, os.path.basename(path), content)
            for p in (f"/api/{space_id}/projects/{project_id}/logo", f"/api/projects/{project_id}/logo"):
                try:
                    call(method, p, body, ctype)
                    return f"{method} {field}"
                except urllib.error.HTTPError as e:
                    errors.append(f"{method} {p} [{field}] -> {e.code}")
    raise RuntimeError("; ".join(errors[-3:]))


def main():
    if not URL or not KEY:
        sys.exit("Set OCTOPUS_URL and OCTOPUS_API_KEY")
    spaces = call("GET", "/api/spaces/all")
    space = next((s for s in spaces if s["Name"] == SPACE), None) or sys.exit(f"Space '{SPACE}' not found")
    projects = {p["Name"]: p for p in call("GET", f"/api/{space['Id']}/projects/all")}
    mapping = json.load(open(os.path.join(HERE, "logos", "logos.json")))
    ok = 0
    for name, fn in mapping.items():
        p = projects.get(name)
        if not p:
            print(f"  - skip (no project): {name}"); continue
        try:
            how = upload(space["Id"], p["Id"], os.path.join(HERE, "logos", fn))
            print(f"  OK   {name}  ({how})"); ok += 1
        except RuntimeError as e:
            print(f"  FAIL {name}: {e}")
    print(f"{ok}/{len(mapping)} logos uploaded. Refresh the browser (logos are cached).")


if __name__ == "__main__":
    main()
