#!/usr/bin/env bash
# Apps in the Noctalia palette: what lucciola-flatpak-theme-access asks of
# Flatpak (read-only access to the GTK folders and kdeglobals, Qt's KDE
# platform theme, nothing more), what lucciola-app-colors-flatpak does with
# the Zen and Vesktop community templates (copies into the Flatpak profile
# and theme folder, one import and one preference, again idempotent; never
# devtools.chrome.enabled; nothing for apps that are not there), and the
# wiring: the templates turned on, the units watching the right files,
# enabled by the build, known to the security baseline.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SF="$ROOT/lucciola/system_files"
ACCESS="$SF/usr/libexec/lucciola/flatpak-theme-access"
BRIDGE="$SF/usr/libexec/lucciola/app-colors-flatpak"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails+1)); fi
}

# --- flatpak-theme-access, on a fake flatpak --------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/flatpak" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FLATPAK_ARGS"
SH
chmod +x "$T/bin/flatpak"
FLATPAK_ARGS="$T/args" PATH="$T/bin:/usr/bin:/bin" bash "$ACCESS"
expected="override
--system
--filesystem=xdg-config/gtk-3.0:ro
--filesystem=xdg-config/gtk-4.0:ro
--filesystem=xdg-config/kdeglobals:ro
--env=QT_QPA_PLATFORMTHEME=kde"
check "access: the system-wide override, the three folders read-only, Qt's KDE theme, nothing else" test "$(cat "$T/args")" = "$expected"
check "access: never a writable path in the override" bash -c "! grep -E '^--filesystem=' '$T/args' | grep -v ':ro$'"
check "access: without flatpak it does nothing and succeeds" env PATH=/usr/bin/nonexistent:/nonexistent /bin/bash "$ACCESS"

# --- app-colors-flatpak: Zen ------------------------------------------------
H="$T/home"; ZEN="$H/.var/app/app.zen_browser.zen/.zen/abc.Default (release)"
mkdir -p "$H/.cache/noctalia/zen-browser" "$ZEN/chrome"
echo ':root { --zen-primary-color: #e6d5bf; }' > "$H/.cache/noctalia/zen-browser/zen-userChrome.css"
echo '@-moz-document url-prefix("about:") { body { background: #121212; } }' > "$H/.cache/noctalia/zen-browser/zen-userContent.css"
echo '// prefs' > "$ZEN/prefs.js"
printf '%s\n' '#urlbar { border-radius: 4px; }' > "$ZEN/chrome/userChrome.css"
printf '%s\n' 'user_pref("browser.startup.page", 3);' > "$ZEN/user.js"
run_bridge() { env -i HOME="$H" PATH=/usr/bin:/bin bash "$BRIDGE" > "$T/bridge.out" 2>&1; }
run_bridge
check "zen: the two stylesheets copied into the Flatpak profile" \
  bash -c "cmp -s '$H/.cache/noctalia/zen-browser/zen-userChrome.css' '$ZEN/chrome/noctalia-userChrome.css' && cmp -s '$H/.cache/noctalia/zen-browser/zen-userContent.css' '$ZEN/chrome/noctalia-userContent.css'"
check "zen: userChrome.css imports it first and keeps the user's own rules" \
  bash -c "[ \"\$(head -n1 '$ZEN/chrome/userChrome.css')\" = '@import url(\"noctalia-userChrome.css\");' ] && grep -qF '#urlbar { border-radius: 4px; }' '$ZEN/chrome/userChrome.css'"
check "zen: userContent.css made, with its import" grep -qxF '@import url("noctalia-userContent.css");' "$ZEN/chrome/userContent.css"
check "zen: user.js turns user stylesheets on and keeps the user's preferences" \
  bash -c "grep -qxF 'user_pref(\"toolkit.legacyUserProfileCustomizations.stylesheets\", true);' '$ZEN/user.js' && grep -qF 'browser.startup.page' '$ZEN/user.js'"
check "zen: never devtools.chrome.enabled" bash -c "! grep -q 'devtools.chrome.enabled' '$ZEN/user.js'"
run_bridge; run_bridge
check "zen: run again, one import and one preference, no more" \
  bash -c "[ \$(grep -c 'noctalia-userChrome.css' '$ZEN/chrome/userChrome.css') = 1 ] && [ \$(grep -c 'legacyUserProfileCustomizations' '$ZEN/user.js') = 1 ]"
sed -i '1i @import url("mine.css");' "$ZEN/chrome/userChrome.css"
run_bridge
check "zen: an import of the user's above ours: ours first again, one only, theirs kept" \
  bash -c "[ \"\$(head -n1 '$ZEN/chrome/userChrome.css')\" = '@import url(\"noctalia-userChrome.css\");' ] && [ \$(grep -c 'noctalia-userChrome.css' '$ZEN/chrome/userChrome.css') = 1 ] && grep -qF 'mine.css' '$ZEN/chrome/userChrome.css'"
echo ':root { --zen-primary-color: #bfd5e6; }' > "$H/.cache/noctalia/zen-browser/zen-userChrome.css"
run_bridge
check "zen: a new palette reaches the profile" grep -q '#bfd5e6' "$ZEN/chrome/noctalia-userChrome.css"

# --- app-colors-flatpak: Vesktop --------------------------------------------
mkdir -p "$H/.config/vesktop/themes" "$H/.var/app/dev.vencord.Vesktop/config/vesktop"
echo '/* noctalia midnight */' > "$H/.config/vesktop/themes/noctalia.theme.css"
echo '/* noctalia material */' > "$H/.config/vesktop/themes/noctalia-material.theme.css"
echo '/* someone else */' > "$H/.config/vesktop/themes/other.theme.css"
run_bridge
V="$H/.var/app/dev.vencord.Vesktop/config/vesktop/themes"
check "vesktop: the Noctalia themes copied into the Flatpak's theme folder" \
  bash -c "cmp -s '$H/.config/vesktop/themes/noctalia.theme.css' '$V/noctalia.theme.css' && cmp -s '$H/.config/vesktop/themes/noctalia-material.theme.css' '$V/noctalia-material.theme.css'"
check "vesktop: other themes left where they are" test ! -e "$V/other.theme.css"

# --- nothing installed: nothing made ----------------------------------------
H2="$T/empty"; mkdir -p "$H2/.cache/noctalia/zen-browser" "$H2/.config/vesktop/themes"
echo 'x' > "$H2/.cache/noctalia/zen-browser/zen-userChrome.css"; echo 'y' > "$H2/.config/vesktop/themes/noctalia.theme.css"
env -i HOME="$H2" PATH=/usr/bin:/bin bash "$BRIDGE" > /dev/null
check "no Flatpak Zen or Vesktop: no folder made under ~/.var" test ! -e "$H2/.var"

# --- wiring -----------------------------------------------------------------
TOML="$SF/usr/share/lucciola/noctalia/28-app-colors.toml"
check "templates: gtk3, gtk4 and kcolorscheme turned on" \
  bash -c "grep -qx 'enable_builtin_templates = true' '$TOML' && grep -qx 'builtin_ids = \[\"gtk3\", \"gtk4\", \"kcolorscheme\"\]' '$TOML'"
PATHU="$SF/usr/lib/systemd/user/lucciola-app-colors-flatpak.path"
check "path unit: watches the four files the two templates write" \
  bash -c "[ \$(grep -c '^PathChanged=' '$PATHU') = 4 ] && grep -qx 'PathChanged=%C/noctalia/zen-browser/zen-userChrome.css' '$PATHU' && grep -qx 'PathChanged=%E/vesktop/themes/noctalia.theme.css' '$PATHU'"
check "build: the system service and the two user units are enabled and checked" \
  bash -c "grep -qx 'systemctl enable lucciola-flatpak-theme-access.service' '$ROOT/lucciola/build.sh' && grep -qx 'systemctl --global enable lucciola-app-colors-flatpak.path lucciola-app-colors-flatpak.service' '$ROOT/lucciola/build.sh'"
check "security baseline: the three enabled units are known" \
  bash -c "[ \$(grep -cE 'lucciola-(flatpak-theme-access|app-colors-flatpak)\\.' '$ROOT/.github/security-baseline/units.txt') = 3 ]"

[ "$fails" = 0 ] && echo "app-colors: all checks passed" || { echo "app-colors: $fails check(s) failed"; exit 1; }
