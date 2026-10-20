#!/usr/bin/env bash
# Checks that run a command in a shell of their own must report that
# command's failure, not the success of the tail or head that shortens its
# output (review R6, 2026-10-20): `(exit 42) | tail` is 0 in a shell without
# pipefail, and the strict mode of the script that started the shell does
# not reach it. Covered here, with stub commands that fail after printing
# ordinary-looking output:
#   - upgrade-smoke.py's guest commands (layer, rebase, gaming dry run), run
#     in `bash --noprofile --norc` the way the serial console runs them;
#   - validate-baseline-packages, through a fake podman that runs the
#     container's script on this machine with fake dnf and rpm.
# PyYAML is needed by validate-baseline-packages (lint.yml installs it).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}
mkdir -p "$T/bin"

# --- upgrade-smoke.py: the guest commands ----------------------------------
# rpm-ostree stub: prints what a run prints, exits $FAKE_RC.
cat > "$T/bin/rpm-ostree" <<'STUB'
#!/bin/sh
echo "Checking out tree 1a2b3c... done"
echo "Resolving dependencies... done"
[ "${FAKE_RC:-0}" = 0 ] || echo "error: Could not depsolve transaction" >&2
exit "${FAKE_RC:-0}"
STUB
printf '#!/bin/sh\nshift; exec "$@"\n' > "$T/bin/timeout"
chmod +x "$T/bin/"*
printf '# comment\nsteam\nlutris\n' > "$T/gaming.txt"
printf '# only comments\n\n' > "$T/gaming-empty.txt"

# guest <python expression giving the command> ; runs it as capture() does,
# sets RC from the "__E__ RC=" marker and leaves the output in $T/out.
guest() {
  local cmd
  cmd="$(python3 - "$ROOT/.github/scripts/upgrade-smoke.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("upgrade_smoke", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(eval(sys.argv[2], vars(m)))
PY
)" || cmd="echo 'no such helper in upgrade-smoke.py'; false"
  env -i PATH="$T/bin:/usr/bin:/bin" FAKE_RC="${FAKE_RC:-0}" bash --noprofile --norc \
    -c "echo __B__; $cmd; echo \"__E__ RC=\$?\"" > "$T/out" 2>&1 || true
  RC="$(sed -n 's/^__E__ RC=//p' "$T/out")"
}
FAKE_RC=1 guest "keep_status('rpm-ostree rebase x', 8)"
check "rebase: a failing rpm-ostree is a failure (RC=$RC)" [ "$RC" = 1 ]
check "rebase: ...and its last lines are still shown" grep -q "Could not depsolve" "$T/out"
FAKE_RC=0 guest "keep_status('rpm-ostree rebase x', 8)"
check "rebase: a good one passes (RC=$RC)" [ "$RC" = 0 ]
FAKE_RC=0 guest "keep_status('rpm-ostree rebase x', 1)"
check "rebase: only the last lines are printed" bash -c "! grep -q 'Checking out' '$T/out'"
FAKE_RC=1 guest "keep_status('rpm-ostree install -y htop', 5)"
check "layer: a failing install is a failure (RC=$RC)" [ "$RC" = 1 ]
FAKE_RC=1 guest "gaming_dry_run('', '$T/gaming.txt')"
check "gaming: a dry run that does not resolve is a failure (RC=$RC)" [ "$RC" = 1 ]
FAKE_RC=0 guest "gaming_dry_run('', '$T/gaming.txt')"
check "gaming: a dry run that resolves passes (RC=$RC)" [ "$RC" = 0 ]
FAKE_RC=0 guest "gaming_dry_run('', '$T/missing.txt')"
check "gaming: a missing package list is a failure (RC=$RC)" [ "$RC" = 1 ]
FAKE_RC=0 guest "gaming_dry_run('', '$T/gaming-empty.txt')"
check "gaming: a list without packages is a failure (RC=$RC)" [ "$RC" = 1 ]
FAKE_RC=1 guest "gaming_dry_run('echo pw | ', '$T/gaming.txt')"
check "gaming: behind the sudo pipe, still rpm-ostree's status (RC=$RC)" [ "$RC" = 1 ]

# --- validate-baseline-packages ---------------------------------------------
# A copy of the script next to a declarations file we control.
V="$T/spec"; mkdir -p "$V/scripts" "$V/declarations"
cp "$ROOT/build_files/40-spec-scripts/scripts/validate-baseline-packages" "$V/scripts/"
decl() {  # decl <install list, space separated>
  { echo "host_packages:"; echo "  baseline:"; echo "    codec_replacement:"
    echo "      override_remove: [libavcodec-free]"
    echo "      install: [$(sed 's/ /, /g' <<<"$1")]"
    echo "    fonts: [google-noto-sans-fonts]"; } > "$V/declarations/margine-atomic.yaml"
}
# podman stub: `run --rm -e K=V... IMAGE bash -c SCRIPT` runs SCRIPT here,
# with the -e variables; FAKE_PODMAN=silent prints nothing and exits 0
# (a run that never reached the loop).
cat > "$T/bin/podman" <<'STUB'
#!/usr/bin/env bash
[ "$1" = pull ] && exit 0
[ "$1" = run ] || exit 2
shift; envs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rm) shift ;;
    -e) envs+=("$2"); shift 2 ;;
    *) break ;;
  esac
done
shift  # the image
[ "${FAKE_PODMAN:-}" = silent ] && exit 0
exec env "${envs[@]}" "$@"
STUB
# dnf stub: everything exists; the test transaction prints and exits $FAKE_RESOLVE_RC.
cat > "$T/bin/dnf" <<'STUB'
#!/bin/sh
case "$*" in
  *tsflags=test*) echo "Transaction Summary"; echo "Install 3 Packages"
                  [ "${FAKE_RESOLVE_RC:-0}" = 0 ] || echo "Problem: package ffmpeg-libs conflicts with libavcodec-free"
                  exit "${FAKE_RESOLVE_RC:-0}" ;;
  *) exit 0 ;;
esac
STUB
printf '#!/bin/sh\necho 45\n' > "$T/bin/rpm"
chmod +x "$T/bin/"*
vbp() {  # vbp ; sets RC
  RC=0
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$HOME" FAKE_RESOLVE_RC="${FAKE_RESOLVE_RC:-0}" FAKE_PODMAN="${FAKE_PODMAN:-}" \
    bash "$V/scripts/validate-baseline-packages" --keep-image > "$T/out" 2>&1 || RC=$?
}
decl "ffmpeg gstreamer1-plugins-bad"
FAKE_RESOLVE_RC=1 vbp
check "baseline: a dnf depsolve failure fails the check (rc $RC, want 2)" [ "$RC" = 2 ]
FAKE_RESOLVE_RC=0 vbp
check "baseline: a clean depsolve passes (rc $RC)" [ "$RC" = 0 ]
FAKE_PODMAN=silent vbp
check "baseline: a container run without verdicts is a failure (rc $RC)" [ "$RC" = 1 ]
decl ""
FAKE_RESOLVE_RC=0 vbp
check "baseline: an empty install list is a failure (rc $RC)" [ "$RC" = 1 ]

if (( fails )); then echo "$fails pipeline-status case(s) failed"; exit 1; fi
echo "all pipeline-status cases passed"
