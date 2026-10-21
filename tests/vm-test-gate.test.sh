#!/usr/bin/env bash
# The vm-test gate (.github/scripts/build-inputs-need-vm-test.py, the
# build-inputs-need-vm-test job in lint.yml): a pull request that changes
# what the image is built from fails the check until it carries the vm-test
# label, in plain words; anything else passes. Offline, with file lists.
# Then the wiring: the job runs on every pull request and on label events,
# with no path filter (it is meant to be required); build.yml builds on the
# label; nothing the gate guards is ignored by build.yml; Renovate adds the
# label to what the gate guards.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/.github/scripts/build-inputs-need-vm-test.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out"; fails=$((fails+1)); fi
}
gate() {  # gate <labels> <files...> ; sets RC, output in $T/out
  local labels="$1"; shift
  printf '%s\n' "$@" > "$T/files"
  RC=0
  env -i PATH=/usr/bin:/bin python3 -I "$GATE" --files "$T/files" --labels "$labels" > "$T/out" 2>&1 || RC=$?
}

gate "" Containerfile
check "Containerfile without the label: fails (rc $RC)"             [ "$RC" = 1 ]
check "...names the file"                                            grep -q '^  Containerfile$' "$T/out"
check "...says what to do, in words"                                 grep -q 'Add the label `vm-test` to the pull request' "$T/out"
check "...and emits an ::error:: for the job log"                    grep -q '^::error::' "$T/out"
gate "vm-test" Containerfile
check "Containerfile with the label: passes (rc $RC)"               [ "$RC" = 0 ]
gate "bug,vm-test,documentation" build_files/50-branding/install.sh
check "the label among others: passes (rc $RC)"                     [ "$RC" = 0 ]
gate "VM-TEST" build_files/50-branding/install.sh
check "the label is exact (rc $RC)"                                 [ "$RC" = 1 ]
gate "" docs/SECURITY-CLAIMS.md README.md .github/workflows/lint.yml tests/x.test.sh tools/content-editor/serve.py site/index.html
check "docs, lint, tests, tools, site: pass (rc $RC)"               [ "$RC" = 0 ]
for f in build_files/00-common.sh build_files/system_files/usr/libexec/margine/rpm-trust lucciola/build.sh \
         lucciola/system_files/etc/greetd/config.toml installer/flatpaks-base disk_config/disk.toml \
         .github/workflows/build.yml .github/scripts/validate-image-rootfs.sh .github/scripts/scan-image-security.py \
         .github/security-baseline/units.txt; do
  gate "" README.md "$f"
  check "$f is a build input (rc $RC)"                               [ "$RC" = 1 ]
done
gate "" .github/workflows/build-fedora-kernel.yml .github/scripts/upgrade-smoke.py disk_configuration/x
check "look-alike paths are not inputs (rc $RC)"                     [ "$RC" = 0 ]
gate ""
check "no changed file: passes (rc $RC)"                             [ "$RC" = 0 ]

# --- the wiring -----------------------------------------------------------
python3 - "$ROOT" > "$T/out" 2>&1 <<'PY' && RC=0 || RC=$?
import re, sys, yaml
root = sys.argv[1]
bad = []
lint = yaml.safe_load(open(f"{root}/.github/workflows/lint.yml"))
on = lint.get("on") or lint.get(True)
pr = on.get("pull_request")
if not isinstance(pr, dict) or "paths" in pr or "paths-ignore" in pr:
    bad.append("lint.yml: pull_request must have no path filter (the gate is a required check)")
types = set((pr or {}).get("types") or [])
for t in ("opened", "synchronize", "reopened", "labeled", "unlabeled"):
    if t not in types:
        bad.append(f"lint.yml: pull_request types lack {t}")
job = lint["jobs"].get("build-inputs-need-vm-test")
if not job:
    bad.append("lint.yml: no build-inputs-need-vm-test job")
else:
    if "name" in job:
        bad.append("lint.yml: the gate job must have no name: (the check is known by its id)")
    if str(job.get("if", "")).strip() != "github.event_name == 'pull_request'":
        bad.append("lint.yml: the gate job runs on pull requests only (if: github.event_name == 'pull_request')")
    perms = job.get("permissions") or {}
    if perms.get("pull-requests") != "read" or perms.get("contents") != "read" or len(perms) != 2:
        bad.append(f"lint.yml: the gate job's permissions must be contents: read, pull-requests: read, got {perms}")
    runs = " ".join(s.get("run", "") for s in job["steps"])
    if "build-inputs-need-vm-test.py" not in runs or "--pr" not in runs:
        bad.append("lint.yml: the gate job does not run the gate script with --pr")
build = yaml.safe_load(open(f"{root}/.github/workflows/build.yml"))
bon = build.get("on") or build.get(True)
if set(bon["pull_request"].get("types") or []) != {"labeled", "synchronize"}:
    bad.append("build.yml: pull_request types must be [labeled, synchronize] (the label starts the build)")
if "vm-test" not in str(build["jobs"]["build_push"].get("if", "")):
    bad.append("build.yml: build_push does not key on the vm-test label")
ignored = set(bon["push"].get("paths-ignore") or []) | set(bon["pull_request"].get("paths-ignore") or [])
sys.path.insert(0, f"{root}/.github/scripts")
import importlib.util
spec = importlib.util.spec_from_file_location("gate", f"{root}/.github/scripts/build-inputs-need-vm-test.py")
gate = importlib.util.module_from_spec(spec); spec.loader.exec_module(gate)
for pattern in gate.BUILD_INPUTS:
    probe = pattern.replace("/**", "/x/y")
    for ig in ignored:
        if gate.fnmatch.fnmatchcase(probe, ig.replace("/**", "/*/*")) or ig == pattern:
            bad.append(f"build.yml ignores {ig}, which the gate treats as a build input ({pattern})")
renovate = open(f"{root}/.github/renovate.json5").read()
rule = re.search(r"matchFileNames:\s*\[(.*?)\][^}]*addLabels:\s*\[\s*'vm-test'", renovate, re.S)
listed = set(re.findall(r"'([^']+)'", rule.group(1))) if rule else set()
for pattern in gate.BUILD_INPUTS:
    if pattern not in listed:
        bad.append(f"renovate.json5: {pattern} is not in the vm-test addLabels rule (a Renovate PR there would be blocked by the gate)")
print("\n".join(bad) or "wiring OK")
sys.exit(1 if bad else 0)
PY
check "lint.yml, build.yml and renovate.json5 agree with the gate" [ "$RC" = 0 ]

if (( fails )); then echo "$fails vm-test-gate case(s) failed"; exit 1; fi
echo "all vm-test-gate cases passed"
