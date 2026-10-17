#!/usr/bin/env bash
# Lucciola USER-SMOKE probe: runs INSIDE the smoke-boot VM as a root
# oneshot (margine-user-smoke.service), injected offline into the qcow2
# by .github/scripts/inject-gui-probe.sh. Where the Layer C gui-probe.sh
# asks "is the graphical session HEALTHY?" (niri and Noctalia alive and
# answering, nothing crashed), this probe asks the user-facing question
# "is this image still LUCCIOLA?": the identity assertions a person would
# notice if they regressed: the CachyOS/BORE kernel booted, the session
# is Lucciola's and new users get it, the public name, the niri defaults
# load for a user, the Margine look of Noctalia, GNOME left stock as the
# fallback, the gaming recipe shipped, and the Margine accent colour GTK
# applications keep.
#
# SOFT ("morbido") GATE: every check is WARN-only. This probe NEVER
# fails the job and NEVER blocks the candidate->stable promotion: it
# only annotates the run (serial -> step summary). It ALWAYS exits 0.
# The CI watcher greps the serial console for:
#   MARGINE-USER-SMOKE: <CHECK> <PASS|WARN> ...   (per check)
#   MARGINE-USER-SMOKE: SUMMARY pass=N warn=M ...  (one line)
#   MARGINE-USER-SMOKE: DONE                       (probe finished)
#
# Runs AFTER gui-probe.sh's poweroff would fire, so it must NOT power the
# VM off itself: gui-probe.sh owns the poweroff (it calls wait_gaming
# then `systemctl poweroff`). This probe just emits and returns; if it
# is the only probe injected it still leaves shutdown to the gui-probe
# unit ordering. Bounded everywhere (no unbounded waits) so it can never
# hold the boot window open.
#
# Lives as a real file (like gui-probe.sh) so shellcheck gates it and it
# can be run on the lab VM directly:
#   sudo PROBE_STDOUT=1 .github/smoke/user-smoke-probe.sh
set -u

# Markers to BOTH /dev/console (the watcher reads -serial) and /dev/kmsg
# (mirrored to console=ttyS0 forced by inject-gui-probe.sh) so the
# verdict survives a BLS entry that lacks the serial console karg.
# PROBE_STDOUT=1 prints instead (same knob as the other probes).
out() {
  if [[ "${PROBE_STDOUT:-0}" == 1 ]]; then echo "$@"; return 0; fi
  echo "$@" > /dev/console 2>/dev/null || true
  echo "<usersmoke> $*" > /dev/kmsg 2>/dev/null || true
}

PASS=0
WARN=0
# check <NAME> <0-if-ok> <detail...>: soft, a failure is a WARN, never fatal.
check() {
  local name="$1" rc="$2"; shift 2
  if [[ "$rc" -eq 0 ]]; then
    PASS=$((PASS + 1)); out "MARGINE-USER-SMOKE: ${name} PASS $*"
  else
    WARN=$((WARN + 1)); out "MARGINE-USER-SMOKE: ${name} WARN $*"
  fi
}

# The injected smoke autologin user is uid 1010 (see inject-gui-probe.sh).
SMOKE_UID=1010
SMOKE_USER=smoke
SMOKE_HOME=/var/home/smoke
RUN_DIR="/run/user/${SMOKE_UID}"

# Run a command AS THE SMOKE USER with its runtime dir and session bus, so
# gsettings resolves the distro dconf db and the gschema overrides through
# the user's profile exactly as a real first login would, and the niri
# and Noctalia clients find the session (extra VAR=value words go first).
as_user() {
  runuser -u "$SMOKE_USER" -- env \
    HOME="$SMOKE_HOME" \
    XDG_RUNTIME_DIR="$RUN_DIR" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=${RUN_DIR}/bus" \
    "$@"
}
usettings() {  # usettings <schema> <key>; empty string on failure
  as_user gsettings get "$1" "$2" 2>/dev/null || true
}

# Give the autologin session a bounded moment to settle so the per-user
# bus and niri are up (this unit is After=graphical.target but the user
# session may lag the target). Bounded: never an unbounded wait.
for _ in $(seq 1 24); do
  [[ -S "${RUN_DIR}/bus" ]] && pgrep -u "$SMOKE_USER" -x niri >/dev/null && break
  sleep 5
done

out "MARGINE-USER-SMOKE: BEGIN"

# 1. CachyOS/BORE kernel is the one that actually booted (CORE identity).
KREL="$(uname -r 2>/dev/null || echo '?')"
if [[ "$KREL" == *cachyos* ]]; then check KERNEL 0 "uname=$KREL"
else check KERNEL 1 "expected *cachyos*, got uname=$KREL"; fi

# 2. The user-facing "did I get the desktop": greetd is the login screen
#    (GDM, its fallback, not running) and the smoke user's graphical
#    session, which greetd-login.py started with a password login, is
#    Lucciola's, on Wayland, opened by the greetd PAM service, with niri
#    running. The session name is the XDG_SESSION_DESKTOP the login screen
#    gave the session (Noctalia Greeter: niri, the first DesktopNames entry;
#    GDM: lucciola, the file's name), which niri-session imports into the
#    user manager.
DM_OK=1
DM="$(readlink /etc/systemd/system/display-manager.service 2>/dev/null)"
if [[ "${DM##*/}" == greetd.service ]] && systemctl is-active --quiet greetd.service 2>/dev/null \
    && ! systemctl is-active --quiet gdm.service 2>/dev/null; then
  DM_OK=0
fi
SID="$(loginctl show-user "$SMOKE_USER" -p Display --value 2>/dev/null)"
S_DESK="$(as_user systemctl --user show-environment 2>/dev/null | sed -n 's/^XDG_SESSION_DESKTOP=//p' | head -n 1)"
S_TYPE="" S_SERVICE=""
if [[ -n "$SID" ]]; then
  S_TYPE="$(loginctl show-session "$SID" -p Type --value 2>/dev/null)"
  S_SERVICE="$(loginctl show-session "$SID" -p Service --value 2>/dev/null)"
  [[ -n "$S_DESK" ]] || S_DESK="$(loginctl show-session "$SID" -p Desktop --value 2>/dev/null)"
fi
NIRI_UP=no
pgrep -u "$SMOKE_USER" -x niri >/dev/null 2>&1 && NIRI_UP=yes
SESSION_DETAIL="session=${SID:-none} service=${S_SERVICE:-?} desktop=${S_DESK:-?} type=${S_TYPE:-?} niri=$NIRI_UP"
if [[ "$DM_OK" -eq 0 && "${S_DESK,,}" =~ ^(lucciola|niri)$ && "$S_TYPE" == wayland && "$S_SERVICE" == greetd && "$NIRI_UP" == yes ]]; then
  check SESSION 0 "greetd active, $SESSION_DETAIL"
elif [[ "$DM_OK" -eq 0 ]]; then
  check SESSION 1 "greetd active but not a Lucciola session from it: $SESSION_DETAIL"
else
  check SESSION 1 "greetd is not the running login screen (display-manager=${DM##*/} greetd=$(systemctl is-active greetd.service 2>/dev/null) gdm=$(systemctl is-active gdm.service 2>/dev/null); $SESSION_DETAIL)"
fi

# 3. The public name: os-release and the product name Margine's own
#    tooling reads both say Lucciola (ID and VARIANT_ID stay Margine's).
OS_NAME="$(sed -n 's/^NAME=//p' /etc/os-release 2>/dev/null | tr -d '"')"
PRODUCT="$(cat /usr/share/margine/product-name 2>/dev/null)"
if [[ "$OS_NAME" == Lucciola && "$PRODUCT" == Lucciola ]]; then
  check OS_NAME 0 "os-release NAME=$OS_NAME product-name=$PRODUCT"
else
  check OS_NAME 1 "os-release NAME=${OS_NAME:-?} product-name=${PRODUCT:-?}"
fi

# 4. New users get Lucciola. accounts-daemon fills a user with no record
#    from the user template of its account type; autologin starts the
#    Session written there (/usr/libexec/lucciola/autologin-session, as
#    GDM did), and Noctalia Greeter preselects Lucciola until someone picks
#    another session (its seeded sync.toml). The administrator template is
#    the one the first user of a fresh install (wheel) gets. accounts-daemon
#    reads the first template it finds in /run, /etc, then the data dirs.
template() {
  local d
  for d in /run /etc /usr/local/share /usr/share; do
    [[ -f "$d/accountsservice/user-templates/$1" ]] && { echo "$d/accountsservice/user-templates/$1"; return; }
  done
}
DS_BAD=""
for t in standard administrator; do
  f="$(template "$t")"
  grep -qx 'Session=lucciola' "${f:-/dev/null}" 2>/dev/null || DS_BAD+=" $t:${f:-missing}"
done
SESSION_FILE=/usr/share/wayland-sessions/lucciola.desktop
grep -qx 'Exec=niri-session' "$SESSION_FILE" 2>/dev/null || DS_BAD+=" $SESSION_FILE"
GREETER_LAST="$(sed -n 's/^last *= *"\(.*\)"$/\1/p' /var/lib/noctalia-greeter/sync.toml 2>/dev/null | head -n 1)"
[[ "$GREETER_LAST" == Lucciola ]] || DS_BAD+=" greeter-last-session:${GREETER_LAST:-none}"
if [[ -z "$DS_BAD" ]]; then
  check DEFAULT_SESSION 0 "user templates Session=lucciola, greeter preselects Lucciola, $SESSION_FILE runs niri-session"
else
  check DEFAULT_SESSION 1 "not Lucciola:$DS_BAD"
fi

# 5. The niri defaults load for a user. niri reads ~/.config/niri/config.kdl
#    INSTEAD of /etc/niri/config.kdl, so session-start makes it start with
#    an include of the system one; `niri validate` then parses the whole
#    chain the compositor uses (Lucciola defaults, lucciola.kdl, the colours
#    Noctalia renders, the screenshot path), as the user, so ~ resolves.
UCFG="$SMOKE_HOME/.config/niri/config.kdl"
if [[ ! -f "$UCFG" ]]; then
  check NIRI_CONFIG 1 "$UCFG missing (session-start did not run?)"
elif ! grep -qE '^[[:space:]]*include[[:space:]]+"/etc/niri/config\.kdl"' "$UCFG"; then
  check NIRI_CONFIG 1 "$UCFG does not include /etc/niri/config.kdl: Lucciola defaults and keybindings are off"
elif VALID="$(as_user timeout 30 niri validate -c "$UCFG" 2>&1)"; then
  check NIRI_CONFIG 0 "$UCFG includes the system config and validates"
else
  check NIRI_CONFIG 1 "niri validate: $(printf '%s\n' "$VALID" | tail -n 2 | sed 's/\x1b\[[0-9;]*m//g' | tr '\n' ' ' | cut -c1-200)"
fi

# 6. Noctalia has the Margine look: dark, custom palette "Margine"
#    (noctalia/20-margine-style.toml). Asked from Noctalia itself, whose
#    IPC socket is named after the session's Wayland display, which niri
#    publishes in the user manager's environment.
WL="$(as_user systemctl --user show-environment 2>/dev/null | sed -n 's/^WAYLAND_DISPLAY=//p' | head -n 1)"
SCHEME="$(as_user WAYLAND_DISPLAY="${WL:-wayland-1}" timeout 10 noctalia msg color-scheme-get 2>/dev/null)"
MODE="$(as_user WAYLAND_DISPLAY="${WL:-wayland-1}" timeout 10 noctalia msg theme-mode-get 2>/dev/null)"
if [[ "$SCHEME" == *Margine* && "$MODE" == *dark* ]]; then
  check NOCTALIA_LOOK 0 "scheme=$SCHEME mode=$MODE"
else
  check NOCTALIA_LOOK 1 "expected the custom Margine palette, dark (scheme=${SCHEME:-no answer} mode=${MODE:-no answer} WAYLAND_DISPLAY=${WL:-unset})"
fi

# 7. GNOME is the stock fallback: Lucciola drops every extension Margine
#    adds, o-tiling first, from disk and from the defaults a user gets.
OTILING_UUID='o-tiling@oliwebd.github.com'
ENABLED_LIST="$(usettings org.gnome.shell enabled-extensions)"
if [[ -e "/usr/share/gnome-shell/extensions/${OTILING_UUID}" ]]; then
  check GNOME_STOCK 1 "o-tiling is installed (enabled-extensions=$ENABLED_LIST)"
elif [[ "$ENABLED_LIST" == *o-tiling* || "$ENABLED_LIST" == *search-light* ]]; then
  check GNOME_STOCK 1 "Margine extensions enabled for $SMOKE_USER: $ENABLED_LIST"
else
  check GNOME_STOCK 0 "no Margine extension (enabled-extensions=${ENABLED_LIST:-?})"
fi

# 8. Gaming ujust recipe exists: `ujust --list` shows margine-gaming*.
#    Run as the smoke user (ujust is the user-facing entry point).
UJUST_BIN=""
for c in /usr/bin/ujust /usr/local/bin/ujust; do [[ -x "$c" ]] && UJUST_BIN="$c" && break; done
if [[ -n "$UJUST_BIN" ]]; then
  UJUST_LIST="$(runuser -u "$SMOKE_USER" -- "$UJUST_BIN" --list 2>/dev/null || true)"
  GAMING_RECIPES="$(printf '%s\n' "$UJUST_LIST" | grep -oE 'margine-gaming[a-z-]*' | sort -u | tr '\n' ',' | sed 's/,$//')"
  if printf '%s\n' "$UJUST_LIST" | grep -qE 'margine-gaming'; then
    check GAMING_UJUST 0 "recipes: ${GAMING_RECIPES:-margine-gaming*}"
  else
    check GAMING_UJUST 1 "no margine-gaming* in ujust --list"
  fi
else
  check GAMING_UJUST 1 "ujust binary not found"
fi

# 9. zz1-margine gschema applied where Lucciola keeps it: accent-color=yellow
#    (not a GNOME default) serves the GTK applications of the niri session.
#    num-workspaces, checked here on Margine, went with the Shell and
#    window-manager defaults lucciola/build.sh drops.
ACCENT="$(usettings org.gnome.desktop.interface accent-color)"
if [[ "$ACCENT" == *yellow* ]]; then
  check GSCHEMA 0 "accent=$ACCENT"
else
  check GSCHEMA 1 "zz1-margine override not applied (accent=${ACCENT:-?})"
fi

# ---- Summary (one parseable line) -----------------------------------------
TOTAL=$((PASS + WARN))
out "MARGINE-USER-SMOKE: SUMMARY pass=${PASS} warn=${WARN} total=${TOTAL}"
if [[ "$WARN" -eq 0 ]]; then
  out "MARGINE-USER-SMOKE: VERDICT ALL-PASS (${PASS}/${TOTAL})"
else
  out "MARGINE-USER-SMOKE: VERDICT WARN (${PASS}/${TOTAL} ok, ${WARN} warning): soft gate, promotion NOT blocked"
fi
out "MARGINE-USER-SMOKE: DONE"

# SOFT GATE: always succeed. The verdict is annotation only.
exit 0
