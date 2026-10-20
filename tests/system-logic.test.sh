#!/usr/bin/env bash
# Lucciola System without a display: the toolkit-free module's tests
# (tests/system-logic.test.py), the privileged helper's argument checks
# (/usr/libexec/lucciola/admin --check), its polkit policy (one action per
# verb, matched on the helper's path and first argument), and the window's
# script compiles and keeps its strings free of long dashes and terminal
# commands. Needs python3 and xmllint (libxml2).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SF="$ROOT/build_files/system_files"
ADMIN="$SF/usr/libexec/lucciola/admin"
GUI="$SF/usr/libexec/margine/system-gui"
POLICY="$SF/usr/share/polkit-1/actions/dev.lucciola.admin.policy"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 12 || true; fails=$((fails+1)); fi
}

python3 -I "$ROOT/tests/system-logic.test.py" > "$T/out" 2>&1 && RC=0 || RC=$?
check "toolkit-free module (rc $RC)" [ "$RC" = 0 ]
check "toolkit-free module: no FAIL line" bash -c "! grep -q '^FAIL' '$T/out'"

# The helper: validation without root.
python3 -I "$ADMIN" --check update > "$T/out" 2>&1 && RC=0 || RC=$?
check "admin --check update plans system-update (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/margine/system-update' '$T/out'"
python3 -I "$ADMIN" --check rollback > "$T/out" 2>&1 && RC=0 || RC=$?
check "admin --check rollback plans rpm-ostree rollback (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx 'rpm-ostree rollback' '$T/out'"
python3 -I "$ADMIN" --check flatpak-unblock com.example.App > "$T/out" 2>&1 && RC=0 || RC=$?
check "admin --check flatpak-unblock: unmask, update, record (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && grep -qx 'flatpak mask --remove com.example.App' '$T/out' && grep -qx 'flatpak update -y --noninteractive com.example.App' '$T/out'"
for bad in "flatpak-unblock" "flatpak-unblock a b" "flatpak-unblock 'x; rm -rf /'" "flatpak-unblock ../etc" "flatpak-unblock -y" "update now" "rollback --force" "reboot" "--check" ; do
  # shellcheck disable=SC2086
  eval "python3 -I '$ADMIN' --check $bad" > "$T/out" 2>&1 && RC=0 || RC=$?
  check "admin refuses: $bad (rc $RC)" [ "$RC" != 0 ]
done
python3 -I "$ADMIN" update > "$T/out" 2>&1 && RC=0 || RC=$?
check "admin without root refuses to act (rc $RC)" bash -c "[ '$RC' != 0 ] && grep -q 'must run as root' '$T/out'"
check "admin never calls a shell" bash -c "! grep -E 'shell=True|os\.system|subprocess\.(call|Popen)\(.*\"' '$ADMIN'"

# The policy: one action per verb, each matched on path + argv1.
xmllint --noout "$POLICY" > "$T/out" 2>&1 && RC=0 || RC=$?
check "policy is well-formed XML (rc $RC)" [ "$RC" = 0 ]
# The helper's usage (no arguments) lists its verbs and exits 1.
verbs="$( (python3 -I "$ADMIN" 2>&1 || true) | grep -E '^  [a-z]' | tr -d ' ' | sort)"
check "the helper lists its verbs" [ -n "$verbs" ]
for v in $verbs; do
  check "policy has an action for '$v' with argv1" \
    bash -c "python3 - '$POLICY' '$v' <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot(); verb = sys.argv[2]
for a in root.iter('action'):
    ann = {x.get('key'): x.text for x in a.iter('annotate')}
    if a.get('id') == f'dev.lucciola.admin.{verb}' and ann.get('org.freedesktop.policykit.exec.path') == '/usr/libexec/lucciola/admin' and ann.get('org.freedesktop.policykit.exec.argv1') == verb:
        d = a.find('defaults')
        assert d.find('allow_active').text == 'auth_admin_keep' and d.find('allow_any').text == 'auth_admin' and d.find('allow_inactive').text == 'auth_admin', 'defaults'
        assert a.find('message').text.strip(), 'message'
        sys.exit(0)
sys.exit(1)
PY"
done
check "policy has no action the helper lacks" \
  bash -c "diff <(grep -oE 'action id=\"dev.lucciola.admin.[a-z-]+\"' '$POLICY' | sed 's/.*admin\.//; s/\"//' | sort) <(echo \"$verbs\")"

# The window's script: compiles, imports the module from its installed path, no long dashes, no commands in its strings.
python3 -I -m py_compile "$GUI" > "$T/out" 2>&1 && RC=0 || RC=$?
check "system-gui compiles (rc $RC)" [ "$RC" = 0 ]
check "system-gui uses the toolkit-free module" grep -q "/usr/share/lucciola/system" "$GUI"
check "system-gui runs privileged actions through the helper only" bash -c "! grep -E 'pkexec\", *\"/usr/(bin|libexec/margine)' '$GUI' && grep -q 'pkexec' '$GUI'"
check "no long dash in the window's strings" bash -c "! grep -q \$'\\u2014' '$GUI' && ! grep -q '\\\\u2014' '$GUI'"
check "no terminal command in the window's strings" bash -c "! grep -E '\"[^\"]*(ujust |rpm-ostree |flatpak |systemctl )[^\"]*\"' '$GUI' | grep -vE '^\s*#|\[\"|subprocess|argv|run\(' | grep -q ."
check "no deprecated dim-label style" bash -c "! grep -q 'dim-label' '$GUI'"
check "Help, shortcuts and Report a Problem are in the menu" bash -c "grep -q '\"win.help\"' '$GUI' && grep -q '\"win.shortcuts\"' '$GUI' && grep -q '\"win.report\"' '$GUI'"

[ "$fails" = 0 ] && echo "system: all checks passed" || { echo "system: $fails failed"; exit 1; }
