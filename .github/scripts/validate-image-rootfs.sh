#!/usr/bin/env bash
# Layer A file-level validation of a built (pre-rechunk) Lucciola image.
#
#   usage: sudo .github/scripts/validate-image-rootfs.sh <image-ref>
#
# Extracted from build.yml's inline run: block (2026-06-12 review,
# phase 3) so it is shellcheck-gated, reviewable as a file, and
# runnable locally against any locally built image:
#   sudo .github/scripts/validate-image-rootfs.sh localhost/lucciola:latest
#
# Guardrail against the 5 first-boot regressions surfaced on the
# 2026-06-06 fresh install (Bluefin logo in About, missing welcome
# screen icon, extensions not installed, no background-Flatpak toast,
# icon-size drift). Runs BEFORE rechunk/push/SBOM/sign so a regression
# fails fast instead of leaking into :stable. The grep sentinels here
# overlap the shipped validators (run in-container by a sibling CI
# step) on purpose during the adoption window — once the in-container
# run has two green runs, the duplicated checks below get deleted.
set -euo pipefail

IMAGE_REF="${1:?usage: validate-image-rootfs.sh <image-ref>}"

# MOUNT the image, do not export it. `podman export | tar -x` wrote a
# second full copy of a ~19 GB rootfs to the runner disk and started
# failing with "No space left on device" on ubuntu-26.04, whose cleanup
# frees less than the old one did (2026-08-20). Mounting reads the
# layers already on disk: no copy, no extraction, seconds instead of
# minutes. The checks below are all read-only, so a mount is all they
# ever needed.
podman container create --replace --name validate-fs \
  --entrypoint /bin/true "$IMAGE_REF" >/dev/null
trap 'podman unmount validate-fs >/dev/null 2>&1 || true; podman rm validate-fs >/dev/null 2>&1 || true' EXIT
ROOTFS=$(podman mount validate-fs)
[[ -n "$ROOTFS" && -d "$ROOTFS" ]] || { echo "::error::could not mount $IMAGE_REF"; exit 1; }

fail=0
check_file() { [[ -f "$ROOTFS/$1" ]] || { echo "::error::missing file $1 ($2)"; fail=1; }; }
check_dir()  { [[ -d "$ROOTFS/$1" ]] || { echo "::error::missing dir $1 ($2)";  fail=1; }; }
check_nonempty() { [[ -s "$ROOTFS/$1" ]] || { echo "::error::file $1 missing or empty ($2)"; fail=1; }; }
check_exec() { [[ -x "$ROOTFS/$1" ]] || { echo "::error::not executable $1 ($2)"; fail=1; }; }

# A.1 — About-panel logo: os-release LOGO + asset on disk
if ! grep -qE '^LOGO=margine-logo$' "$ROOTFS/etc/os-release"; then
  echo "::error::A.1 /etc/os-release does not declare LOGO=margine-logo"; fail=1
fi
if [[ ! -f "$ROOTFS/usr/share/pixmaps/margine-logo.png" && ! -f "$ROOTFS/usr/share/pixmaps/margine-logo.svg" ]]; then
  echo "::error::A.1 /usr/share/pixmaps/margine-logo.{png,svg} missing"; fail=1
fi
check_nonempty "usr/share/pixmaps/fedora_logo_med.png" "A.1"
check_nonempty "usr/share/pixmaps/fedora_whitelogo_med.png" "A.1"

# A.2 — Welcome screen icon: present + non-empty (retry_curl_strict)
check_nonempty "usr/share/icons/Adwaita/symbolic/places/start-here-symbolic.svg" "A.2"
if grep -Eiq '<image[[:space:]>]|data:image/' "$ROOTFS/usr/share/icons/Adwaita/symbolic/places/start-here-symbolic.svg"; then
  echo "::error::A.2 start-here-symbolic.svg embeds a raster image; GTK4 symbolic icons require path/circle/rect primitives"; fail=1
fi

# A.3: Lucciola, niri + Noctalia, and GNOME as a STOCK fallback session.
# Since 2026-10-18 the build adds no GNOME extensions, Shell dconf defaults
# or GNOME first-login bootstrap at all (until then lucciola/build.sh
# removed what the Margine steps added; the Margine checks that used to sit
# here asserted the opposite). Assert the outcome: none of Margine's
# extensions, none of its Shell dconf defaults or first-login autostarts,
# the Lucciola session on the login screen and preselected for new users.
for uuid in \
  appindicatorsupport@rgcjonas.gmail.com \
  bazaar-integration@kolunmi.github.io \
  dash-to-dock@micxgx.gmail.com \
  gradia-integration@alexandervanhee.github.io \
  gsconnect@andyholmes.github.io \
  o-tiling@oliwebd.github.com \
  hide-cursor@elcste.com \
  caffeine@patapon.info \
  smile-extension@mijorus.it; do
  [[ ! -e "$ROOTFS/usr/share/gnome-shell/extensions/$uuid" ]] \
    || { echo "::error::A.3 GNOME extension $uuid survived: GNOME must stay stock in Lucciola"; fail=1; }
done
for f in "$ROOTFS"/etc/dconf/db/distro.d/*margine* "$ROOTFS"/etc/dconf/db/distro.d/*shell*; do
  if [[ -e "$f" ]]; then echo "::error::A.3 Margine's GNOME dconf defaults survived: ${f#"$ROOTFS"/}"; fail=1; fi
done
for f in margine-first-boot.desktop margine-first-boot-status.desktop; do
  [[ ! -e "$ROOTFS/etc/xdg/autostart/$f" ]] \
    || { echo "::error::A.3 GNOME first-login autostart etc/xdg/autostart/$f survived"; fail=1; }
done
check_file "usr/share/wayland-sessions/lucciola.desktop" "A.3"
[[ ! -e "$ROOTFS/usr/share/wayland-sessions/niri.desktop" ]] \
  || { echo "::error::A.3 the plain Niri session entry is back next to Lucciola's"; fail=1; }
grep -qx 'Exec=niri-session' "$ROOTFS/usr/share/wayland-sessions/lucciola.desktop" 2>/dev/null \
  || { echo "::error::A.3 lucciola.desktop does not run niri-session"; fail=1; }
for t in standard administrator; do
  grep -qx 'Session=lucciola' "$ROOTFS/usr/share/accountsservice/user-templates/$t" 2>/dev/null \
    || { echo "::error::A.3 AccountsService template $t does not preselect the Lucciola session"; fail=1; }
done
check_file "etc/niri/config.kdl" "A.3"
for f in session-start lock bar-widths color-calibration; do
  check_exec "usr/libexec/lucciola/$f" "A.3"
done
if grep -qs 'it\.mijorus\.smile' "$ROOTFS/usr/share/flatpak/preinstall.d/margine-defaults.preinstall"; then
  echo "::error::A.3 Smile is preinstalled again (Noctalia's launcher picks emoji)"; fail=1
fi

# A.3.login: the login screen is greetd running Noctalia Greeter, GDM its
# fallback (lucciola/build.sh step 5). -L/readlink, not -e: the image's
# absolute links dangle under $ROOTFS (see A.4.mok).
dm="$(readlink "$ROOTFS/etc/systemd/system/display-manager.service" 2>/dev/null || true)"
[[ "$dm" == */greetd.service ]] \
  || { echo "::error::A.3.login display-manager.service points to '${dm:-nothing}', not greetd"; fail=1; }
grep -qs '^command = ".*/usr/bin/noctalia-greeter-session"' "$ROOTFS/etc/greetd/config.toml" \
  || { echo "::error::A.3.login etc/greetd/config.toml does not run Noctalia Greeter"; fail=1; }
grep -qsE '^-password[[:space:]]+optional[[:space:]]+pam_oo7\.so' "$ROOTFS/usr/lib/pam.d/greetd" \
  && grep -qsE '^session[[:space:]]+optional[[:space:]]+pam_env\.so.*session-type\.conf' "$ROOTFS/usr/lib/pam.d/greetd" \
  && grep -qsE '^-auth[[:space:]]+optional[[:space:]]+pam_oo7\.so' "$ROOTFS/usr/lib/pam.d/greetd" \
  || { echo "::error::A.3.login usr/lib/pam.d/greetd lacks Lucciola's pam_oo7/pam_env lines"; fail=1; }
[[ ! -e "$ROOTFS/etc/pam.d/greetd" ]] \
  || { echo "::error::A.3.login etc/pam.d/greetd shadows Fedora's usr/lib/pam.d/greetd"; fail=1; }
grep -qsx 'OnFailure=gdm.service' "$ROOTFS/usr/lib/systemd/system/greetd.service.d/50-lucciola.conf" \
  || { echo "::error::A.3.login greetd.service has no GDM fallback"; fail=1; }
test -L "$ROOTFS/usr/lib/systemd/system/graphical.target.wants/lucciola-login-migrate.service" \
  || { echo "::error::A.3.login lucciola-login-migrate.service is not enabled"; fail=1; }
check_file "usr/lib/tmpfiles.d/lucciola-greeter.conf" "A.3.login"
check_exec "usr/libexec/lucciola/autologin-session" "A.3.login"
check_exec "usr/libexec/lucciola/login-migrate" "A.3.login"
check_exec "usr/bin/dbus-run-session" "A.3.login"

# A.4: first-boot status helper (its GNOME autostart is gone, see A.3)
check_exec "usr/libexec/margine-first-boot-status" "A.4"

# A.4.gfx — GRUB HiDPI legibility via a BAKED LARGE FONT (2026-06-16, was a
# gfxmode-low scheme that firmware ignored on amdgpu UEFI = no-op). Assert the
# image ships: the generated font, a drop-in that loadfonts it + selects it
# via gfxterm_font + switches to gfxterm, and the re-render helper (bootupd
# does NOT re-render the static config on `bootc upgrade`, so existing installs
# need `ujust margine-grub-hidpi`).
GRUB_GFX="usr/lib/bootupd/grub2-static/configs.d/05_margine-gfxmode.cfg"
check_file "$GRUB_GFX" "A.4.gfx"
check_nonempty "usr/lib/bootupd/grub2-static/fonts/margine.pf2" "A.4.gfx"
check_exec "usr/libexec/margine/grub-hidpi-apply" "A.4.gfx"
# The re-render runs automatically at boot (the bootloader on /boot isn't
# updated by image upgrades) — assert the service ships AND is enabled.
# No ordering cycles in the boot transaction. systemd "solves" a cycle by
# deleting a job of its choosing: once that was tmpfiles-setup-dev and the
# machine booted into emergency mode (2026-06-01); in 2026-09 a cycle sat
# in margine-seed-etc-passwd.service for weeks, logged at every boot and
# noticed by nobody. Evaluated against the image's own unit files.
# A silent pass must mean "no cycle", not "the tool said nothing": first
# prove on this runner that systemd-analyze reports a cycle built on purpose.
cycle_selftest() {
  local t; t="$(mktemp -d)"
  printf '[Unit]\nWants=cyc-b.service\nAfter=cyc-b.service\n[Service]\nType=oneshot\nExecStart=/bin/true\n' > "$t/cyc-a.service"
  printf '[Unit]\nWants=cyc-a.service\nAfter=cyc-a.service\n[Service]\nType=oneshot\nExecStart=/bin/true\n' > "$t/cyc-b.service"
  # Capture first, grep after: verify exits non-zero when it finds
  # problems, and under pipefail a `verify | grep -q` pipeline then counts
  # as failed even though grep matched (that made this self-test fail on
  # the first CI run while the tool was working fine).
  local out
  out="$(systemd-analyze verify --man=no "$t/cyc-a.service" "$t/cyc-b.service" 2>&1 || true)"
  rm -rf "$t"
  grep -qi "ordering cycle" <<<"$out"
}
if ! command -v systemd-analyze >/dev/null 2>&1; then
  echo "::warning::systemd-analyze not available on this runner: ordering-cycle check skipped"
elif ! cycle_selftest; then
  echo "::warning::systemd-analyze did not report a deliberately cyclic pair: ordering-cycle check not trustworthy here, skipped"
else
  # graphical.target too: the display manager and the login-screen
  # migration unit order themselves there (2026-10, greetd).
  VERIFY_OUT="$(systemd-analyze --root="$ROOTFS" verify --man=no sysinit.target multi-user.target graphical.target 2>&1 || true)"
  CYCLES="$(grep -iE "ordering cycle" <<<"$VERIFY_OUT" || true)"
  if [ -n "$CYCLES" ]; then
    echo "::error::A.4.units ordering cycle in the image's boot transaction:"
    echo "$CYCLES" | head -5
    fail=1
  else
    echo "  ok: no ordering cycle in sysinit.target / multi-user.target / graphical.target (self-test passed)"
  fi
fi
check_file "usr/lib/systemd/system/margine-grub-hidpi.service" "A.4.gfx"
test -L "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants/margine-grub-hidpi.service" \
  || { echo "::error::A.4.gfx margine-grub-hidpi.service is not enabled (multi-user.target.wants symlink missing) — GRUB font won't auto-apply"; fail=1; }
# Flatpak updates moved out of uupd (2026-09-20): both timers must be
# shipped AND enabled, and uupd's module must be off, or apps never update.
check_file "usr/lib/systemd/system/margine-flatpak-update.service" "A.4.flatpak-update"
test -L "$ROOTFS/usr/lib/systemd/system/timers.target.wants/margine-flatpak-update.timer" \
  || { echo "::error::A.4.flatpak-update margine-flatpak-update.timer is not enabled (timers.target.wants symlink missing): system Flatpaks would never update"; fail=1; }
test -L "$ROOTFS/usr/lib/systemd/user/timers.target.wants/margine-flatpak-user-update.timer" \
  || { echo "::error::A.4.flatpak-update margine-flatpak-user-update.timer is not enabled for users"; fail=1; }
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["modules"]["flatpak"]["disable"] is True else 1)' "$ROOTFS/etc/uupd/config.json" \
  || { echo "::error::A.4.flatpak-update uupd's flatpak module is still enabled in /etc/uupd/config.json: its per-user step fails under polkit"; fail=1; }
grep -q 'loadfont .*margine\.pf2' "$ROOTFS/$GRUB_GFX" 2>/dev/null \
  || { echo "::error::A.4.gfx GRUB drop-in does not loadfont the baked margine.pf2 — menu stays tiny on HiDPI"; fail=1; }
grep -q '^[[:space:]]*set gfxterm_font=' "$ROOTFS/$GRUB_GFX" 2>/dev/null \
  || { echo "::error::A.4.gfx GRUB drop-in does not set gfxterm_font — gfxterm would fall back to its tiny built-in font"; fail=1; }
grep -q 'terminal_output gfxterm' "$ROOTFS/$GRUB_GFX" 2>/dev/null \
  || { echo "::error::A.4.gfx GRUB drop-in does not switch to gfxterm"; fail=1; }

# A.4.grub-lock: `ujust margine-grub-lock` only works while bootupd's
# static GRUB config keeps reading user.cfg (GRUB2_PASSWORD). If a base
# change drops that snippet, the password would silently protect nothing,
# and TPM2 disk unlock would again be one `e` away from a root shell.
check_exec "usr/libexec/margine/grub-lock" "A.4.grub-lock"
if ! grep -qs 'GRUB2_PASSWORD' "$ROOTFS/usr/lib/bootupd/grub2-static/configs.d/01_users.cfg"; then
  echo "::error::bootupd's static GRUB config no longer reads GRUB2_PASSWORD (A.4.grub-lock)"; fail=1
fi
[[ -x "$ROOTFS/usr/bin/grub2-mkpasswd-pbkdf2" ]] \
  || { echo "::error::grub2-mkpasswd-pbkdf2 missing: margine-grub-lock cannot hash a password (A.4.grub-lock)"; fail=1; }
# Both /boot writers source this to get through a read-only /boot (recent
# bootc installs); without it they die on every run.
[[ -f "$ROOTFS/usr/libexec/margine/boot-writable.sh" ]] \
  || { echo "::error::usr/libexec/margine/boot-writable.sh missing: grub-lock and grub-hidpi-apply cannot write to a read-only /boot (A.4.grub-lock)"; fail=1; }

# A.4.keyring — login keyring on oo7 (Fedora 45). margine-keyring opens the
# keyring at login with a TPM-bound credential (fingerprint, autologin);
# keyring-legacy-aside runs before oo7-daemon so a Fedora 44 plaintext
# keyring cannot stop it, keyring-import-legacy moves its items over; the
# D-Bus activation file starts oo7 outside GNOME's session target (Lucciola).
check_exec "usr/bin/margine-keyring" "A.4.keyring"
check_exec "usr/bin/seahorse" "A.4.keyring"
check_exec "usr/libexec/margine/keyring-legacy-aside" "A.4.keyring"
check_exec "usr/libexec/margine/keyring-import-legacy" "A.4.keyring"
for f in usr/lib/systemd/user/oo7-daemon.service.d/50-margine-keyring-legacy.conf \
         usr/share/dbus-1/services/org.freedesktop.secrets.service \
         usr/lib/systemd/user/graphical-session.target.wants/margine-keyring-import.service; do
  [[ -e "$ROOTFS/$f" ]] || { echo "::error::$f missing (A.4.keyring)"; fail=1; }
done

# A.4.repro: leftovers that made identical builds differ (2026-10-03).
# adb keys in root's home would be one private key shared by every
# install of the same build. (The offline docs' Cloudflare-obfuscated text
# was the other one; the docs left on 2026-10-18.)
if [[ -e "$ROOTFS/var/roothome/.android" ]]; then
  echo "::error::var/roothome/.android (adb keys) shipped in the image (A.4.repro)"; fail=1
fi

# A.4.selinux-home: /home must map to /var/home, never the reverse
# (ublue-os/bluefin#4976): with "/var/home /home" every path in a home
# resolves to default_t and a restorecon breaks SSH key login.
SUBS="etc/selinux/targeted/contexts/files/file_contexts.subs_dist"
check_file "$SUBS" "A.4.selinux-home"
if [[ -f "$ROOTFS/$SUBS" ]]; then
  if grep -qE '^/var/home[[:space:]]' "$ROOTFS/$SUBS"; then
    echo "::error::$SUBS maps /var/home to /home (A.4.selinux-home)"; fail=1
  fi
  if ! grep -qE '^/home[[:space:]]+/var/home[[:space:]]*$' "$ROOTFS/$SUBS"; then
    echo "::error::$SUBS has no '/home /var/home' line (A.4.selinux-home)"; fail=1
  fi
fi

# A.4.mok: the Margine key must be enrolled even while Secure Boot is
# off, every boot until shim has it (2026-10-04): the old unit skipped
# the import with Secure Boot off and stamped /var/.mok-enrolled, so
# turning Secure Boot on later left the Margine kernel unbootable.
check_exec "usr/libexec/margine/mok-enroll" "A.4.mok"
check_exec "usr/libexec/margine/mok-notify" "A.4.mok"
check_file "usr/lib/systemd/system/mok-enroll.service" "A.4.mok"
check_file "usr/lib/systemd/user/graphical-session.target.wants/margine-mok-notify.service" "A.4.mok"
if [[ -f "$ROOTFS/usr/lib/systemd/system/mok-enroll.service" ]]; then
  grep -q '^ExecStart=/usr/libexec/margine/mok-enroll$' "$ROOTFS/usr/lib/systemd/system/mok-enroll.service" \
    || { echo "::error::mok-enroll.service does not run /usr/libexec/margine/mok-enroll (A.4.mok)"; fail=1; }
  if grep -q 'mok-enrolled' "$ROOTFS/usr/lib/systemd/system/mok-enroll.service"; then
    grep -n 'mok-enrolled' "$ROOTFS/usr/lib/systemd/system/mok-enroll.service" | grep -qv '^[0-9]*:#' \
      && { echo "::error::mok-enroll.service still gates on a one-shot marker (A.4.mok)"; fail=1; }
  fi
fi
# -L, not -e: `systemctl enable` in the build writes an ABSOLUTE link
# (/usr/lib/systemd/system/...), which dangles when the image is mounted
# under $ROOTFS on the runner, so -e reported an enabled unit as missing.
[[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/mok-enroll.service" || -L "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants/mok-enroll.service" ]] \
  || { echo "::error::mok-enroll.service is not enabled (A.4.mok)"; fail=1; }

# A.4.trust: devices must verify the image signature on update (2026-10-06).
# Before this, policy.json had no scope for the image's repository and pulls
# fell through to the catch-all insecureAcceptAnything: "signed" transports
# verified nothing. Two scopes, one key: ghcr.io/daniel-g-carrasco/lucciola,
# what this image updates from, and the Margine repository it shares the
# signing key with (an install moved here from margine:lucciola keeps a
# verified way back).
check_nonempty "usr/lib/pki/containers/margine.pub" "A.4.trust"
for r in margine lucciola; do
  grep -qs 'use-sigstore-attachments: true' "$ROOTFS/etc/containers/registries.d/$r.yaml" \
    || { echo "::error::registries.d/$r.yaml missing or without use-sigstore-attachments (A.4.trust)"; fail=1; }
done
if ! python3 - "$ROOTFS/etc/containers/policy.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
for repo in ("ghcr.io/daniel-g-carrasco/lucciola", "ghcr.io/daniel-g-carrasco/margine"):
    r = p["transports"]["docker"][repo][0]
    assert r["type"] == "sigstoreSigned" and r["keyPath"] == "/usr/lib/pki/containers/margine.pub"
assert p["transports"]["docker"].get("ghcr.io/ublue-os"), "base scope lost"
PY
then
  echo "::error::policy.json lacks a sigstoreSigned scope for ghcr.io/daniel-g-carrasco/lucciola or .../margine, or lost the base ones (A.4.trust)"; fail=1
fi
test -L "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants/margine-signed-origin.service" \
  || { echo "::error::margine-signed-origin.service is not enabled (A.4.trust)"; fail=1; }
check_exec "usr/libexec/margine/signed-origin" "A.4.trust"

# A.4.bis — desktop launchers have high-res icons. The offline docs, their
# launcher and their refresh timer left on 2026-10-18 (Lucciola's guide is
# online): none of them may come back by accident.
check_nonempty "usr/share/icons/hicolor/scalable/apps/margine-scheduler.svg" "A.4.bis"
grep -qxF 'Icon=margine-scheduler' "$ROOTFS/usr/share/applications/margine-scheduler.desktop" || { echo "::error::A.4.bis scheduler launcher does not use margine-scheduler icon"; fail=1; }
for f in usr/share/margine/offline-docs usr/share/applications/margine-documentation.desktop \
         usr/bin/margine-docs-open usr/lib/systemd/system/margine-docs-refresh.timer; do
  if [[ -e "$ROOTFS/$f" ]]; then echo "::error::$f is back in the image (A.4.bis: the offline docs left on 2026-10-18)"; fail=1; fi
done

# A.5 — REMOVED (org.gnome.shell.app-grid schema does not exist in
# GNOME 47/48; the keys we tried to set are ignored. Icon-size drift
# between app-grid/folder is a CSS theme issue, not a gschema one).

# A.3.bis: the dconf profile still reads the distro database. The build
# puts no Shell defaults there (A.3); the database stays for authselect's
# defaults.
grep -qxF 'system-db:distro' "$ROOTFS/etc/dconf/profile/user" || { echo "::error::A.3.bis /etc/dconf/profile/user lacks system-db:distro"; fail=1; }

# A.3.ter — downstream patches + branding must land on the FINAL image
# (added 2026-06-12). These assert OUTCOMES, independent of how the build
# scripts behave.
test -s "$ROOTFS/usr/share/icons/hicolor/scalable/apps/margine-logo.svg" \
  || { echo "::error::A.3.ter margine-logo.svg missing from hicolor"; fail=1; }
test -s "$ROOTFS/usr/share/icons/hicolor/scalable/apps/fedora-logo-icon.svg" \
  || { echo "::error::A.3.ter fedora-logo-icon.svg missing (fedora-welcome + gnome-initial-setup hardcode it)"; fail=1; }
test -s "$ROOTFS/usr/share/pixmaps/fedora_logo_med.png" \
  || { echo "::error::A.3.ter About wordmark (fedora_logo_med.png) missing"; fail=1; }
if cmp -s "$ROOTFS/usr/share/pixmaps/fedora_logo_med.png" "$ROOTFS/usr/share/pixmaps/fedora_whitelogo_med.png"; then
  echo "::error::A.3.ter About wordmark dark/light variants are byte-identical (theme differentiation lost)"; fail=1
fi
test -x "$ROOTFS/usr/libexec/margine/staged-update-notify" \
  || { echo "::error::A.3.ter staged-update-notify missing"; fail=1; }

if (( fail != 0 )); then
  echo "::error::First-boot asset validation FAILED — blocking rechunk/push/sign."
  exit 1
fi
echo "✓ First-boot asset + keybinding-conflict validation PASSED"
