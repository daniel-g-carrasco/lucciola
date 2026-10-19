"""Exercise the actual user-session check with root-only bootc and layered status."""
import json
import runpy
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

HELPER = Path(sys.argv[1]) if len(sys.argv) > 1 else (
    Path(__file__).resolve().parents[1]
    / "build_files/system_files/usr/libexec/margine-staleness-check"
)
REPO = "ghcr.io/daniel-g-carrasco/lucciola"


def check(origin, stale, expected, status_ok=True):
    calls = []

    def run(cmd, **kwargs):
        calls.append(cmd)
        if cmd[0] == "bootc":
            return subprocess.CompletedProcess(cmd, 1, "", "requires root")
        if cmd[0] == "rpm-ostree":
            data = {"deployments": [
                {"staged": True, "container-image-reference": f"ostree-image-signed:docker://{REPO}:stable"},
                {"booted": True, "requested-packages": ["code"], "container-image-reference": origin},
            ]}
            return subprocess.CompletedProcess(cmd, 0 if status_ok else 1, json.dumps(data), "")
        if cmd[0] == "skopeo":
            assert cmd[-1] == f"docker://{REPO}:candidate", "must inspect the booted tag"
            from datetime import datetime, timezone
            created = "2000-01-01T00:00:00Z" if stale else datetime.now(timezone.utc).isoformat()
            return subprocess.CompletedProcess(cmd, 0, json.dumps({"Created": created}), "")
        assert cmd[0] == "/usr/libexec/margine/margine-notify", "unexpected subprocess"
        return subprocess.CompletedProcess(cmd, 0, "", "")

    with patch("subprocess.run", side_effect=run):
        try:
            runpy.run_path(str(HELPER))
        except SystemExit as e:
            assert e.code == 0
    notified = any(c[0].endswith("margine-notify") for c in calls)
    assert notified == expected, f"notification={notified}, expected={expected}"


check(f"ostree-image-signed:docker://{REPO}:candidate", True, True)
print("ok   stale candidate alerts a non-root user with layered packages")
check(f"ostree-unverified-registry:{REPO}:candidate", False, False)
print("ok   fresh booted tag does not alert")
check(f"ostree-image-signed:docker://{REPO}@sha256:" + "a" * 64, True, False)
check("ostree-unverified-registry:example.invalid/other:stable", True, False)
check(f"ostree-image-signed:docker://{REPO}:candidate", True, False, status_ok=False)
print("ok   deliberate pins, other images, and unavailable status do not alert")
