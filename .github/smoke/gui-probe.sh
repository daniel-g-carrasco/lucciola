#!/usr/bin/env bash
# Lucciola Layer C GUI smoke probe: runs INSIDE the smoke-boot VM as a
# root oneshot (margine-gui-smoke.service), injected offline into the
# qcow2 by .github/scripts/inject-gui-probe.sh. Verdict goes to the
# serial console; the CI watcher greps for MARGINE-GUI-SMOKE: PASS/FAIL.
#
# The product under test is the Lucciola session: niri with the Noctalia
# shell, started by greetd from a password login. margine-greetd-login.service
# (greetd-login.py) runs first: greetd's autologin, a logout, the greeter, then
# a password login over greetd's IPC socket, which goes through the whole
# greetd PAM stack. This probe checks the session that login started, and
# that pam_oo7 opened the Login keyring with the password. GNOME stays in the
# image only as a stock fallback session, so nothing here looks at GNOME
# Shell any more (until 2026-10 this probe checked gnome-shell and Margine's
# extensions; until the greetd switch of 2026-10 the session came from GDM's
# autologin).
#
# Lived as a triple-escaped heredoc inside smoke-boot.yml until
# 2026-06-12: invisible to shellcheck and unrunnable locally. As a
# file it can be executed on the lab VM directly, which matters now
# that this probe is slated to become gating. By hand, against a
# session that is already logged in, without powering the machine off:
#   sudo PROBE_STDOUT=1 SMOKE_USER=<user> .github/smoke/gui-probe.sh
set -u
# Markers go to BOTH /dev/console (the watcher reads -serial) and
# /dev/kmsg: if a BLS entry lacks the serial console karg the console
# write would vanish, but kmsg is mirrored to console=ttyS0 (now forced
# by inject-gui-probe.sh), so the verdict still reaches serial.log.
# PROBE_STDOUT=1 prints instead (same knob as security-probe.sh).
out() {
  if [[ "${PROBE_STDOUT:-0}" == 1 ]]; then echo "$@"; return 0; fi
  echo "$@" > /dev/console 2>/dev/null || true
  echo "<smoke> $*" > /dev/kmsg 2>/dev/null || true
}
poweroff_vm() {
  [[ "${PROBE_STDOUT:-0}" == 1 ]] && return 0
  sleep 2
  systemctl poweroff
}

# gaming_check, then developer_check, run in the BACKGROUND (started
# below): their rpm-ostree dry runs (up to 420 s per attempt) must never
# delay the GUI verdict. wait_gaming is called before every poweroff so
# both layer verdicts are still captured, even when the GUI checks bail
# out early. Safe to call more than once.
wait_gaming() { [[ -n "${GAMING_PID:-}" ]] && wait "$GAMING_PID" 2>/dev/null || true; }
fail() { out "MARGINE-GUI-SMOKE: FAIL $*"; wait_gaming; poweroff_vm; exit 0; }

# ---- Gaming-native layer resolvability (independent of the GUI) ------------
# `ujust lucciola-gaming-native` layers a multilib RPM set whose fragile
# edge is steam's 32-bit chain: about 200 i686 packages, layered since
# 2026-10-18 together with the applications (the image no longer carries
# them), each of which must fit the x86_64 packages of the image. A
# dry-run resolves that exact transaction the way the recipe would,
# WITHOUT applying it: a depsolve failure here is the i686/x86_64 skew
# that broke `margine-gaming-native` for real. Package set is read from
# the same file the recipe installs from (no drift). A FAIL blocks
# promotion (qemu-boot-wait.sh); a missing or empty list is a FAIL too,
# since the recipe cannot run without it.
gaming_check() {
  local list=/usr/share/margine/gaming-native-packages.txt
  if [[ ! -r "$list" ]]; then
    out "MARGINE-GAMING-NATIVE: FAIL package list $list not found: ujust lucciola-gaming-native cannot run"
    return
  fi
  local pkgs
  mapfile -t pkgs < <(grep -vE '^[[:space:]]*(#|$)' "$list")
  if [[ "${#pkgs[@]}" -eq 0 ]]; then
    out "MARGINE-GAMING-NATIVE: FAIL empty package list $list"
    return
  fi
  # rpm-ostreed is dbus-activated and not reachable at the very start of
  # boot; wait for it so an unready daemon SKIPs instead of burning the
  # whole 240s budget on a spurious failure.
  local ready=
  for _ in $(seq 1 30); do
    rpm-ostree status >/dev/null 2>&1 && { ready=1; break; }
    sleep 2
  done
  [[ -n "$ready" ]] || { out "MARGINE-GAMING-NATIVE: SKIP (rpm-ostreed not ready)"; return; }
  # rpm-ostreed runs one transaction at a time and at first boot another
  # one may hold it: a busy daemon gets a few more tries, a timeout is a
  # skip (warn-only, like the other skips), and a failure carries
  # rpm-ostree's own words. The first FAIL of this probe (2026-10-10) said
  # nothing, because its message had none of the words grepped for.
  local rc attempt why
  for attempt in 1 2 3; do
    timeout 420 rpm-ostree install --dry-run "${pkgs[@]}" >/tmp/gaming.out 2>&1
    rc=$?
    if (( rc == 0 )); then
      out "MARGINE-GAMING-NATIVE: PASS (${#pkgs[@]} pkgs resolve)"
      return
    fi
    if (( rc == 124 )); then
      out "MARGINE-GAMING-NATIVE: SKIP (dry run timed out after 420 s on attempt $attempt)"
      return
    fi
    grep -qiE 'transaction in progress|busy' /tmp/gaming.out || break
    sleep 20
  done
  why="$(grep -iE 'cannot install|conflict|requires|nothing provides|depsolve|problem' /tmp/gaming.out | head -3 | tr '\n' ' ' | tr -s ' ')"
  [[ -n "$why" ]] || why="$(tail -n 3 /tmp/gaming.out | tr '\n' ' ' | tr -s ' ')"
  out "MARGINE-GAMING-NATIVE: FAIL rc=$rc free(/var)=$(df -h --output=avail /var 2>/dev/null | tail -1 | tr -d ' ') ${why}"
}

# ---- Developer layer resolvability (2026-10-18) ------------------------------
# `ujust lucciola-devmode` layers VS Code from Microsoft's repository plus
# gcc, flatpak-builder and friends from Fedora's. Same dry run as the
# gaming check, after it (rpm-ostreed runs one transaction at a time), with
# the recipe's own repository step first: `devmode repo` adds the VS Code
# repository with its key checked, and the probe removes it again
# afterwards. A refused key or a depsolve failure is a FAIL (blocks
# promotion, qemu-boot-wait.sh); a repository that does not download or a
# timeout is a SKIP: build.yml's resolve check ran before the push.
developer_check() {
  local list=/usr/share/margine/developer-packages.txt dev=/usr/libexec/margine/devmode
  if [[ ! -r "$list" || ! -x "$dev" ]]; then
    out "MARGINE-DEVELOPER-LAYER: FAIL $list or $dev not found: ujust lucciola-devmode cannot run"
    return
  fi
  local pkgs
  mapfile -t pkgs < <("$dev" packages 2>/dev/null)
  if [[ "${#pkgs[@]}" -eq 0 ]]; then
    out "MARGINE-DEVELOPER-LAYER: FAIL empty package list $list"
    return
  fi
  rpm-ostree status >/dev/null 2>&1 || { out "MARGINE-DEVELOPER-LAYER: SKIP (rpm-ostreed not ready)"; return; }
  if ! "$dev" repo >/tmp/developer-repo.out 2>&1; then
    # layer-repo says "refusing" for any refused key or repository file.
    if grep -q "refusing" /tmp/developer-repo.out; then
      out "MARGINE-DEVELOPER-LAYER: FAIL the VS Code repository key or file was refused: $(tail -n 2 /tmp/developer-repo.out | tr '\n' ' ')"
    else
      out "MARGINE-DEVELOPER-LAYER: SKIP (VS Code repository not reachable: $(tail -n 1 /tmp/developer-repo.out))"
    fi
    "$dev" repo-remove >/dev/null 2>&1 || true
    return
  fi
  local rc attempt why
  for attempt in 1 2 3; do
    # The recipe's own flags: --allow-inactive accepts a package the image
    # already ships, --idempotent one already requested.
    timeout 420 rpm-ostree install --dry-run --idempotent --allow-inactive "${pkgs[@]}" >/tmp/developer.out 2>&1
    rc=$?
    (( rc == 0 || rc == 124 )) && break
    grep -qiE 'transaction in progress|busy' /tmp/developer.out || break
    sleep 20
  done
  "$dev" repo-remove >/dev/null 2>&1 || true
  if (( rc == 0 )); then
    out "MARGINE-DEVELOPER-LAYER: PASS (${#pkgs[@]} pkgs resolve)"
  elif (( rc == 124 )); then
    out "MARGINE-DEVELOPER-LAYER: SKIP (dry run timed out after 420 s on attempt $attempt)"
  else
    why="$(grep -iE 'cannot install|conflict|requires|nothing provides|depsolve|problem|not found' /tmp/developer.out | head -3 | tr '\n' ' ' | tr -s ' ')"
    [[ -n "$why" ]] || why="$(tail -n 3 /tmp/developer.out | tr '\n' ' ' | tr -s ' ')"
    out "MARGINE-DEVELOPER-LAYER: FAIL rc=$rc ${why}"
  fi
}
{ gaming_check; developer_check; } & GAMING_PID=$!

# ---- The autologin user and its session ------------------------------------
# inject-gui-probe.sh creates "smoke" (uid 1010, home /var/home/smoke);
# SMOKE_USER points the probe at another user on a lab VM.
# greetd-login.py leaves its verdict in this file: login=pass|fail, the
# reason, and the time of the password login (since=, epoch seconds).
LOGIN_RESULT=/run/margine-smoke/greetd-login.result
SMOKE_USER="${SMOKE_USER:-smoke}"
SMOKE_UID="$(id -u "$SMOKE_USER" 2>/dev/null || echo 1010)"
SMOKE_HOME="$(getent passwd "$SMOKE_USER" 2>/dev/null | cut -d: -f6)"
[[ -n "$SMOKE_HOME" ]] || SMOKE_HOME="/var/home/$SMOKE_USER"
RUN_DIR="/run/user/${SMOKE_UID}"
NIRI_PID="" NIRI_SOCK="" WL_DISPLAY=""

# Run a command as the user, inside its session: runtime dir and session
# bus by path, and niri's IPC and Wayland sockets once they are known.
# Clients find niri through NIRI_SOCKET, and Noctalia's IPC socket is
# named after the Wayland display ($XDG_RUNTIME_DIR/noctalia-<display>.sock,
# wayland-0 when unset), so both must be the session's own.
as_user() {
  local envs=(HOME="$SMOKE_HOME" XDG_RUNTIME_DIR="$RUN_DIR"
              DBUS_SESSION_BUS_ADDRESS="unix:path=${RUN_DIR}/bus")
  [[ -n "$NIRI_SOCK" ]] && envs+=(NIRI_SOCKET="$NIRI_SOCK")
  [[ -n "$WL_DISPLAY" ]] && envs+=(WAYLAND_DISPLAY="$WL_DISPLAY")
  runuser -u "$SMOKE_USER" -- env "${envs[@]}" "$@"
}

# niri runs as the user unit niri.service (greetd -> niri-session ->
# systemctl --user start niri.service), so its MainPID is the compositor:
# `pgrep niri` alone also matches the long-lived `niri msg event-stream`
# client of /usr/libexec/lucciola/bar-widths. At startup niri publishes
# NIRI_SOCKET and WAYLAND_DISPLAY in the user manager's environment
# (import-environment, which is how D-Bus-activated services such as the
# portal reach the session); the socket file, named
# niri.<wayland display>.<pid>.sock, is the fallback.
find_niri() {
  local env_dump s
  NIRI_PID="$(as_user systemctl --user show -p MainPID --value niri.service 2>/dev/null)"
  [[ "$NIRI_PID" =~ ^[1-9][0-9]*$ ]] || NIRI_PID=""
  env_dump="$(as_user systemctl --user show-environment 2>/dev/null)"
  NIRI_SOCK="$(sed -n 's/^NIRI_SOCKET=//p' <<<"$env_dump" | head -n 1)"
  WL_DISPLAY="$(sed -n 's/^WAYLAND_DISPLAY=//p' <<<"$env_dump" | head -n 1)"
  if [[ ! -S "$NIRI_SOCK" && -n "$NIRI_PID" ]]; then
    NIRI_SOCK=""
    for s in "$RUN_DIR"/niri.*."$NIRI_PID".sock; do [[ -S "$s" ]] && NIRI_SOCK="$s"; done
  fi
  if [[ -z "$WL_DISPLAY" && -n "$NIRI_SOCK" && -n "$NIRI_PID" ]]; then
    WL_DISPLAY="${NIRI_SOCK##*/niri.}"
    WL_DISPLAY="${WL_DISPLAY%."$NIRI_PID".sock}"
  fi
}

# The last lines niri (and everything it spawned: session-start, Noctalia)
# wrote to its journal stream, for FAIL messages that explain themselves.
niri_log() {
  journalctl -b -q --no-pager -o cat _SYSTEMD_USER_UNIT=niri.service _UID="$SMOKE_UID" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | tail -n 3 | tr '\n' ' ' | cut -c1-300
}

# The user's graphical session: logind has its id, type and the PAM service
# that opened it. The session name comes from the environment the login
# screen gave the session, which niri-session imports into the user manager:
# Noctalia Greeter sets XDG_SESSION_DESKTOP to the session file's first
# DesktopNames entry (niri), GDM set it to the file's name (lucciola), and
# XDG_CURRENT_DESKTOP is DesktopNames (niri). logind's Desktop is the
# fallback (it stayed EMPTY for a GDM-started session, 2026-10-17).
session_info() {
  SID="$(loginctl show-user "$SMOKE_USER" -p Display --value 2>/dev/null)"
  S_TYPE="" S_SERVICE=""
  S_DESK="$(as_user systemctl --user show-environment 2>/dev/null | sed -n 's/^XDG_SESSION_DESKTOP=//p' | head -n 1)"
  [[ -n "$SID" ]] || return 0
  S_TYPE="$(loginctl show-session "$SID" -p Type --value 2>/dev/null)"
  S_SERVICE="$(loginctl show-session "$SID" -p Service --value 2>/dev/null)"
  [[ -n "$S_DESK" ]] || S_DESK="$(loginctl show-session "$SID" -p Desktop --value 2>/dev/null)"
}

# ---- 0. The password login through greetd ----------------------------------
# greetd-login.py ran before this probe (unit ordering). A failed login
# explains everything below, so it is the verdict.
if [[ -r "$LOGIN_RESULT" ]]; then
  LOGIN_OK="$(sed -n 's/^login=//p' "$LOGIN_RESULT")"
  LOGIN_SINCE="$(sed -n 's/^since=//p' "$LOGIN_RESULT")"
  [[ "$LOGIN_OK" == pass ]] || fail "greetd password login: $(sed -n 's/^reason=//p' "$LOGIN_RESULT" | cut -c1-400)"
else
  LOGIN_SINCE=""
  [[ "${PROBE_STDOUT:-0}" == 1 ]] || fail "no verdict from the greetd login driver ($LOGIN_RESULT missing: margine-greetd-login.service did not run?)"
fi

# ---- 1. niri started for the autologin user ---------------------------------
# First boot is slow (flatpak preinstall etc. competes for I/O).
for _ in $(seq 1 60); do
  pgrep -u "$SMOKE_USER" -x niri >/dev/null && break
  sleep 5
done
if ! pgrep -u "$SMOKE_USER" -x niri >/dev/null; then
  # Say whether the login landed in GNOME instead.
  session_info
  if pgrep -u "$SMOKE_USER" -x gnome-shell >/dev/null; then
    fail "niri never started: the login went to GNOME (session ${SID:-?} desktop=${S_DESK:-?}), not to the Lucciola session"
  fi
  fail "niri never started for $SMOKE_USER (session ${SID:-none} desktop=${S_DESK:-?} type=${S_TYPE:-?}); niri log: $(niri_log)"
fi

# ---- 2. The session is Lucciola's, on Wayland -------------------------------
# niri (Noctalia Greeter's name for the Lucciola session, from its
# DesktopNames) or lucciola (the session file's name, GDM's); gnome is the
# fallback taking over. The PAM service that opened it is greetd's: a GDM
# session here would mean greetd failed and its fallback took over.
session_info
[[ -n "$SID" ]] || fail "logind has no graphical session for $SMOKE_USER"
[[ "$S_TYPE" == wayland ]] || fail "session $SID is type=${S_TYPE:-?}, not wayland"
[[ "$S_SERVICE" == greetd ]] || fail "session $SID was opened by PAM service '${S_SERVICE:-?}', not greetd"
case "${S_DESK,,}" in
  lucciola|niri) ;;
  *) fail "session $SID desktop=${S_DESK:-?}: not the Lucciola session" ;;
esac

# ---- 3. Settle: niri's IPC, session-start, Noctalia, notifications ----------
# niri spawns /usr/libexec/lucciola/session-start at startup, which seeds
# the user's Noctalia and niri files and then execs Noctalia; Noctalia
# takes org.freedesktop.Notifications when it comes up. A bounded poll
# (not a fixed sleep) until all of it answers, then each check on its own
# so a FAIL names the first missing piece.
NOCTALIA_TOML="$SMOKE_HOME/.config/noctalia/00-lucciola.toml"
NIRI_USER_CFG="$SMOKE_HOME/.config/niri/config.kdl"
niri_ipc_ok() { as_user timeout 10 niri msg version >/tmp/niri-version.out 2>&1; }
seeded_ok() {
  grep -qF '/usr/share/lucciola/noctalia/' "$NOCTALIA_TOML" 2>/dev/null \
    && grep -qE '^[[:space:]]*include[[:space:]]+"/etc/niri/config\.kdl"' "$NIRI_USER_CFG" 2>/dev/null
}
noctalia_ipc_ok() { as_user timeout 10 noctalia msg status >/tmp/noctalia-status.out 2>&1; }
# PID of the connection owning org.freedesktop.Notifications. Asking the
# bus about a name never activates it, so this sees who owns it now.
notif_pid() {
  as_user busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus \
    GetConnectionUnixProcessID s org.freedesktop.Notifications 2>/dev/null | awk '{print $2}'
}
for _ in $(seq 1 18); do
  find_niri
  niri_ipc_ok && seeded_ok && noctalia_ipc_ok && [[ -n "$(notif_pid)" ]] && break
  sleep 5
done

[[ -n "$NIRI_PID" ]] || fail "niri.service is not running for $SMOKE_USER (niri was not started by niri-session?)"
[[ "$(cat "/proc/$NIRI_PID/comm" 2>/dev/null)" == niri ]] \
  || fail "niri.service MainPID $NIRI_PID is not niri"
niri_ipc_ok || fail "niri does not answer on its socket (NIRI_SOCKET=${NIRI_SOCK:-unset}): $(tail -n 2 /tmp/niri-version.out | tr '\n' ' ')"
NIRI_VER="$(sed -n 's/^Compositor version: *//p' /tmp/niri-version.out | head -n 1)"
NIRI_VER="${NIRI_VER%% *}"

[[ -f "$NOCTALIA_TOML" ]] || fail "session-start did not run: $NOCTALIA_TOML missing; niri log: $(niri_log)"
seeded_ok || fail "session-start ran but left $NOCTALIA_TOML or $NIRI_USER_CFG without the Lucciola include"

pgrep -u "$SMOKE_USER" -x noctalia >/dev/null || fail "Noctalia is not running for $SMOKE_USER; niri log: $(niri_log)"
noctalia_ipc_ok || fail "Noctalia runs but does not answer on its IPC (WAYLAND_DISPLAY=${WL_DISPLAY:-unset}): $(tail -n 2 /tmp/noctalia-status.out | tr '\n' ' ')"

# Noctalia is the notification server of the session (the bar's
# notification centre): any other owner, or none, is a broken desktop.
NPID="$(notif_pid)"
[[ -n "$NPID" ]] || fail "nothing owns org.freedesktop.Notifications on the user bus"
NCOMM="$(cat "/proc/$NPID/comm" 2>/dev/null)"
[[ "$NCOMM" == noctalia ]] || fail "org.freedesktop.Notifications is owned by ${NCOMM:-pid $NPID}, not Noctalia"
as_user busctl --user --timeout=10 call org.freedesktop.Notifications /org/freedesktop/Notifications \
  org.freedesktop.Notifications GetServerInformation >/dev/null 2>&1 \
  || fail "Noctalia owns org.freedesktop.Notifications but GetServerInformation got no answer"

# ---- 3b. The Login keyring: pam_oo7 opened it with the password -------------
# The password login handed the password to oo7: pam_oo7 in greetd's PAM
# stack keeps it, oo7-daemon (started with niri.service) receives it from
# pam_oo7's helper and opens the Login keyring. "Unlocked" alone proves too
# little (oo7 can answer for a keyring that needed no password), so the
# daemon's own line for the secret it received must be in its log since the
# password login; the autologin before it had no password to give. The same
# property `ujust lucciola-keyring status` reads.
keyring_locked() {
  as_user busctl --user --timeout=10 get-property org.freedesktop.secrets \
    /org/freedesktop/secrets/aliases/default org.freedesktop.Secret.Collection Locked 2>/dev/null | awk '{print $2}'
}
KR=""
for _ in $(seq 1 12); do
  KR="$(keyring_locked)"
  [[ -n "$KR" ]] && break
  sleep 5
done
OO7_LOG="$(journalctl -b -q --no-pager -o cat _UID="$SMOKE_UID" _SYSTEMD_USER_UNIT=oo7-daemon.service \
  ${LOGIN_SINCE:+--since "@$LOGIN_SINCE"} 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
oo7_tail() { tail -n 3 <<<"$OO7_LOG" | tr '\n' ' ' | cut -c1-300; }
case "$KR" in
  false) ;;
  true) fail "the Login keyring is LOCKED after a password login: pam_oo7 did not hand the password over; oo7 log: $(oo7_tail)" ;;
  *)    fail "the Secret Service (oo7) does not answer for the Login keyring; oo7 log: $(oo7_tail)" ;;
esac
grep -q 'Received login secret from helper' <<<"$OO7_LOG" \
  || fail "the Login keyring answers unlocked, but oo7 logged no secret from pam_oo7 since the password login; oo7 log: $(oo7_tail)"

# ---- 4. Outputs and the bar --------------------------------------------------
# niri renders only on a hardware GPU: it skips software EGL renderers
# (llvmpipe; src/backend/tty.rs, "software EGL renderers are skipped"),
# so a VM without 3D acceleration, the CI one included, gets niri running
# with no output at all. With an output, Noctalia must have put its bar
# there (layer-shell namespace noctalia-bar-<name>); without one the bar
# cannot exist and the PASS line says it was not checked.
OUTPUTS="$(as_user timeout 10 niri msg -j outputs 2>/dev/null | python3 -c '
import json, sys
print(sum(1 for o in json.load(sys.stdin).values() if o.get("logical")))' 2>/dev/null)"
[[ "$OUTPUTS" =~ ^[0-9]+$ ]] || fail "niri msg outputs gave no readable answer"
BAR="not-checked(no-output)"
if (( OUTPUTS > 0 )); then
  BAR=""
  for _ in $(seq 1 9); do
    BAR="$(as_user timeout 10 niri msg -j layers 2>/dev/null | python3 -c '
import json, sys
for layer in json.load(sys.stdin):
    print(layer.get("namespace", ""))' 2>/dev/null | grep -m1 '^noctalia-bar')"
    [[ -n "$BAR" ]] && break
    sleep 5
  done
  [[ -n "$BAR" ]] || fail "niri has $OUTPUTS output(s) but no Noctalia bar on them (no noctalia-bar layer surface)"
fi

# ---- 5. xdg-desktop-portal ---------------------------------------------------
# Called the way a Flatpak app reaches it: the call D-Bus-activates the
# portal if nothing has yet, in the environment niri published. The
# FileChooser interface exists only when the portal found a backend for
# this desktop (niri-portals.conf), so an XDG_CURRENT_DESKTOP that never
# reached the user manager fails here, not just a portal that is down.
PORTAL="$(as_user timeout 90 busctl --user --timeout=80 get-property org.freedesktop.portal.Desktop \
  /org/freedesktop/portal/desktop org.freedesktop.portal.FileChooser version 2>&1)" \
  || fail "xdg-desktop-portal has no FileChooser: $(tr '\n' ' ' <<<"$PORTAL" | cut -c1-200)"
PORTAL_V="${PORTAL##* }"

# ---- 6. Still alive, nothing crashed -----------------------------------------
find_niri
[[ -n "$NIRI_PID" && "$(cat "/proc/$NIRI_PID/comm" 2>/dev/null)" == niri ]] \
  || fail "niri died during the probe window; niri log: $(niri_log)"
noctalia_ipc_ok || fail "Noctalia stopped answering during the probe window; niri log: $(niri_log)"
CORES=$(coredumpctl --no-pager -q list 2>/dev/null \
  | grep -cE '/(niri|noctalia|xwayland-satellite|xdg-desktop-portal[a-z-]*)([[:space:]]|$)' || true)
[[ "$CORES" -eq 0 ]] || fail "niri, Noctalia or a portal dumped core ($CORES)"
# A Rust panic in a niri thread is logged even when the compositor
# survives it; Noctalia and session-start write to the same stream.
PANIC="$(journalctl -b -q --no-pager -o cat _SYSTEMD_USER_UNIT=niri.service _UID="$SMOKE_UID" 2>/dev/null \
  | grep -m1 'panicked at' || true)"
[[ -z "$PANIC" ]] || fail "panic in the niri session: ${PANIC:0:200}"

# Branding validator (from margine-fedora-atomic): file checks plus,
# when a display is reachable, a GTK icon lookup. (Headless-safe since
# fedora-atomic#56: no display => skip, not a false FAIL.) Boot splash,
# logos and os-release LOGO are still Margine's in Lucciola.
if [[ -x /usr/bin/lucciola-validate-branding ]]; then
  /usr/bin/lucciola-validate-branding > /tmp/branding.out 2>&1 \
    || fail "lucciola-validate-branding: $(tail -3 /tmp/branding.out | tr '\n' ' ')"
fi

out "MARGINE-GUI-SMOKE: PASS login=${S_SERVICE}/password keyring=unlocked session=${S_DESK,,}/${S_TYPE} niri=${NIRI_VER:-?} outputs=$OUTPUTS bar=$BAR notifications=$NCOMM portal=FileChooser.v${PORTAL_V}"
wait_gaming
poweroff_vm
