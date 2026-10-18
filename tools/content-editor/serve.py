#!/usr/bin/env python3
"""Lucciola content editor: change the website and the welcome window texts.

    python3 tools/content-editor/serve.py      (or: just edit)

Opens http://127.0.0.1:<port> in the browser. Only this computer can reach
it. Python's standard library only; nothing to install.
"""

import argparse
import datetime
import json
import re
import secrets
import shutil
import subprocess
import sys
import threading
import urllib.request
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import site_patch  # noqa: E402
import welcome_content  # noqa: E402

REPO = HERE.parents[1]
SITE = REPO / "site/index.html"
WELCOME = welcome_content.CONTENT
FILES = [SITE, WELCOME]
UI = HERE / "ui"
TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml"}
TOKEN = secrets.token_urlsafe(24)
LOCK = threading.Lock()
MAX_BODY = 8 * 1024 * 1024


def rel(p):
    return str(Path(p).relative_to(REPO))


def read(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    tmp = Path(str(path) + ".editor-tmp")
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    tmp.replace(path)


def git(*args, check=False, timeout=60):
    r = subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip() or r.stdout.strip()}")
    return r


def branch():
    r = git("symbolic-ref", "--quiet", "--short", "HEAD")
    return r.stdout.strip() if r.returncode == 0 else None


def changed_files():
    r = git("status", "--porcelain", "--", *map(rel, FILES))
    return [line[3:].strip() for line in r.stdout.splitlines() if line.strip()]


# ---- the site page as served inside the editor ---------------------------

def served_site():
    doc = site_patch.Document(read(SITE))
    page = doc.served()
    head = '<link rel="stylesheet" href="/ui/frame.css">\n'
    tail = f'<script src="/ui/frame.js" data-hash="{doc.hash}"></script>\n'
    i = page.rfind("</head>")
    page = page[:i] + head + page[i:]
    j = page.rfind("</body>")
    return page[:j] + tail + page[j:]


# ---- saving --------------------------------------------------------------

def save(body):
    """Check both parts first, then write; nothing is written if one is wrong."""
    errors, warnings, writes = [], [], []
    site = body.get("site")
    if site and (site.get("ops") or site.get("texts")):
        try:
            new, warn = site_patch.save(read(SITE), site.get("hash"), site.get("ops", []), site.get("texts", {}))
            warnings += [f"Website: {w}" for w in warn]
            writes.append((SITE, new))
        except site_patch.EditError as e:
            errors.append(f"Website: {e}")
    welcome = body.get("welcome")
    if welcome is not None:
        problems = welcome_content.validate(welcome)
        if problems:
            errors += [f"Welcome window: {p}" for p in problems]
        else:
            writes.append((WELCOME, welcome_content.dumps(welcome)))
    if errors:
        return {"ok": False, "errors": errors, "warnings": warnings}
    saved = []
    for path, text in writes:
        if read(path) != text:
            write(path, text)
            saved.append(rel(path))
    return {"ok": True, "saved": saved, "warnings": warnings}


# ---- show changes --------------------------------------------------------

def diff():
    r = git("diff", "--no-color", "-U1", "HEAD", "--", *map(rel, FILES))
    return {"diff": r.stdout, "branch": branch()}


# ---- propose changes -----------------------------------------------------

def gh_state():
    if not shutil.which("gh"):
        return "missing"
    r = subprocess.run(["gh", "auth", "status", "--hostname", "github.com"], capture_output=True, text=True, timeout=30)
    return "ok" if r.returncode == 0 else "logged-out"


def slug(text):
    words = re.findall(r"[a-z0-9]+", text.lower())[:4]
    return "-".join(words) or "texts"


def plan(summary):
    """What Propose would do, in words and commands, and what stops it."""
    problems, notes = [], []
    files = changed_files()
    cur = branch()
    if not files:
        problems.append("There is nothing to propose: no saved changes to the website or the welcome window.")
    if cur is None:
        problems.append("The checkout is not on a branch. Run: git switch main")
    gh = gh_state()
    if gh == "missing":
        problems.append("The GitHub command line tool (gh) is not installed. Install it, then run: gh auth login")
    elif gh == "logged-out":
        problems.append("The GitHub command line tool (gh) is not logged in. Run: gh auth login")
    if git("remote", "get-url", "origin").returncode:
        problems.append("This checkout has no 'origin' remote on GitHub.")
    other = [line[3:] for line in git("status", "--porcelain").stdout.splitlines()
             if line[3:].strip() not in files]
    if other:
        more = f" and {len(other) - 5} more" if len(other) > 5 else ""
        notes.append(f"Other changed files in this checkout are left out: {', '.join(other[:5])}{more}.")
    summary = (summary or "").strip() or "update texts"
    if site_patch.EM_DASH in summary:
        problems.append("The description has a long dash; use a colon or a comma.")
    area = {rel(SITE): "site", rel(WELCOME): "welcome"}
    areas = sorted({area.get(f, "content") for f in files}) or ["content"]
    message = f"{areas[0] if len(areas) == 1 else 'content'}: {summary}"
    reuse = bool(cur and cur.startswith("content/"))
    if reuse:
        new_branch = cur
        notes.append(f"You are already on the proposal {cur}: this adds to it.")
    else:
        day = datetime.date.today().isoformat()
        base = f"content/{day}-{slug(summary)}"
        new_branch, k = base, 2
        while git("rev-parse", "--verify", "--quiet", f"refs/heads/{new_branch}").returncode == 0:
            new_branch, k = f"{base}-{k}", k + 1
        if cur and cur not in ("main", "master"):
            notes.append(f"You are on the branch {cur}, not main: the proposal will also carry its other changes.")
    steps = []
    if not reuse:
        steps.append(("Make a new branch for the proposal", ["git", "switch", "-c", new_branch]))
    steps += [
        ("Take the changed files", ["git", "add", "--", *files]),
        ("Save them as one change", ["git", "commit", "-m", message]),
        ("Send the branch to GitHub", ["git", "push", "-u", "origin", f"{new_branch}:{new_branch}"]),
        ("Open a pull request to main (if there is none yet)",
         ["gh", "pr", "create", "--base", "main", "--head", new_branch, "--title", message, "--body",
          "Text changes made with the content editor (tools/content-editor).\n\n"
          + "\n".join(f"- {f}" for f in files)]),
    ]
    return {"ok": not problems, "problems": problems, "notes": notes, "branch": new_branch,
            "from": cur, "files": files, "message": message,
            "steps": [{"what": w, "command": " ".join(_quote(a) for a in c)} for w, c in steps],
            "_steps": steps}


def _quote(a):
    return a if re.fullmatch(r"[\w./:=@+-]+", a) else "'" + a.replace("'", "'\\''") + "'"


def propose(summary, expected_branch):
    p = plan(summary)
    if not p["ok"]:
        return {"ok": False, "log": [], "errors": p["problems"]}
    if p["branch"] != expected_branch:
        return {"ok": False, "log": [], "errors": ["Something changed since the plan was shown. Open Propose again."]}
    if not p["branch"].startswith("content/") or p["branch"] in ("main", "master"):
        return {"ok": False, "log": [], "errors": ["Refusing to push anywhere but a content/ branch."]}
    log = []
    for what, cmd in p["_steps"]:
        if cmd[:3] == ["gh", "pr", "create"]:
            v = subprocess.run(["gh", "pr", "view", p["branch"], "--json", "url", "-q", ".url"],
                               cwd=REPO, capture_output=True, text=True, timeout=60)
            if v.returncode == 0 and v.stdout.strip():
                log.append({"what": "The pull request already exists", "ok": True, "out": v.stdout.strip()})
                return {"ok": True, "log": log, "url": v.stdout.strip(), "branch": p["branch"]}
        r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=180)
        out = (r.stdout + r.stderr).strip()
        log.append({"what": what, "ok": r.returncode == 0, "out": out[-2000:]})
        if r.returncode:
            return {"ok": False, "log": log, "errors": [f"Stopped at: {what}."], "branch": branch()}
    url = next((m.group(0) for m in re.finditer(r"https://github\.com/\S+/pull/\d+", log[-1]["out"])), "")
    return {"ok": True, "log": log, "url": url, "branch": p["branch"]}


# ---- HTTP ----------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "LucciolaEditor"

    def log_message(self, fmt, *args):
        if self.server.verbose:
            super().log_message(fmt, *args)

    def _host_ok(self):
        host = (self.headers.get("Host") or "").split(":")[0]
        return host in ("127.0.0.1", "localhost")

    def _send(self, status, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else (
            body.encode("utf-8") if isinstance(body, str) else json.dumps(body).encode("utf-8"))
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._host_ok():
            return self._send(HTTPStatus.FORBIDDEN, {"error": "bad host"})
        path = self.path.split("?")[0]
        try:
            if path == "/":
                page = read(UI / "editor.html").replace("__TOKEN__", TOKEN)
                return self._send(200, page, TYPES[".html"])
            if path == "/site":
                return self._send(200, served_site(), TYPES[".html"])
            if path.startswith("/ui/"):
                f = (UI / path[4:]).resolve()
                if f.parent != UI or not f.is_file() or f.suffix not in TYPES:
                    return self._send(404, {"error": "not found"})
                return self._send(200, f.read_bytes(), TYPES[f.suffix])
            if path == "/api/welcome":
                return self._send(200, {"content": welcome_content.load(WELCOME), "actions": welcome_content.ACTIONS,
                                        "conditions": welcome_content.CONDITIONS})
            if path == "/api/state":
                return self._send(200, {"branch": branch(), "changed": changed_files()})
            if path == "/api/diff":
                return self._send(200, diff())
        except site_patch.EditError as e:
            return self._send(500, {"error": str(e)})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._host_ok() or self.headers.get("X-Editor-Token") != TOKEN:
            return self._send(HTTPStatus.FORBIDDEN, {"error": "This request did not come from the editor page."})
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BODY:
            return self._send(413, {"error": "too large"})
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._send(400, {"error": "bad request"})
        path = self.path.split("?")[0]
        with LOCK:
            if path == "/api/save":
                return self._send(200, save(body))
            if path == "/api/propose/plan":
                p = plan(body.get("summary"))
                p.pop("_steps")
                return self._send(200, p)
            if path == "/api/propose":
                return self._send(200, propose(body.get("summary"), body.get("branch")))
        self._send(404, {"error": "not found"})


def already_running(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=2) as r:
            return "branch" in json.loads(r.read())
    except (OSError, ValueError):
        return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8790, help="port on 127.0.0.1 (default 8790; 0 picks a free one)")
    ap.add_argument("--no-browser", action="store_true", help="do not open the browser")
    ap.add_argument("--verbose", action="store_true", help="log every request")
    args = ap.parse_args()
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError:
        if args.port and already_running(args.port):
            url = f"http://127.0.0.1:{args.port}/"
            print(f"The editor is already running: {url}\n(To restart it, press Ctrl+C in the terminal where it runs.)")
            if not args.no_browser:
                webbrowser.open(url)
            return
        srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    srv.verbose = args.verbose
    url = f"http://127.0.0.1:{srv.server_address[1]}/"
    print(f"Lucciola content editor: {url}\nWorking on branch: {branch() or '(none)'}\nPress Ctrl+C to stop.",
          flush=True)
    if not args.no_browser:
        threading.Timer(0.3, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
