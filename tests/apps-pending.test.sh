#!/usr/bin/env bash
# The slim and naked app sets chosen while the first-boot app install still
# runs (/usr/libexec/lucciola/feature, trim and apps_apply_pending): the
# choice waits in a file, the end of flatpak-preinstall.service applies it,
# and without a choice that end does nothing. On fake flatpak and systemctl,
# as root in a user namespace (unshare -r), so nothing on the machine is
# touched; where user namespaces are blocked (Ubuntu's AppArmor on the CI
# runners) through passwordless sudo, still on the fakes only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEATURE="$ROOT/build_files/system_files/usr/libexec/lucciola/feature"
DROPIN="$ROOT/build_files/system_files/usr/lib/systemd/system/flatpak-preinstall.service.d/20-lucciola-apps-profile.conf"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null || true; fails=$((fails + 1)); fi
}
if unshare -r true 2>/dev/null; then AS_ROOT=(unshare -r)
elif sudo -n true 2>/dev/null; then AS_ROOT=(sudo -n)
else echo "apps-pending: no user namespace and no passwordless sudo here, skipped"; exit 0
fi
export FAKE="$T/fake"; mkdir -p "$T/bin" "$FAKE"
cat > "$T/bin/flatpak" <<'SH'
#!/bin/sh
case "$1 $2" in
  "info --system") [ -e "$FAKE/apps/$3" ] ;;
  "uninstall --system") for a; do [ -e "$FAKE/apps/$a" ] && rm -f "$FAKE/apps/$a" && echo "removed $a" >> "$FAKE/log"; done; true ;;
  *) true ;;
esac
SH
cat > "$T/bin/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >> "$FAKE/log"
case "$*" in *is-enabled*) [ -e "$FAKE/masked" ] && echo masked || echo enabled ;; "mask "*) : > "$FAKE/masked" ;; esac
true
SH
chmod +x "$T/bin/"*
PENDING="$T/state/apps-profile-pending"
run() {  # run <feature args...>
  RC=0
  "${AS_ROOT[@]}" env -i PATH="$T/bin:/usr/bin:/bin" FAKE="$FAKE" LUCCIOLA_APPS_PENDING="$PENDING" \
    bash "$FEATURE" "$@" > "$T/out" 2>&1 || RC=$?
}
reset() {  # the first-boot install halfway: GIMP there, the browser not yet
  rm -rf "$FAKE" "$T/state"; mkdir -p "$FAKE/apps"
  : > "$FAKE/log"; touch "$FAKE/apps/org.gimp.GIMP" "$FAKE/apps/org.libreoffice.LibreOffice"
}
log() { cat "$FAKE/log"; }

reset; run slim install
check "slim during the install: accepted, the choice waits (rc $RC)" bash -c "[ '$RC' = 0 ] && [ \"\$(cat '$PENDING')\" = slim ] && grep -q 'applied as soon as it finishes' '$T/out'"
check "nothing masked or removed yet" bash -c "! grep -q 'mask\|removed' '$FAKE/log'"
run slim status
check "status says it is chosen and waits" bash -c "grep -qx 'state=partial' '$T/out' && grep -q 'when the first-boot app install finishes' '$T/out'"
run slim apply-pending
check "the install ends without the browser: the choice keeps waiting" bash -c "[ '$RC' = 0 ] && [ -s '$PENDING' ] && ! grep -q 'mask' '$FAKE/log'"
touch "$FAKE/apps/app.zen_browser.zen"; run slim apply-pending
check "the install ends with the browser: masked, not stopped, GIMP gone, the choice done" bash -c "[ '$RC' = 0 ] && grep -qx 'systemctl mask flatpak-preinstall.service' '$FAKE/log' && ! grep -q 'systemctl stop' '$FAKE/log' && grep -qx 'removed org.gimp.GIMP' '$FAKE/log' && [ ! -e '$PENDING' ]"
check "slim keeps LibreOffice" test -e "$FAKE/apps/org.libreoffice.LibreOffice"

reset; run naked install; touch "$FAKE/apps/app.zen_browser.zen"; run slim apply-pending
check "naked waits and is applied as naked: LibreOffice goes too" bash -c "grep -qx 'removed org.libreoffice.LibreOffice' '$FAKE/log' && grep -qx 'removed org.gimp.GIMP' '$FAKE/log'"

reset; touch "$FAKE/apps/app.zen_browser.zen"; run slim apply-pending
check "no choice: the end of the install does nothing" bash -c "[ '$RC' = 0 ] && [ ! -s '$FAKE/log' ]"
run slim install
check "slim after the install: stopped, masked, removed at once" bash -c "grep -q 'systemctl stop flatpak-preinstall.service' '$FAKE/log' && grep -qx 'systemctl mask flatpak-preinstall.service' '$FAKE/log' && grep -qx 'removed org.gimp.GIMP' '$FAKE/log'"

reset; mkdir -p "$T/state"; echo bogus > "$PENDING"; touch "$FAKE/apps/app.zen_browser.zen"; run slim apply-pending
check "an unknown choice is said, dropped, and changes nothing" bash -c "grep -q 'unknown pending app set' '$T/out' && [ ! -e '$PENDING' ] && ! grep -q 'mask\|removed' '$FAKE/log'"
run gaming apply-pending
check "apply-pending is refused for another feature" [ "$RC" != 0 ]

check "the service applies a waiting choice after each run, and never fails for it" grep -qx 'ExecStartPost=-/usr/libexec/lucciola/feature slim apply-pending' "$DROPIN"

if (( fails )); then echo "$fails apps-pending case(s) failed"; exit 1; fi
echo "apps-pending: all checks passed"
