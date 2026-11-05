#!/usr/bin/env bash
# /usr/libexec/lucciola/update-state on fakes: rpm-ostree, systemctl (both
# managers) and journalctl answer from files. Covered: the JSON shape, the
# staged and booted versions, a running transaction, the three channels
# with their outcomes, the failed one with the journal's reason and the
# count, a night failure a newer image has settled, nothing failed, tools
# missing. Needs python3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
US="$ROOT/build_files/system_files/usr/libexec/lucciola/update-state"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 12; fails=$((fails+1)); fi; }
mkdir -p "$T/bin"
cat > "$T/bin/rpm-ostree" <<'SH'
#!/bin/sh
cat "$FAKE/status.json"
SH
cat > "$T/bin/systemctl" <<'SH'
#!/bin/sh
scope=system; [ "$1" = "--user" ] && { scope=user; shift; }
case "$1" in
  show) cat "$FAKE/show-$scope.txt" ;;
  list-timers) cat "$FAKE/timers-$scope.json" ;;
  *) exit 1 ;;
esac
SH
cat > "$T/bin/journalctl" <<'SH'
#!/bin/sh
scope=system; [ "$1" = "--user" ] && scope=user
unit=""; while [ $# -gt 0 ]; do [ "$1" = "-u" ] && unit="$2"; shift; done
cat "$FAKE/journal-$scope-$unit.txt" 2>/dev/null
SH
chmod +x "$T/bin/"*
export FAKE="$T/fake"; mkdir -p "$FAKE"
run() { RC=0; env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" FAKE="$FAKE" python3 -I "$US" "$@" > "$T/out" 2>&1 || RC=$?; }
field() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$T/out" "$1"; }

# A staged update, uupd failed on a distrobox, the rest fine.
cat > "$FAKE/status.json" <<'J'
{"transaction": null, "deployments": [
  {"staged": true, "version": "candidate.20261101", "checksum": "80bb", "base-commit-meta": {"ostree.manifest-digest": "sha256:new"}},
  {"booted": true, "version": "candidate.20261024", "checksum": "be94", "container-image-reference": "ostree-image-signed:docker://ghcr.io/daniel-g-carrasco/lucciola:candidate",
   "base-commit-meta": {"ostree.manifest-digest": "sha256:old"}}]}
J
cat > "$FAKE/show-system.txt" <<'S'
Id=uupd.service
ActiveState=failed
Result=start-limit-hit
ExecMainStartTimestamp=@1793528407
ExecMainExitTimestamp=@1793528427

Id=margine-flatpak-update.service
ActiveState=inactive
Result=success
ExecMainStartTimestamp=@1793525929
ExecMainExitTimestamp=@1793525930
S
cat > "$FAKE/show-user.txt" <<'S'
Id=margine-flatpak-user-update.service
ActiveState=inactive
Result=success
ExecMainExitTimestamp=@1793468405

Id=margine-brew-upgrade.service
ActiveState=inactive
Result=success
ExecMainExitTimestamp=@1793530345
S
echo '[{"next":1793589132825035,"last":1793525929510372,"unit":"uupd.timer"},{"next":1793547961795608,"last":1793525929511996,"unit":"margine-flatpak-update.timer"}]' > "$FAKE/timers-system.json"
echo '[{"next":1794133559239308,"last":1793527866158042,"unit":"margine-brew-upgrade.timer"},{"next":1793549567515156,"last":1793468405576124,"unit":"margine-flatpak-user-update.timer"}]' > "$FAKE/timers-user.json"
cat > "$FAKE/journal-system-uupd.service.txt" <<'L'
{"level":"INFO","msg":"Updating","title":"System"}
{"level":"ERROR","msg":"module_fail","output":{"Stdout":"\u001b[1;31m Upgrading box...\n\u001b[0m\u001b[31m Error: could not start entrypoint.\n\u001b[0m\n","Failure":true,"Stderr":null,"Context":"Distroboxes for User: daniel"},"module":"Distroboxes for User: daniel"}
{"level":"ERROR","msg":"Updates finished with errors!"}
L
run --json
check "runs (rc $RC)" [ "$RC" = 0 ]
check "booted and staged versions" [ "$(field 'd["booted"] + " " + d["staged"]')" = "candidate.20261024 candidate.20261101" ]
check "no transaction" [ "$(field 'd["transaction"]')" = "" ]
check "one failed channel" [ "$(field 'd["failed"]')" = 1 ]
check "three channels in order" [ "$(field '[c["key"] for c in d["channels"]]')" = "['system', 'apps', 'tools']" ]
check "system failed on uupd with the journal's reason" [ "$(field 'd["channels"][0]["outcome"] + "|" + d["channels"][0]["unit"] + "|" + d["channels"][0]["reason"]')" = "failed|uupd.service|Distroboxes for User: daniel: Error: could not start entrypoint." ]
check "the line carries the reason and the next try" bash -c "[[ \"$(field 'd["channels"][0]["line"]')\" == Failed*'Distroboxes for User: daniel: Error: could not start entrypoint. Next try '* ]]"
check "apps and tools ok" [ "$(field 'd["channels"][1]["outcome"] + d["channels"][2]["outcome"]')" = "okok" ]
check "no log in the output" bash -c "! grep -q '\"log\"' '$T/out'"
check "checked is now-ish" [ "$(field 'abs(d["checked"] - __import__("time").time()) < 120')" = True ]

# A running transaction, nothing failed, nothing staged.
cat > "$FAKE/status.json" <<'J'
{"transaction": ["Upgrade", ":1.9", "/org/projectatomic/rpmostree1/default"], "deployments": [
  {"booted": true, "version": "candidate.20261101", "checksum": "80bb", "base-commit-meta": {"ostree.manifest-digest": "sha256:new"}}]}
J
sed -i 's/ActiveState=failed/ActiveState=inactive/; s/Result=start-limit-hit/Result=success/' "$FAKE/show-system.txt"
run --json
check "transaction named" [ "$(field 'd["transaction"]')" = "Upgrade" ]
check "nothing staged, nothing failed" [ "$(field 'str(d["staged"]) + str(d["failed"])')" = "None0" ]

# A hung user unit (killed on timeout) counts as failed, with the user journal.
printf 'Id=margine-brew-upgrade.service\nActiveState=failed\nResult=timeout\nExecMainStartTimestamp=@1793530000\nExecMainExitTimestamp=@1793531800\n' > "$FAKE/show-user.txt"
printf '==> Upgrading node\nError: No developer tools installed.\nbrew upgrade reported errors\n' > "$FAKE/journal-user-margine-brew-upgrade.service.txt"
run --json
check "hung tools unit counted and explained" [ "$(field 'd["channels"][2]["outcome"] + "|" + str(d["channels"][2]["user"]) + "|" + d["channels"][2]["reason"]')" = "hung|True|Error: No developer tools installed." ]
check "failed count includes the hung one" [ "$(field 'd["failed"]')" = 1 ]

# 2026-11-05: the night's run failed on the system step alone, the window's
# update succeeded in the evening and the newer image was booted: the
# failure is settled, neither counted nor notified. An older image is not.
printf 'Id=margine-brew-upgrade.service\nActiveState=inactive\nResult=success\nExecMainExitTimestamp=@1793530345\n' > "$FAKE/show-user.txt"
printf 'Id=uupd.service\nActiveState=failed\nResult=exit-code\nExecMainStartTimestamp=@1793848300\nExecMainExitTimestamp=@1793848536\n' > "$FAKE/show-system.txt"
cat > "$FAKE/journal-system-uupd.service.txt" <<'L'
{"level":"INFO","msg":"Hardware checks passed"}
{"level":"ERROR","msg":"module_fail","module":"system","context":"System Update","output":"error: Could not depsolve transaction; 1 problem detected"}
{"level":"ERROR","msg":"Updates finished with errors!"}
{"level":"ERROR","msg":"1 update module(s) failed: System Update"}
L
cat > "$FAKE/status.json" <<'J'
{"transaction": null, "deployments": [
  {"booted": true, "version": "lucciola.20261105", "checksum": "28bf", "base-timestamp": 1793887356, "timestamp": 1793909686,
   "base-commit-meta": {"ostree.manifest-digest": "sha256:4aff"}},
  {"version": "candidate.20261104", "checksum": "7046", "base-timestamp": 1793771272, "timestamp": 1793778207}]}
J
run --json
check "a newer image booted after a failed system step: superseded, not counted" [ "$(field 'd["channels"][0]["outcome"] + "|" + str(d["failed"])')" = "superseded|0" ]
check "and the line says so" bash -c "[[ \"$(field 'd["channels"][0]["line"]')\" == 'The run '*' failed, a newer version has arrived since'* ]]"
sed -i 's/"base-timestamp": 1793887356/"base-timestamp": 1793800000/' "$FAKE/status.json"
run --json
check "an image built before the run: still failed" [ "$(field 'd["channels"][0]["outcome"] + "|" + str(d["failed"])')" = "failed|1" ]

# Tools failing (a machine without rpm-ostree, a manager that does not
# answer): still JSON, channels never ran.
printf '#!/bin/sh\nexit 1\n' > "$T/bin/systemctl"; cp "$T/bin/systemctl" "$T/bin/rpm-ostree"
run --json
check "without rpm-ostree and systemctl: still answers (rc $RC)" [ "$RC" = 0 ]
check "then nothing is known" [ "$(field 'str(d["booted"]) + str(d["failed"]) + d["channels"][0]["outcome"]')" = "None0never" ]
run --help; check "an unknown argument is refused (rc $RC)" [ "$RC" = 2 ]

echo; [ "$fails" = 0 ] && echo "update-state: all checks passed" || { echo "update-state: $fails failed"; exit 1; }
