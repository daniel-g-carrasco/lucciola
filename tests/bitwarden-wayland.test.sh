#!/usr/bin/env bash
# bitwarden-wayland (/usr/libexec/lucciola/bitwarden-wayland) in a throwaway
# home with fake flatpak and systemctl: enable writes its three override keys
# and enables the link unit, disable takes exactly those away, the user's other
# overrides for Bitwarden stay, status follows, nothing happens for a PC
# without Bitwarden; the unit links the socket under the second name.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BW="$ROOT/build_files/system_files/usr/libexec/lucciola/bitwarden-wayland"
UNIT="$ROOT/build_files/system_files/usr/lib/systemd/user/lucciola-bitwarden-wayland-link.service"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/out" 2>/dev/null; fails=$((fails+1)); fi; }
mkdir -p "$T/bin" "$T/home"
cat > "$T/bin/flatpak" <<'SH'
#!/bin/sh
echo "flatpak $*" >> "$FAKE_LOG"
case "$1" in info) [ -f "$FAKE_INSTALLED" ] ;; *) exit 0 ;; esac
SH
cat > "$T/bin/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >> "$FAKE_LOG"
case "$*" in
  *is-enabled*) [ -f "$FAKE_ENABLED" ] ;;
  *" enable "*) : > "$FAKE_ENABLED" ;;
  *" disable "*) rm -f "$FAKE_ENABLED" ;;
esac
exit 0
SH
chmod +x "$T/bin/"*
run() { RC=0; env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" FAKE_LOG="$T/log" FAKE_INSTALLED="$T/installed" FAKE_ENABLED="$T/enabled" bash "$BW" "$@" > "$T/out" 2>&1 || RC=$?; }
O="$T/home/.local/share/flatpak/overrides/com.bitwarden.desktop"

run status; check "no Bitwarden: absent" grep -qx absent "$T/out"
run enable; check "no Bitwarden: enable refuses (rc $RC)" bash -c "[ $RC != 0 ] && [ ! -e '$O' ]"
: > "$T/installed"; mkdir -p "$(dirname "$O")"
printf '[Context]\nfilesystems=xdg-documents;\n\n[Environment]\nFOO=bar\n' > "$O"
run status; check "installed, untouched: off" grep -qx off "$T/out"
run enable
check "enable: the second socket name, the Wayland display, Wayland mode" bash -c "grep -qx 'filesystems=xdg-documents;xdg-run/bitwarden-wayland;' '$O' && grep -qx 'WAYLAND_DISPLAY=bitwarden-wayland' '$O' && grep -qx 'DISPLAY_MODE=WAYLAND' '$O'"
check "enable: the user's own overrides stay" bash -c "grep -qx 'FOO=bar' '$O'"
check "enable: the link unit enabled and started, Bitwarden closed" bash -c "grep -q 'systemctl --user enable --now lucciola-bitwarden-wayland-link.service' '$T/log' && grep -q 'flatpak kill com.bitwarden.desktop' '$T/log'"
run status; check "status after enable: on" grep -qx on "$T/out"
run enable; check "enable twice: one entry each" bash -c "[ \$(grep -o 'xdg-run/bitwarden-wayland' '$O' | wc -l) = 1 ] && [ \$(grep -c 'WAYLAND_DISPLAY' '$O') = 1 ]"
run disable
check "disable: its keys gone, the user's stay" bash -c "! grep -q 'bitwarden-wayland\|DISPLAY_MODE' '$O' && grep -qx 'filesystems=xdg-documents;' '$O' && grep -qx 'FOO=bar' '$O'"
run status; check "status after disable: off" grep -qx off "$T/out"
rm -f "$O"; run enable; run disable; check "disable with nothing else in the override: no file left" test ! -e "$O"
check "unit: links the session socket under the second name before autostart" bash -c "grep -q 'ln -f \"\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY\" \"\$XDG_RUNTIME_DIR/bitwarden-wayland\"' '$UNIT' && grep -qx 'Before=xdg-desktop-autostart.target' '$UNIT'"
check "the build does not enable it for everyone" bash -c "! grep -q 'bitwarden-wayland-link' '$ROOT/lucciola/build.sh'"
if (( fails )); then echo "$fails bitwarden-wayland check(s) failed"; exit 1; fi
echo "bitwarden-wayland: all checks passed"
