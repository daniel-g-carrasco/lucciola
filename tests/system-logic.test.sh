#!/usr/bin/env bash
# Lucciola System without a display: the toolkit-free module's tests
# (tests/system-logic.test.py), the privileged helper's argument checks
# (/usr/libexec/lucciola/admin --check), its polkit policy (one action per
# verb, matched on the helper's path and first argument; *-status verbs free
# for an active user, every other verb auth_admin_keep), and the window's
# script: compiles, keeps its strings free of long dashes and terminal
# commands, runs pkexec on the helper alone. Needs python3 and xmllint.
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

# The helper: plans without root.
plan() { python3 -I "$ADMIN" --check "$@" > "$T/out" 2>&1 && RC=0 || RC=$?; }
plan update;                      check "update plans system-update (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/margine/system-update' '$T/out'"
plan rollback;                    check "rollback plans rpm-ostree rollback (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx 'rpm-ostree rollback' '$T/out'"
plan flatpak-unblock com.example.App; check "flatpak-unblock: unmask, update, record (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && grep -qx 'flatpak mask --remove com.example.App' '$T/out' && grep -qx 'flatpak update -y --noninteractive com.example.App' '$T/out'"
plan kernel fedora;               check "kernel fedora: CONFIRM=yes, no prompt (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx 'CONFIRM=yes /usr/libexec/margine/kernel-switch fedora' '$T/out'"
plan tpm-unlock-status;           check "tpm-unlock-status plans the helper's status (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/bin/lucciola-tpm-unlock status' '$T/out'"
plan tpm-unlock-enable;           check "tpm-unlock-enable: PCR 7, passphrase in a root-only file, never argv (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && grep -q 'root-only file' '$T/out' && grep -q 'lucciola-tpm-unlock enable 7\$' '$T/out' && ! grep -q 'LUCCIOLA_UNLOCK_KEY_FILE=' '$T/out'"
plan tpm-unlock-enable 7+14;      check "tpm-unlock-enable with PCRs 7+14 (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -q 'enable 7+14\$' '$T/out'"
plan tpm-unlock-disable;          check "tpm-unlock-disable (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -q 'lucciola-tpm-unlock disable' '$T/out'"
plan grub-lock-status;            check "grub-lock-status (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/margine/grub-lock status' '$T/out'"
plan grub-lock-on;                check "grub-lock-on: password on stdin twice, never argv (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -q 'password on stdin, twice' '$T/out'"
plan grub-lock-off;               check "grub-lock-off (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/margine/grub-lock off' '$T/out'"
plan autologin-on;                check "autologin-on names the invoking user (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx \"/usr/bin/lucciola-autologin on $(id -un)\" '$T/out'"
plan autologin-off;               check "autologin-off (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/bin/lucciola-autologin off' '$T/out'"
plan secureboot-enroll;           check "secureboot-enroll: switch file away, enroll, timeout (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && grep -qx 'rm -f /etc/margine/secureboot-enroll' '$T/out' && grep -qx '/usr/libexec/margine/mok-enroll enroll' '$T/out' && grep -qx 'mokutil --timeout -1' '$T/out'"
plan secureboot-never;            check "secureboot-never: writes off, revokes (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -q \"write '/etc/margine/secureboot-enroll': 'off\" '$T/out' && grep -qx 'mokutil --revoke-import' '$T/out'"
plan scheduler lavd Gaming;       check "scheduler: one mode, both spellings (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/margine/scheduler-apply lavd Gaming gaming' '$T/out'"
plan scheduler lavd;              check "scheduler: Auto by default (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/margine/scheduler-apply lavd Auto auto' '$T/out'"
plan scheduler-off;               check "scheduler-off (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/margine/scheduler-apply off' '$T/out'"
for bad in "flatpak-unblock" "flatpak-unblock a b" "flatpak-unblock 'x; rm -rf /'" "flatpak-unblock ../etc" "flatpak-unblock -y" \
           "update now" "rollback --force" "reboot" "--check" "kernel" "kernel foo" "kernel fedora now" \
           "tpm-unlock-enable '7;8'" "tpm-unlock-enable 7 8" "tpm-unlock-enable ../x" "grub-lock-on pw" "grub-lock-off x" \
           "autologin-on bob" "autologin-off x" "secureboot-enroll x" "scheduler" "scheduler lavd Turbo" "scheduler 'x;y' Auto" "scheduler LAVD" "scheduler-off x"; do
  eval "python3 -I '$ADMIN' --check $bad" > "$T/out" 2>&1 && RC=0 || RC=$?
  check "admin refuses: $bad (rc $RC)" [ "$RC" != 0 ]
done
python3 -I "$ADMIN" update > "$T/out" 2>&1 && RC=0 || RC=$?
check "admin without root refuses to act (rc $RC)" bash -c "[ '$RC' != 0 ] && grep -q 'must run as root' '$T/out'"
check "admin never calls a shell" bash -c "! grep -E 'shell=True|os\.system|subprocess\.(call|Popen)\(.*\"' '$ADMIN'"
check "admin reads secrets from stdin, never argv" bash -c "grep -q 'sys.stdin.readline' '$ADMIN' && ! grep -qE 'argv.*(password|passphrase)' '$ADMIN'"

# The policy: one action per verb, each matched on path + argv1; *-status free for an active user.
xmllint --noout "$POLICY" > "$T/out" 2>&1 && RC=0 || RC=$?
check "policy is well-formed XML (rc $RC)" [ "$RC" = 0 ]
verbs="$( (python3 -I "$ADMIN" 2>&1 || true) | grep -E '^  [a-z]' | tr -d ' ' | sort)"
check "the helper lists its verbs" [ -n "$verbs" ]
for v in $verbs; do
  check "policy: '$v' has its action, argv1 and the right defaults" \
    bash -c "python3 - '$POLICY' '$v' <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot(); verb = sys.argv[2]
read_only = verb.endswith('-status')
for a in root.iter('action'):
    ann = {x.get('key'): x.text for x in a.iter('annotate')}
    if a.get('id') == f'dev.lucciola.admin.{verb}' and ann.get('org.freedesktop.policykit.exec.path') == '/usr/libexec/lucciola/admin' and ann.get('org.freedesktop.policykit.exec.argv1') == verb:
        d = a.find('defaults')
        want = ('no', 'no', 'yes') if read_only else ('auth_admin', 'auth_admin', 'auth_admin_keep')
        got = (d.find('allow_any').text, d.find('allow_inactive').text, d.find('allow_active').text)
        assert got == want, f'defaults {got} != {want}'
        assert a.find('message').text.strip() and a.find('description').text.strip(), 'message'
        sys.exit(0)
sys.exit(1)
PY"
done
check "policy has no action the helper lacks" \
  bash -c "diff <(grep -oE 'action id=\"dev.lucciola.admin.[a-z-]+\"' '$POLICY' | sed 's/.*admin\.//; s/\"//' | sort) <(echo \"$verbs\")"
check "the old pkexec rule with the over-wide cache is gone" \
  bash -c "[ ! -e '$SF/usr/share/polkit-1/rules.d/49-margine-scheduler.rules' ] && [ ! -e '$ROOT/.github/security-baseline/configs/usr/share/polkit-1/rules.d/49-margine-scheduler.rules' ]"
check "no other polkit rule relaxes org.freedesktop.policykit.exec" \
  bash -c "! grep -rl 'org.freedesktop.policykit.exec' '$SF/usr/share/polkit-1/rules.d' 2>/dev/null | grep -q ."

# The helpers' non-interactive switches the dispatcher relies on.
check "kernel-switch honours CONFIRM=yes" grep -q 'CONFIRM:-}" == yes' "$SF/usr/libexec/margine/kernel-switch"
check "tpm-unlock takes the passphrase from a key file" grep -q 'LUCCIOLA_UNLOCK_KEY_FILE' "$SF/usr/bin/lucciola-tpm-unlock"
check "grub-lock reads the password from stdin when not a terminal" grep -q 'read -r p1; read -r p2' "$SF/usr/libexec/margine/grub-lock"
check "lucciola-keyring reads the password from stdin when not a terminal" grep -q 'IFS= read -r pw1' "$SF/usr/bin/lucciola-keyring"
check "the ujust scheduler recipe goes through the dispatcher" bash -c "grep -q 'lucciola/admin scheduler \"\$MODE\" Auto' '$ROOT/build_files/60-custom.just' && grep -q 'lucciola/admin scheduler-off' '$ROOT/build_files/60-custom.just' && ! grep -q 'sudo /usr/libexec/margine/scheduler-apply' '$ROOT/build_files/60-custom.just'"

# The window's script: compiles, imports the module from its installed path, no long dashes, no commands in its strings.
python3 -I -m py_compile "$GUI" > "$T/out" 2>&1 && RC=0 || RC=$?
check "system-gui compiles (rc $RC)" [ "$RC" = 0 ]
check "system-gui uses the toolkit-free module" grep -q "/usr/share/lucciola/system" "$GUI"
check "system-gui runs privileged actions through the helper only" bash -c "! grep -E 'pkexec\", *\"/usr/(bin|libexec/margine)' '$GUI' && grep -q 'pkexec' '$GUI'"
check "no long dash in the window's strings" bash -c "! grep -q \$'\\u2014' '$GUI' && ! grep -q '\\\\u2014' '$GUI'"
check "no terminal command in the window's strings" bash -c "! grep -E '\"[^\"]*(ujust |rpm-ostree |flatpak |systemctl |scxctl )[^\"]*\"' '$GUI' | grep -vE '^\s*#|\[\"|subprocess|argv|run\(' | grep -q ."
check "no deprecated dim-label style" bash -c "! grep -q 'dim-label' '$GUI'"
check "Help, shortcuts and Report a Problem are in the menu" bash -c "grep -q '\"win.help\"' '$GUI' && grep -q '\"win.shortcuts\"' '$GUI' && grep -q '\"win.report\"' '$GUI'"
check "the pages exist" bash -c "grep -q '\"startup\"' '$GUI' && grep -q '\"login\"' '$GUI' && grep -q '\"hardware\"' '$GUI'"
check "the scheduler page never asks scxctl for the status" bash -c "! grep -E '\"scxctl\", *\"get\"' '$GUI' | grep -q ."
check "the old scheduler picker is gone, its launcher opens the page" \
  bash -c "[ ! -e '$SF/usr/libexec/margine/scheduler-picker' ] && grep -q 'system-gui --page hardware' '$SF/usr/share/applications/margine-scheduler.desktop'"

[ "$fails" = 0 ] && echo "system: all checks passed" || { echo "system: $fails failed"; exit 1; }
