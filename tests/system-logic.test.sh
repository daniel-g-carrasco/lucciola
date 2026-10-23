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
# The optional features, the app profiles and the maintenance verbs: one
# definition in /usr/libexec/lucciola/feature (and printers-repair), reached
# through fixed argument vectors.
for f in gaming gaming-native ai devmode vscode devtools docker tailscale vm sunshine phone; do
  plan "$f-on";  check "$f-on plans the feature helper (rc $RC)"  bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/lucciola/feature $f install' '$T/out'"
  plan "$f-off"; check "$f-off plans the feature helper (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/lucciola/feature $f remove' '$T/out'"
done
plan ai-on amd;                   check "ai-on amd: the ROCm plugin as the one option (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/lucciola/feature ai install amd' '$T/out'"
plan apps-slim;                   check "apps-slim (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/lucciola/feature slim install' '$T/out'"
plan apps-naked;                  check "apps-naked (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/lucciola/feature naked install' '$T/out'"
plan apps-restore;                check "apps-restore brings the stock set back (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/lucciola/feature slim remove' '$T/out'"
plan brew-remove;                 check "brew-remove runs devmode without sudo inside (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx 'MARGINE_SUDO= /usr/libexec/margine/devmode brew-remove' '$T/out'"
plan printers-repair;             check "printers-repair (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/lucciola/printers-repair' '$T/out'"
plan dock-wake;                   check "dock-wake forces the rescue (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '/usr/libexec/margine/dock-dp-rescue --force' '$T/out'"
plan dock-rescue off;             check "dock-rescue off writes the switch (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -q \"write '/etc/margine/dock-dp-rescue': 'off\" '$T/out'"
for bad in "ai-on nvidia" "gaming-on now" "dock-rescue maybe" "apps-slim please" "flatpak-unblock" "flatpak-unblock a b" "flatpak-unblock 'x; rm -rf /'" "flatpak-unblock ../etc" "flatpak-unblock -y" \
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
# The feature helper: no prompt, no advice, root checked, every feature known.
FEAT="$SF/usr/libexec/lucciola/feature"
check "feature helper never prompts" bash -c "! grep -qE 'read -r?p' '$FEAT'"
check "feature helper refuses install/remove without root" bash -c "grep -q 'need_root' '$FEAT'"
bash -n "$FEAT" > "$T/out" 2>&1 && RC=0 || RC=$?
check "feature helper parses (rc $RC)" [ "$RC" = 0 ]
for f in gaming gaming-native ai devmode vscode devtools docker tailscale vm sunshine phone slim naked; do
  check "feature helper knows $f" bash -c "grep -qE '^${f//-/_}_status\(\)' '$FEAT'"
done
"$FEAT" nothing status > "$T/out" 2>&1 && RC=0 || RC=$?
check "feature helper refuses an unknown feature (rc $RC)" [ "$RC" != 0 ]
check "the phone layer's list names the packages the recipe explains" bash -c "grep -qx kdeconnectd '$ROOT/build_files/60-ujust-services/phone-packages.txt' && grep -qx fuse-sshfs '$ROOT/build_files/60-ujust-services/phone-packages.txt'"
check "the indicator's autostart entry runs kdeconnect-indicator" grep -qx 'Exec=kdeconnect-indicator' "$SF/usr/share/lucciola/phone/org.kde.kdeconnect.nonplasma.desktop"
check "printers-repair never prompts" bash -c "! grep -qE 'read -r?p' '$SF/usr/libexec/lucciola/printers-repair'"
# The recipes explain and ask, then go through the dispatcher: no second definition.
JUST="$ROOT/build_files/60-custom.just"
recipe_body() { awk -v r="$1" '$0 ~ "^" r "( |:)" {on=1; next} on && /^[^ \t]/ {on=0} on' "$JUST"; }
for pair in "lucciola-gaming:gaming-on" "lucciola-gaming-remove:gaming-off" "lucciola-gaming-native:gaming-native-on" "lucciola-gaming-native-remove:gaming-native-off" \
            "lucciola-ai:ai-on" "lucciola-ai-remove:ai-off" "lucciola-slim:apps-slim" "lucciola-naked:apps-naked" "lucciola-slim-restore:apps-restore" \
            "lucciola-printers-repair:printers-repair" "lucciola-dock-wake:dock-wake" "lucciola-dock-rescue:dock-rescue" \
            "lucciola-docker:docker-on" "lucciola-tailscale:tailscale-on" "lucciola-vscode:vscode-on" "lucciola-devtools:devtools-on" "lucciola-vm:vm-on" \
            "lucciola-devmode:devmode-on" "lucciola-sunshine:sunshine-on" "lucciola-sunshine-remove:sunshine-off" "lucciola-update-unblock:flatpak-unblock" "lucciola-phone:phone-on"; do
  recipe="${pair%%:*}"; verb="${pair##*:}"
  recipe_body "$recipe" > "$T/out"
  check "recipe $recipe goes through the dispatcher ($verb)" grep -q "lucciola/admin $verb" "$T/out"
done
check "no recipe layers or unlayers packages on its own any more" \
  bash -c "! grep -nE '^\s+sudo rpm-ostree (install|uninstall|override)' '$JUST' | grep -q ."
check "no recipe installs or removes system Flatpaks on its own any more" \
  bash -c "! grep -nE '^\s+sudo flatpak (install|uninstall)' '$JUST' | grep -q ."
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
check "the pages exist" bash -c "grep -q '\"startup\"' '$GUI' && grep -q '\"login\"' '$GUI' && grep -q '\"hardware\"' '$GUI' && grep -q '\"features\"' '$GUI' && grep -q '\"apps\"' '$GUI' && grep -q '\"phone\"' '$GUI'"
check "a page shown again within half a minute keeps what it has" bash -c "grep -q '^PAGE_KEEPS_FOR = 30' '$GUI' && grep -q 'self._page_refreshed.get(page_id, 0.0) > PAGE_KEEPS_FOR' '$GUI'"
check "a phone's card stays open across the refresh every action ends in" bash -c "grep -q 'row.set_expanded(device\\[\"id\"\\] in self._phone_expanded)' '$GUI' && grep -q 'def _on_phone_card_expanded' '$GUI'"
check "the camera rows sit with the phone's actions, above the switches" bash -c "awk '/Browse the Phone in Files/{b=NR} /self._add_camera_rows\\(row, device\\)/{c=NR} /for plugin, title, blurb, enabled in device/{f=NR} END{exit !(b && c && f && b < c && c < f)}' '$GUI'"
check "under niri a folder opens in Files: niri takes GNOME's default applications" bash -c "[ \"\$(readlink '$ROOT/lucciola/system_files/usr/share/applications/niri-mimeapps.list')\" = gnome-mimeapps.list ]"
check "niri-session hands the environment over without the import-environment warning (build 2a)" bash -c "grep -q 'dbus-update-activation-environment --systemd --all' '$ROOT/lucciola/build.sh' && grep -q 'ddcutil dbus-tools' '$ROOT/lucciola/build.sh'"
check "the Phone page talks to the daemon by its bus name and never runs kdeconnect-cli" bash -c "grep -q 'KDEC_BUS = \"org.kde.kdeconnect\"' '$GUI' && ! grep -q 'kdeconnect-cli' '$GUI'"
check "the Phone page writes Lucciola's default (notifications to the phone off) through the daemon" grep -q 'PHONE_DEFAULT_OFF' "$GUI"
# The phone as a webcam lives in the Phone page now: the old window is gone,
# its launcher opens the page, the camera runs scrcpy and adb by path as the
# user, and the microphone goes through pw-loopback (pactl is not in the image).
check "the separate Phone Camera window is gone" [ ! -e "$SF/usr/libexec/margine/phone-cam-gui" ]
check "the Phone Camera launcher opens the Phone page" bash -c "grep -qx 'Exec=/usr/libexec/margine/system-gui --page phone' '$SF/usr/share/applications/dev.margine.PhoneCam.desktop' && grep -qx 'StartupWMClass=dev.margine.System' '$SF/usr/share/applications/dev.margine.PhoneCam.desktop'"
check "the camera drives scrcpy's server itself and lands in PipeWire, by path" bash -c "grep -q 'ADB = \"/usr/bin/adb\"' '$GUI' && grep -q 'QRENCODE = \"/usr/bin/qrencode\"' '$GUI' && grep -q 'pipewiresink name=pw mode=provide' '$GUI' && grep -q 'server_command' '$GUI' && ! grep -q 'pactl' '$GUI' && ! grep -q 'pw-loopback' '$GUI'"
check "the camera keeps its PipeWire node while the phone reconnects, lists sizes without the scrcpy client, never wakes the screen" bash -c "grep -q 'intervideosink' '$GUI' && grep -q 'intervideosrc' '$GUI' && grep -q 'interaudiosrc' '$GUI' && grep -q 'RECONNECT_SECONDS' '$GUI' && grep -q 'def set_facing' '$GUI' && ! grep -q 'list-camera-sizes' '$GUI' && ! grep -q 'KEYCODE_WAKEUP' '$GUI'"
check "the PipeWire node flows with no app linked (async off) and keeps flowing to apps (no pool lent upstream), the preview and the V4L2 copy has its own pipeline, the app lets the phone go when it quits" bash -c "[ \$(grep -c 'identity drop-allocation=true ! pipewiresink name=pw mode=provide async=false' '$GUI') -eq 2 ] && grep -q 'def _open_loopback' '$GUI' && grep -q 'def preview_paintable' '$GUI' && [ \$(grep -c gtk4paintablesink '$GUI') -eq 1 ] && grep -q 'v4l2sink device={device}' '$GUI' && ! grep -q 'intervideosink channel={ch}-v4l2 sync=false.*v4l2sink' '$GUI' && grep -q 'def do_shutdown' '$GUI' && grep -q 'cam.stop(wait=True)' '$GUI'"
check "the camera dialog turns the picture (Rotate, from the sensor's orientation), keeps the resolution while streaming, offers webcam sizes and spaces the preview" bash -c "grep -q 'def _on_rotate' '$GUI' && grep -q 'def set_view' '$GUI' && grep -q 'dumpsys\", \"media.camera' '$GUI' && grep -q 'Stop the camera to change it' '$GUI' && grep -q 'ls.webcam_sizes' '$GUI' && grep -q 'self._picture.set_margin_top' '$GUI'"
check "a slow first frame keeps its connection, the watchdog counts bytes from the phone, the software decoder holds no frames back" bash -c "grep -q 'connected, the camera is still starting' '$GUI' && grep -q 'fdsrc fd={fd} ! identity name=watch ! h264parse' '$GUI' && grep -q 'max-threads\", 1' '$GUI'"
check "the camera always constrains the size and the stream is raw, without control" bash -c "grep -q 'camera_size=' '$SF/usr/share/lucciola/system/lucciola_system.py' && grep -q 'raw_stream=true' '$SF/usr/share/lucciola/system/lucciola_system.py' && grep -q 'control=false' '$SF/usr/share/lucciola/system/lucciola_system.py'"
check "the loopback device is a bonus, never a requirement" bash -c "grep -q 'if device:' '$GUI' && ! grep -q 'button_row(expander, \"Register' '$GUI'"
check "wireless pairing takes the code as an argument, never typed into adb" bash -c "grep -q 'ADB, \"pair\", f\"{h}:{p}\", c' '$GUI' && grep -q 'ADB, \"pair\", f\"{service\[.host.\]}:{service\[.port.\]}\", password' '$GUI'"
check "the QR code carries the payload the phone expects" grep -q 'qr_pairing_payload' "$GUI"
for k in $(grep -oE '"key": "[a-z-]+"' "$GUI" | cut -d'"' -f4); do
  check "the window's feature '$k' has its verbs in the helper" bash -c "echo \"$verbs\" | grep -qx '$k-on' && echo \"$verbs\" | grep -qx '$k-off'"
done
check "the window runs the user-level recipes through ujust by path, never a shell" bash -c "grep -q 'UJUST = \"/usr/bin/ujust\"' '$GUI' && ! grep -q 'shell=True' '$GUI'"
check "the scheduler page never asks scxctl for the status" bash -c "! grep -E '\"scxctl\", *\"get\"' '$GUI' | grep -q ."
check "the old scheduler picker is gone, its launcher opens the page" \
  bash -c "[ ! -e '$SF/usr/libexec/margine/scheduler-picker' ] && grep -q 'system-gui --page hardware' '$SF/usr/share/applications/margine-scheduler.desktop'"

[ "$fails" = 0 ] && echo "system: all checks passed" || { echo "system: $fails failed"; exit 1; }
