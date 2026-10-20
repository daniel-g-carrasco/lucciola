#!/usr/bin/env python3
"""The content editor's server, running: only the page opened with the
address it prints (#k=<key>) can use its API. Another program on this
computer, a Flatpak app that shares the network for one, reaches 127.0.0.1
too: it must get neither the key nor an answer from /api/. Nothing here
writes a file (Save gets an empty request)."""

import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVE = ROOT / "tools/content-editor/serve.py"
fails = 0


def check(name, cond, detail=""):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails += 1
        if detail:
            print(f"     {detail}")


def req(base, path, method="GET", headers=None, body=None):
    r = urllib.request.Request(base + path, method=method, headers=headers or {},
                               data=body.encode() if body is not None else None)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


srv = subprocess.Popen([sys.executable, "-B", str(SERVE), "--port", "0", "--no-browser"],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    first = srv.stdout.readline()
    m = re.search(r"(http://127\.0\.0\.1:\d+)/#k=([\w-]+)", first)
    check("server: prints its address with the key in the fragment", m is not None, first.strip())
    if not m:
        sys.exit(1)
    base, key = m.group(1), m.group(2)
    port = base.rsplit(":", 1)[1]
    js = {"Content-Type": "application/json"}

    status, page = req(base, "/")
    check("server: the page opens without the key", status == 200, status)
    check("server: the page does not carry the key", key not in page and "__TOKEN__" not in page)
    for f in ("editor.js", "frame.js", "editor.css"):
        status, text = req(base, f"/ui/{f}")
        check(f"server: /ui/{f} does not carry the key", status == 200 and key not in text, status)

    for path in ("/api/state", "/api/diff", "/api/welcome"):
        status, _ = req(base, path)
        check(f"server: GET {path} without the key is refused", status == 403, status)
    status, text = req(base, "/api/state", headers={"X-Editor-Token": key})
    check("server: GET /api/state with the key answers", status == 200 and "branch" in text, status)

    for name, hdr in (("without the key", {}), ("with a wrong key", {"X-Editor-Token": "x" * len(key)}),
                      ("with the key from a foreign page", {"X-Editor-Token": key, "Origin": "http://evil.example"}),
                      ("with the key from another local port", {"X-Editor-Token": key, "Origin": "http://127.0.0.1:1"})):
        for path in ("/api/save", "/api/propose/plan", "/api/propose"):
            status, _ = req(base, path, "POST", {**js, **hdr}, "{}")
            check(f"server: POST {path} {name} is refused", status == 403, status)
    status, _ = req(base, "/api/save", "POST", {**js, "X-Editor-Token": key, "Host": "evil.example"}, "{}")
    check("server: a foreign Host is refused even with the key", status == 403, status)

    status, text = req(base, "/api/save", "POST", {**js, "X-Editor-Token": key}, "{}")
    check("server: POST /api/save with the key answers (nothing to save)",
          status == 200 and '"saved": []' in text, f"{status} {text[:200]}")
    status, _ = req(base, "/api/save", "POST",
                    {**js, "X-Editor-Token": key, "Origin": f"http://localhost:{port}"}, "{}")
    check("server: the editor's own origin is accepted", status == 200, status)
finally:
    srv.terminate()
    srv.wait(timeout=10)

print()
if fails:
    print(f"{fails} test(s) FAILED")
    sys.exit(1)
print("all content-editor server tests passed")
