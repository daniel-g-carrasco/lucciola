#!/usr/bin/env bash
# /usr/libexec/lucciola/admin handing secrets to a helper, for real: its
# run_step on a stand-in for lucciola-tpm-unlock that copies what it was
# given. The disk passphrase and the TPM's PIN arrive whole, each in a file
# only its owner reads, under a directory only its owner enters, never as
# arguments; the files are gone when the step ends, also when it fails; and
# two lines are read from stdin, the passphrase first.
# Needs python3 only (no root: the secret directory is pointed at a
# temporary one).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 -I - "$ROOT/build_files/system_files/usr/libexec/lucciola/admin" <<'PY'
import importlib.machinery
import importlib.util
import io
import os
import sys
import tempfile

fails = 0


def check(name, cond, detail=""):
    global fails
    if cond:
        print(f"ok   {name}")
    else:
        fails += 1
        print(f"FAIL {name}" + (f"\n     {detail}" if detail else ""))


_admin_path = sys.argv[1]
_loader = importlib.machinery.SourceFileLoader("lucciola_admin", _admin_path)
_spec = importlib.util.spec_from_loader("lucciola_admin", _loader)
admin = importlib.util.module_from_spec(_spec)
sys.dont_write_bytecode = True
_loader.exec_module(admin)

with tempfile.TemporaryDirectory() as tmp:
    admin.SECRET_DIR = os.path.join(tmp, "run")
    seen = os.path.join(tmp, "seen")
    fake = os.path.join(tmp, "fake-tpm-unlock")
    with open(fake, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\n"
                 'm() { [ -n "$1" ] && stat -c %a "$1"; }\n'
                 f'{{ echo "argv: $*"; printf "pw=[%s]\\n" "$(cat "$LUCCIOLA_UNLOCK_KEY_FILE")";\n'
                 '  printf "pin=[%s]\\n" "$([ -n "${LUCCIOLA_TPM_PIN_FILE:-}" ] && cat "$LUCCIOLA_TPM_PIN_FILE")";\n'
                 '  echo "modes: $(m "$LUCCIOLA_UNLOCK_KEY_FILE") $(m "${LUCCIOLA_TPM_PIN_FILE:-}") $(m "$(dirname "$LUCCIOLA_UNLOCK_KEY_FILE")")";\n'
                 f'  echo "confirm=$CONFIRM"; }} > {seen}\n'
                 'exit "${FAKE_RC:-0}"\n')
    os.chmod(fake, 0o755)
    step = admin.Step([fake, "pin", "7"], env={"CONFIRM": "yes"}, stdin="secret-and-pin-files")
    rc = admin.run_step(step, "the disk passphrase", "c0ffee42")
    got = open(seen, encoding="utf-8").read()
    check("admin pin step: runs and reports the helper's exit code", rc == 0, got)
    check("admin pin step: the passphrase arrives whole, no newline added", "pw=[the disk passphrase]\n" in got, got)
    check("admin pin step: the PIN arrives whole", "pin=[c0ffee42]\n" in got, got)
    check("admin pin step: both files 600, their directory 700", "modes: 600 600 700\n" in got, got)
    check("admin pin step: neither secret is an argument", "argv: pin 7\n" in got, got)
    check("admin pin step: the files are gone afterwards", os.listdir(admin.SECRET_DIR) == [], str(os.listdir(admin.SECRET_DIR)))
    step = admin.Step([fake, "pin", "7"], env={"CONFIRM": "yes", "FAKE_RC": "3"}, stdin="secret-and-pin-files")
    check("admin pin step: a failing helper's code comes back, and the files are gone all the same",
          admin.run_step(step, "p", "123456") == 3 and os.listdir(admin.SECRET_DIR) == [])
    step = admin.Step([fake, "no-pin", "7"], env={"CONFIRM": "yes"}, stdin="secret-file")
    os.remove(seen)
    admin.run_step(step, "the disk passphrase")
    got = open(seen, encoding="utf-8").read()
    check("admin no-pin step: the passphrase file, and no PIN file at all", "pw=[the disk passphrase]\n" in got and "pin=[]\n" in got, got)

_stdin = sys.stdin
sys.stdin = io.StringIO("the disk passphrase\nc0ffee42\n")
check("admin reads two lines: the passphrase, then the PIN", (admin.read_secret(), admin.read_secret("PIN")) == ("the disk passphrase", "c0ffee42"))
sys.stdin = io.StringIO("the disk passphrase\n")
admin.read_secret()
try:
    admin.read_secret("PIN")
    check("admin refuses a missing PIN line", False)
except SystemExit as e:
    check("admin refuses a missing PIN line, naming it", "no PIN was given" in str(e), str(e))
sys.stdin = _stdin

print("admin-secrets: all checks passed" if fails == 0 else f"admin-secrets: {fails} failed")
sys.exit(1 if fails else 0)
PY
