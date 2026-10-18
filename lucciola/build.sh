#!/usr/bin/env bash
# Lucciola image build: runs once inside the main Containerfile, after every
# Margine step (build_files/) and before 99-cleanup.sh. Adds niri and Noctalia
# from the official Fedora repositories, makes "Lucciola" the session and the
# system name, puts greetd with Noctalia Greeter in place of GDM as the login
# screen (step 5), and checks the result.
#
# Written when Lucciola was a second build FROM the published Margine image,
# and kept as it was when the two builds became one (2026-10). Until
# 2026-10-18 it also undid Margine's GNOME customisation (extensions, Shell
# defaults, dconf keyfiles, first-login autostarts, Smile and Extension
# Manager); the Margine steps no longer add any of it, and 2b only checks
# that GNOME arrives stock. Still redoing a Margine step:
#   3   rewrites the os-release 10-os-identity writes;
#   the closing dnf clean repeats what 99-cleanup.sh does anyway.
set -euo pipefail

log() { echo "[lucciola-build] $*"; }

: "${NOCTALIA_VR:?NOCTALIA_VR must be set (the pinned noctalia version-release)}"
: "${NOCTALIA_GREETER_VERSION:?NOCTALIA_GREETER_VERSION must be set (the Noctalia Greeter tag the greeter-rpm stage built)}"
# The Fedora tag comes from the base, so the pin holds across a Fedora
# release: the same version-release, built for the release underneath.
NOCTALIA_EVR="${NOCTALIA_VR}.fc$(rpm -E %fedora)"

# 1. Packages. Weak dependencies off: niri's package recommends waybar,
#    fuzzel, alacritty and swaylock, a second bar, launcher, terminal and
#    locker next to Noctalia, which owns those jobs. Its other recommendations
#    are covered by the Margine image: wireplumber, the GNOME/GTK portals, and
#    gnome-keyring, whose job (the Secret Service) oo7 does from Fedora 45.
#    Noctalia is pinned: upstream supports only its latest release and Fedora
#    ships every one within a day, so a new version arrives only through a
#    reviewed change of NOCTALIA_VR, never by itself. The other side of the
#    pin: Fedora's updates repository keeps only the newest build, so a
#    version that came as an update stops being installable the day the
#    next one goes stable (5.2.1-1 left Fedora 44 on 2026-10-17), and this
#    install fails until NOCTALIA_VR follows.
#    ddcutil: Noctalia's brightness slider drives external monitors over
#    DDC/CI when it finds it (GNOME has no such path, so Margine itself
#    does not carry it). The Fedora package brings the udev rule that
#    opens /dev/i2c-* to the logged-in user and the modules-load entry
#    for i2c-dev.
log "installing niri, xwayland-satellite, noctalia-${NOCTALIA_EVR}, ddcutil"
dnf5 -y --setopt=install_weak_deps=False install \
  niri xwayland-satellite "noctalia-${NOCTALIA_EVR}" ddcutil
for f in /usr/lib/udev/rules.d/60-ddcutil-i2c.rules /usr/lib/modules-load.d/ddcutil.conf; do
  [[ -f "$f" ]] || { echo "ERROR: $f missing: the ddcutil package layout changed, external-monitor brightness would need a rule of our own" >&2; exit 1; }
done
for p in waybar mako fuzzel alacritty swaylock; do
  if rpm -q "$p" >/dev/null 2>&1; then
    echo "ERROR: $p got installed; it would compete with Noctalia" >&2
    exit 1
  fi
done

# 2. Session. The login screen lists wayland-sessions/*.desktop by their
#    Name=; Lucciola replaces the plain "Niri" entry with its own (same
#    niri-session underneath), so the login screen offers "Lucciola" next to
#    GNOME.
src=/usr/share/wayland-sessions/niri.desktop
[[ -f "$src" ]] || { echo "ERROR: $src missing: niri package layout changed" >&2; exit 1; }
grep -q '^Exec=niri-session' "$src" || { echo "ERROR: niri.desktop no longer runs niri-session" >&2; exit 1; }
sed -e 's/^Name=.*/Name=Lucciola/' \
    -e 's/^Comment=.*/Comment=Lucciola: niri with the Noctalia shell/' \
    "$src" > /usr/share/wayland-sessions/lucciola.desktop
rm -f "$src"
log "session entry: $(grep -E '^(Name|Exec|DesktopNames)=' /usr/share/wayland-sessions/lucciola.desktop | tr '\n' ' ')"

# 2b. GNOME stays stock. Lucciola keeps GNOME as a fallback session only,
#     and stock: no Shell extension besides the GNOME Classic set Fedora's
#     gnome-shell-extensions package ships, no override that enables one,
#     no Shell, mutter, window-manager or settings-daemon defaults in our
#     gschema overrides or the dconf database, no first-login autostart.
#     The Margine steps stopped adding them on 2026-10-18 (the zz1 override
#     keeps what GTK applications read: accent colour, wallpaper,
#     virt-manager); this fails the build if one comes back, from them or
#     from the base.
log "checking that GNOME is stock"
bad=()
for d in /usr/share/gnome-shell/extensions/*/; do
  [[ -d "$d" ]] || continue   # the glob itself, when the directory is empty
  srpm="$(rpm -qf --qf '%{SOURCERPM}' "${d%/}" 2>/dev/null || true)"
  [[ "$srpm" == gnome-shell-extensions-* ]] || bad+=("extension $(basename "$d") (${srpm:-owned by no package})")
done
while read -r name srpm; do
  [[ "$srpm" == gnome-shell-extensions-* ]] || bad+=("extension package $name")
done < <(rpm -qa --qf '%{NAME} %{SOURCERPM}\n' 'gnome-shell-extension-*')
for f in /usr/share/glib-2.0/schemas/org.gnome.shell.extensions.*.gschema.xml; do
  [[ -e "$f" ]] || continue
  rpm -qf "$f" >/dev/null 2>&1 || bad+=("schema owned by no package: $f")
done
gnome_section='org[./]gnome[./](shell|mutter|desktop[./]wm|desktop[./]app-folders|desktop[./]search-providers|desktop[./]peripherals|settings-daemon)'
for f in /usr/share/glib-2.0/schemas/zz*.gschema.override; do
  [[ -e "$f" ]] || continue
  if grep -qE "^\[${gnome_section}([].:])" "$f"; then bad+=("$f sets GNOME Shell or window-manager defaults"); fi
  if grep -q 'enabled-extensions' "$f"; then bad+=("$f enables extensions"); fi
done
for f in /etc/dconf/db/distro.d/*; do
  [[ -f "$f" ]] || continue
  if grep -qE "^\[${gnome_section}(/|\])" "$f"; then bad+=("dconf $f sets GNOME Shell or window-manager defaults"); fi
done
for f in /etc/xdg/autostart/margine-first-boot*.desktop; do
  if [[ -e "$f" ]]; then bad+=("first-login autostart $f"); fi
done
if (( ${#bad[@]} )); then
  printf 'ERROR: GNOME is not stock: %s\n' "${bad[@]}" >&2
  exit 1
fi
# Every override still compiles cleanly against the schemas in the image.
out="$(glib-compile-schemas --dry-run /usr/share/glib-2.0/schemas 2>&1)" || { echo "$out" >&2; exit 1; }
if grep -q 'zz1-margine' <<<"$out"; then
  echo "$out" >&2; echo "ERROR: zz1-margine.gschema.override names a schema or key the image does not have" >&2; exit 1
fi
log "GNOME extensions: $(ls /usr/share/gnome-shell/extensions/ 2>/dev/null | tr '\n' ' ')"

# 2c. Lucciola is the session a new user gets. accounts-daemon fills a
#     user's record from these templates the first time it sees the user.
#     Noctalia Greeter keeps its own memory of the last session (seeded with
#     Lucciola, step 5); this record is what autologin starts
#     (/usr/libexec/lucciola/autologin-session) and what GDM preselects when
#     it is the login screen (greetd's fallback). Users that already have a
#     record (an install moved from Margine) are not touched.
for t in standard administrator; do
  f="/usr/share/accountsservice/user-templates/$t"
  grep -q '^Session=' "$f" || { echo "ERROR: $f has no Session key: the accountsservice template layout changed" >&2; exit 1; }
  sed -i 's/^Session=.*/Session=lucciola/' "$f"
  grep -q '^Session=lucciola$' "$f" || { echo "ERROR: $f not rewritten" >&2; exit 1; }
done

# 3. Identity. Only the public name changes: ID, VARIANT_ID and the rest stay
#    Margine's, because the tooling underneath (validators, status, update
#    helpers) is Margine's and keys on them.
fedora_ver="$(rpm -E %fedora)"
build_date="$(date -u +%Y%m%d)"
sed -i \
  -e 's/^NAME=.*/NAME="Lucciola"/' \
  -e "s/^VERSION=.*/VERSION=\"${fedora_ver} (Lucciola)\"/" \
  -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Lucciola ${fedora_ver} (${build_date})\"/" \
  -e 's/^VARIANT=.*/VARIANT="Lucciola"/' \
  /usr/lib/os-release
grep -q '^NAME="Lucciola"$' /usr/lib/os-release || { echo "ERROR: os-release not rewritten" >&2; exit 1; }

# 4. Checks: the shipped niri config must parse (includes resolved), and the
#    helpers must be there and executable.
niri validate -c /etc/niri/config.kdl
# Noctalia's own validator; it only warns on bad values, so any warning fails.
out="$(noctalia config validate /usr/share/lucciola/noctalia/ 2>&1)" || { echo "$out" >&2; exit 1; }
if grep -q WARN <<<"$out"; then echo "$out" >&2; echo "ERROR: Noctalia defaults have warnings" >&2; exit 1; fi
# Noctalia silently falls back to its builtin palette when a custom palette
# lacks the "terminal" block (src/theme/theme_service.cpp,
# parseCommunityPaletteJson), so check what it actually requires.
python3 - /usr/share/lucciola/noctalia/palettes/Margine.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
keys = ["mPrimary", "mOnPrimary", "mSecondary", "mOnSecondary", "mTertiary", "mOnTertiary",
        "mError", "mOnError", "mSurface", "mOnSurface", "mSurfaceVariant", "mOnSurfaceVariant",
        "mOutline", "mShadow", "mHover", "mOnHover"]
dark = d["dark"]
missing = [k for k in keys if k not in dark]
term = dark.get("terminal", {})
for part in ("normal", "bright"):
    if set(term.get(part, {})) != {"black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"}:
        missing.append("terminal." + part)
if missing:
    sys.exit("ERROR: Margine palette incomplete, Noctalia would ignore it: " + ", ".join(missing))
PY
# lucciola-keep-awake is a symlink from system_files: -x follows it, so a
# dangling one fails here.
for f in /usr/libexec/lucciola/{session-start,lock,bar-widths,color-calibration,keep-awake} /usr/bin/lucciola-keep-awake; do
  [[ -x "$f" ]] || { echo "ERROR: $f missing or not executable" >&2; exit 1; }
done
# The Python helpers must at least parse (ast, so no __pycache__ in /usr).
for f in /usr/libexec/lucciola/{bar-widths,color-calibration}; do
  python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f"
done
rpm -q niri noctalia xwayland-satellite

# 5. Login screen: greetd running Noctalia Greeter, in place of GDM.
#    GDM drew a GNOME login screen in front of a niri desktop; Noctalia
#    Greeter has the Noctalia look and offers the same sessions. GDM stays
#    installed, disabled: it is the fallback greetd.service starts when the
#    greeter cannot come up (greetd.service.d/50-lucciola.conf), the GNOME
#    session and the base-trim guard expect it, and a user can switch back
#    to it. Files: lucciola/system_files (greetd config template, greeter
#    settings, tmpfiles, SELinux module, PAM environment, the migration unit).
#
# 5a. Packages. greetd and its SELinux module from Fedora; Noctalia Greeter
#     built from its pinned tag by the Containerfile's greeter-rpm stage (why
#     not a third-party repository: see there). dbus-daemon brings
#     dbus-run-session, which the greeter's wrapper needs for a session bus
#     (the base has only dbus-broker). Weak dependencies off, as above.
shopt -s nullglob
greeter_rpms=(/ctx/greeter-rpm/noctalia-greeter-"${NOCTALIA_GREETER_VERSION}"-*.rpm)
shopt -u nullglob
(( ${#greeter_rpms[@]} == 1 )) || { echo "ERROR: expected one noctalia-greeter-${NOCTALIA_GREETER_VERSION} RPM in /ctx/greeter-rpm, found ${#greeter_rpms[@]}" >&2; exit 1; }
log "installing greetd, greetd-selinux, dbus-daemon, ${greeter_rpms[0]##*/}"
dnf5 -y --setopt=install_weak_deps=False install greetd greetd-selinux dbus-daemon "${greeter_rpms[0]}"
rpm -q greetd greetd-selinux dbus-daemon noctalia-greeter gdm
# dbus-daemon also brings dbus-daemon-launch-helper, setuid root (4750,
# group dbus): it starts system services for a dbus-daemon SYSTEM bus. The
# system bus here is dbus-broker, which starts services through systemd, so
# the helper is never used and would only be a way to root for the dbus
# account (the one dbus-broker runs as). dbus-run-session, all the greeter
# needs, runs a session bus as the user and has no use for it either.
helper=/usr/libexec/dbus-1/dbus-daemon-launch-helper
if [[ -u "$helper" ]]; then
  chmod u-s "$helper"
  log "dropped setuid from $helper (unused: the system bus is dbus-broker)"
fi
[[ ! -u "$helper" ]] || { echo "ERROR: $helper is still setuid" >&2; exit 1; }
for f in /usr/bin/greetd /usr/bin/noctalia-greeter-session /usr/bin/noctalia-greeter-apply-appearance \
         /usr/bin/dbus-run-session /usr/bin/pkexec /usr/lib/pam.d/greetd /usr/lib/pam.d/greetd-greeter \
         /usr/share/polkit-1/actions/org.noctalia.greeter.apply-appearance.policy; do
  [[ -e "$f" ]] || { echo "ERROR: $f missing after the greetd/greeter install" >&2; exit 1; }
done
# The greeter account. Fedora's greetd creates "greetd" (sysusers.d); the
# config below and lucciola-greeter.conf in tmpfiles.d name it.
getent passwd greetd >/dev/null || { echo "ERROR: no greetd account after installing greetd" >&2; exit 1; }
grep -q '^u[[:space:]]\+greetd[[:space:]]' /usr/lib/sysusers.d/greetd.conf \
  || { echo "ERROR: greetd's sysusers.d entry changed: installed systems would not get the account at boot" >&2; exit 1; }

# 5b. SELinux. greetd-selinux labels greetd (xdm_exec_t: it runs as xdm_t,
#     like GDM) and its state; Lucciola's module labels the greeter's state
#     directory the same way (the .cil file says why). semodule as the
#     greetd-selinux scriptlet runs it: -n, no policy load in a build.
semodule -n -s targeted -X 200 -i /usr/share/selinux/packages/targeted/lucciola-greeter.cil
semodule -l | grep -qx 'lucciola-greeter' || { echo "ERROR: the lucciola-greeter SELinux module did not load" >&2; exit 1; }
for want in "/usr/bin/greetd xdm_exec_t" "/var/lib/greetd xdm_var_lib_t" "/etc/greetd/config.toml xdm_etc_t" \
            "/var/lib/noctalia-greeter xdm_var_lib_t" "/var/lib/noctalia-greeter/sync.toml xdm_var_lib_t"; do
  path="${want% *}" type="${want#* }"
  got="$(matchpathcon -n "$path" 2>/dev/null || true)"
  [[ "$got" == *":${type}:"* ]] || { echo "ERROR: SELinux would label $path '${got:-nothing}', expected $type" >&2; exit 1; }
done

# 5c. PAM. Fedora's /usr/lib/pam.d/greetd is GDM's password login
#     (/usr/lib/pam.d/gdm-password) in all that matters: system-auth for
#     auth (pam_unix, and pam_fprintd when authselect's with-fingerprint is
#     on), account and session (pam_systemd), pam_oo7 handing the login
#     password to the Secret Service, pam_selinux, pam_loginuid,
#     pam_keyinit, pam_namespace, postlogin. It is used as it is, with two
#     lines added, and Fedora's later changes to it come through (the
#     security baseline shows them as a diff):
#     - pam_oo7 in the password stack, as GDM has it: a password changed at
#       login (an expired one) re-encrypts the Login keyring too;
#     - pam_env before system-auth's pam_systemd, so the autologin session
#       registers as a Wayland one (session-type.conf says why).
#     GDM's pam_selinux_permit line is left out on purpose: it lets accounts
#     that SELinux marks passwordless (xguest) in without a password, and
#     Lucciola has none.
#     No copy in /etc/pam.d: one there would shadow Fedora's file forever,
#     as the old /etc copies of GDM's files did after Fedora 45 moved them.
python3 - /usr/lib/pam.d/greetd <<'PY'
import re, sys
path = sys.argv[1]
lines = open(path).read().splitlines()
def find(rx):
    hits = [i for i, l in enumerate(lines) if re.match(rx, l)]
    if len(hits) != 1:
        sys.exit(f"ERROR: {path}: expected one line matching {rx!r}, found {len(hits)}: Fedora changed the file, review it against gdm-password")
    return hits[0]
# Everything the stack must already have, in the stages it must have it.
for rx in (r"^auth\s+substack\s+system-auth\s*$", r"^-auth\s+optional\s+pam_oo7\.so\s*$",
           r"^auth\s+include\s+postlogin\s*$", r"^account\s+required\s+pam_nologin\.so\s*$",
           r"^account\s+include\s+system-auth\s*$", r"^session\s+required\s+pam_selinux\.so\s+close\s*$",
           r"^session\s+required\s+pam_loginuid\.so\s*$", r"^session\s+required\s+pam_selinux\.so\s+open\s*$",
           r"^session\s+optional\s+pam_keyinit\.so\s+force\s+revoke\s*$", r"^session\s+required\s+pam_namespace\.so\s*$",
           r"^-session\s+optional\s+pam_oo7\.so\s+auto_start\s*$", r"^session\s+include\s+postlogin\s*$"):
    find(rx)
pw = find(r"^password\s+include\s+system-auth\s*$")
lines[pw + 1:pw + 1] = ["# Lucciola (lucciola/build.sh 5c): as gdm-password, a password changed here re-encrypts the keyring.",
                        "-password  optional    pam_oo7.so use_authtok"]
se = find(r"^session\s+include\s+system-auth\s*$")
lines[se:se] = ["# Lucciola (lucciola/build.sh 5c): wayland unless the greeter said otherwise, before pam_systemd.",
                "session    optional    pam_env.so readenv=0 user_readenv=0 conffile=/usr/share/lucciola/greetd/session-type.conf"]
open(path, "w").write("\n".join(lines) + "\n")
PY
grep -q '^-\?session.*pam_systemd\.so' /etc/pam.d/system-auth \
  || { echo "ERROR: system-auth has no pam_systemd: greetd sessions would get no logind session" >&2; exit 1; }
[[ -f /usr/share/lucciola/greetd/session-type.conf ]] || { echo "ERROR: session-type.conf missing" >&2; exit 1; }
[[ ! -e /etc/pam.d/greetd && ! -e /etc/pam.d/greetd-greeter ]] \
  || { echo "ERROR: an /etc/pam.d copy of greetd's PAM files would shadow Fedora's" >&2; exit 1; }
log "greetd PAM stack: $(grep -cvE '^[[:space:]]*(#|$)' /usr/lib/pam.d/greetd) lines, pam_oo7 in auth/password/session"

# 5d. greetd's configuration (the template says what each line is for). The
#     package's own file is %config(noreplace); written over here, in the
#     image's /etc, where the update's /etc merge brings it to installed
#     systems that never had one.
install -m 0644 /usr/share/lucciola/greetd/config.toml /etc/greetd/config.toml
rm -f /etc/greetd/config.toml.rpmnew /etc/greetd/config.toml.rpmsave
python3 - /etc/greetd/config.toml /usr/share/wayland-sessions/lucciola.desktop /usr/share/lucciola/greeter/sync.toml <<'PY'
import sys, tomllib
conf = tomllib.load(open(sys.argv[1], "rb"))
d = conf.get("default_session", {})
if not d.get("command", "").endswith("/usr/bin/noctalia-greeter-session") or d.get("user") != "greetd":
    sys.exit(f"ERROR: {sys.argv[1]} does not run Noctalia Greeter as greetd: {d}")
if "initial_session" in conf:
    sys.exit(f"ERROR: {sys.argv[1]} ships an autologin")
name = next((l.split("=", 1)[1].strip() for l in open(sys.argv[2]) if l.startswith("Name=")), "")
last = tomllib.load(open(sys.argv[3], "rb")).get("session", {}).get("last")
if last != name:
    sys.exit(f"ERROR: the greeter's seeded session '{last}' is not the session file's Name= '{name}'")
PY
sessions="$(noctalia-greeter sessions)"
grep -qx 'Lucciola' <<<"$sessions" && grep -qx 'GNOME' <<<"$sessions" \
  || { echo "ERROR: Noctalia Greeter does not list Lucciola and GNOME: $(tr '\n' ' ' <<<"$sessions")" >&2; exit 1; }
log "greeter sessions: $(tr '\n' ' ' <<<"$sessions")"

# 5e. greetd is the display manager, GDM is not. display-manager.service is
#     a symlink in /etc: the image's version reaches an installed system
#     through the update's /etc merge unless the machine changed it, and
#     lucciola-login-migrate.service handles that case (see the script).
#     The preset says the same for anything that re-applies presets.
systemctl disable gdm.service
systemctl enable greetd.service
dm="$(readlink /etc/systemd/system/display-manager.service || true)"
[[ "$dm" == */greetd.service ]] || { echo "ERROR: display-manager.service points to '${dm:-nothing}', not greetd" >&2; exit 1; }
[[ -L /usr/lib/systemd/system/graphical.target.wants/lucciola-login-migrate.service ]] \
  || { echo "ERROR: lucciola-login-migrate.service is not enabled" >&2; exit 1; }
[[ -x /usr/libexec/lucciola/login-migrate && -x /usr/libexec/lucciola/autologin-session ]] \
  || { echo "ERROR: the login helpers in /usr/libexec/lucciola are missing or not executable" >&2; exit 1; }
grep -qx 'OnFailure=gdm.service' /usr/lib/systemd/system/greetd.service.d/50-lucciola.conf \
  || { echo "ERROR: greetd.service lost its GDM fallback" >&2; exit 1; }
# Fedora orders greetd after plymouth-quit-wait.service: the boot splash
# quits, then the greeter starts (every greetd-based Fedora login screen does
# the same). Checked so a change there is noticed.
grep -q '^After=.*plymouth-quit-wait\.service' /usr/lib/systemd/system/greetd.service \
  || { echo "ERROR: greetd.service no longer waits for Plymouth to quit" >&2; exit 1; }

# 5f. /var/lib/greetd and /var/lib/noctalia-greeter come from tmpfiles.d at
#     boot, on fresh installs and updated systems alike (lucciola-greeter.conf
#     says why), so the image carries no copy of them.
rm -rf /var/lib/greetd /var/lib/noctalia-greeter
systemd-tmpfiles --dry-run --create /usr/lib/tmpfiles.d/greetd.conf /usr/lib/tmpfiles.d/lucciola-greeter.conf >/dev/null \
  || { echo "ERROR: the greetd tmpfiles entries do not parse" >&2; exit 1; }
log "login screen: greetd + noctalia-greeter $(rpm -q --qf '%{VERSION}-%{RELEASE}' noctalia-greeter), GDM kept as the fallback"

dnf5 clean all
rm -rf /var/cache/libdnf5/* /var/lib/dnf/* /var/log/dnf5.log* 2>/dev/null || true
log "done"
