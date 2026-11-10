#!/usr/bin/env bash
# bar-widths' lock screen part, on a fake niri and fprintd and temp folders. What
# must hold: every monitor gets the arrangement at its own size, the account's
# name and picture, the fingerprint line only with a print enrolled, weather only
# with a location; saved widgets switched off are retired once, and widgets
# switched on are left alone.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BW="$ROOT/lucciola/system_files/usr/libexec/lucciola/bar-widths"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null || true; fails=$((fails + 1)); fi
}
mkdir -p "$T/bin" "$T/pictures"
cat > "$T/bin/niri" <<'SH'
#!/bin/sh
case "$*" in
  *outputs*) cat "$FAKE/outputs.json" ;;
  *workspaces*) echo '[{"name": "1", "output": "eDP-1"}]' ;;
esac
SH
cat > "$T/bin/fprintd-list" <<'SH'
#!/bin/sh
[ -e "$FAKE/enrolled" ] && echo " - #0: right-index-finger" || echo "User has no fingers enrolled"
SH
chmod +x "$T/bin/"*
export FAKE="$T/fake"; mkdir -p "$FAKE"
cat > "$FAKE/outputs.json" <<'J'
{"eDP-1": {"logical": {"width": 1440, "height": 960}},
 "DP-3": {"logical": {"width": 2560, "height": 1440}},
 "HDMI-A-1": {"logical": null}}
J
ME="$(id -un)"
fresh() { rm -rf "${T:?}/home"; mkdir -p "$T/home/.config/noctalia" "$T/home/.local/state/noctalia"; rm -f "$T/pictures/"*; }
run() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" FAKE="$FAKE" LUCCIOLA_ACCOUNT_PICTURES="$T/pictures" \
    /usr/bin/python3 "$BW" --once > "$T/out" 2>&1
}
FRAGMENT="$T/home/.config/noctalia/31-lucciola-lock.toml"
SAVED="$T/home/.local/state/noctalia/settings.toml"
q() {  # q <python expression on w (the widgets) and d (the whole file)>: true or not
  /usr/bin/python3 -I - "$FRAGMENT" "$1" > "$T/out" 2>&1 <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
w = d.get("lockscreen_widgets", {}).get("widget", {})
ok = eval(sys.argv[2])
print(ok)
sys.exit(0 if ok else 1)
PY
}

fresh; rm -f "$FAKE/enrolled"; run
check "the script runs" [ -f "$FRAGMENT" ]
check "the fragment is valid TOML and switched on" q 'd["lockscreen_widgets"]["enabled"] is True'
check "a login box for each monitor that is on" q '{k for k in w if k.startswith("lockscreen-login-box@")} == {"lockscreen-login-box@eDP-1", "lockscreen-login-box@DP-3"}'
check "no widget for a monitor that is off" q 'not any(v["output"] == "HDMI-A-1" for v in w.values())'
check "every widget in the order, and only those" q 'set(d["lockscreen_widgets"]["widget_order"]) == set(w)'
check "the field: a dark fill, half see-through" q 'w["lockscreen-login-box@eDP-1"]["settings"]["input_opacity"] == 0.5'
check "the field alone is centred: the box leans by the eye" q 'w["lockscreen-login-box@eDP-1"]["cx"] == 743.0'
check "the laptop: field where the login has it" q 'w["lockscreen-login-box@eDP-1"]["cy"] == 525.0'
check "the laptop: picture and name centred" q 'w["lucciola-picture-edp_1"]["cx"] == 720.0 and w["lucciola-name-edp_1"]["cx"] == 720.0'
check "the laptop: last icon in the corner" q 'w["lucciola-poweroff-edp_1"]["cx"] == 1405.0 and w["lucciola-poweroff-edp_1"]["cy"] == 925.0'
check "a big monitor: its own centre and corner" q 'w["lucciola-picture-dp_3"]["cx"] == 1280.0 and w["lucciola-poweroff-dp_3"]["cx"] == 2525.0 and w["lucciola-poweroff-dp_3"]["cy"] == 1405.0'
check "the placement is the monitor's size" q 'w["lockscreen-login-box@DP-3"]["placement_width"] == 2560.0 and w["lockscreen-login-box@DP-3"]["placement_height"] == 1440.0'
check "the eye stays, the confirm button and the hint go" q 'all((lambda s: s["show_password_reveal"] and not s["show_login_button"] and not s["show_unlock_hint"] and s["show_caps_lock"])(w[k]["settings"]) for k in w if k.startswith("lockscreen-login-box@"))'
check "the name is the account's" q 'w["lucciola-name-edp_1"]["settings"]["title"] == "'"$ME"'"'
check "the four session actions, with the real commands" q '[w["lucciola-%s-edp_1" % a]["settings"]["command"] for a in ("suspend", "reboot", "poweroff")] == ["systemctl suspend", "systemctl reboot", "systemctl poweroff"] and "logout" in w["lucciola-logout-edp_1"]["settings"]["glyph"]'
check "no account picture: the firefly" q 'w["lucciola-picture-edp_1"]["settings"]["image_path"] == "/usr/share/lucciola/avatar/lucciola.png"'
check "no fingerprint: no line" q '"lucciola-fingerprint-edp_1" not in w'
check "no location: no weather" q '"lucciola-weather-edp_1" not in w'

fresh; : > "$FAKE/enrolled"; : > "$T/pictures/$ME"
printf '[location]\nauto_locate = true\n' > "$SAVED"; run
check "a fingerprint: the line under the field" q 'w["lucciola-fingerprint-edp_1"]["cy"] == 571.0 and "fingerprint reader" in w["lucciola-fingerprint-edp_1"]["settings"]["format"] and "{" not in w["lucciola-fingerprint-edp_1"]["settings"]["format"]'
check "what is playing: Lucciola's own strip, sized by itself, under the fingerprint line" q 'w["lucciola-media-edp_1"]["type"] == "lucciola/now_playing:strip" and w["lucciola-media-edp_1"]["box_width"] == 0.0 and w["lucciola-media-edp_1"]["cy"] - 30 >= w["lucciola-fingerprint-edp_1"]["cy"] + 9 + 16 and w["lucciola-media-edp_1"]["settings"]["background"] is False'
check "a location: weather under the clock" q 'w["lucciola-weather-edp_1"]["cy"] == w["lucciola-clock-edp_1"]["cy"] + 82'
check "an account picture: that one" q 'w["lucciola-picture-edp_1"]["settings"]["image_path"] == "'"$T/pictures/$ME"'"'

# Saved widgets switched off: retired once, the rest of the file untouched.
fresh; cat > "$SAVED" <<'TOML'
config_version = 15

[dock]
enabled = true

[lockscreen_widgets]
enabled = false
schema_version = 2
widget_order = [
    "lockscreen-login-box@DP-2",
    "lockscreen-login-box@eDP-1"
]

    [lockscreen_widgets.grid]
    cell_size = 16

    [lockscreen_widgets.widget."lockscreen-login-box@DP-2"]
    cx = 960.0

        [lockscreen_widgets.widget."lockscreen-login-box@DP-2".settings]
        layout = "regular"

[plugins]
enabled = [ "lucciola/updates" ]
TOML
cp "$SAVED" "$T/before"; run
saved() { /usr/bin/python3 -I -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); sys.exit(0 if eval(sys.argv[2]) else 1)' "$SAVED" "$1"; }
check "saved widgets switched off go" saved '"lockscreen_widgets" not in d'
check "the rest of the saved settings stays" saved 'd["dock"]["enabled"] is True and d["plugins"]["enabled"] == ["lucciola/updates"] and d["config_version"] == 15'
check "a copy of what was there" cmp -s "$T/before" "$SAVED.bak-lock-widgets"
printf '\n[lockscreen_widgets]\nenabled = false\n' >> "$SAVED"; run
check "once only: what is saved afterwards stays" saved '"lockscreen_widgets" in d'

# Saved widgets switched on are someone's own.
fresh; printf '[lockscreen_widgets]\nenabled = true\nwidget_order = []\n' > "$SAVED"; cp "$SAVED" "$T/before"; run
check "saved widgets switched on stay" cmp -s "$T/before" "$SAVED"

# A saved file Noctalia could not read itself is left alone, and nothing breaks.
fresh; printf 'not toml [[[\n' > "$SAVED"; cp "$SAVED" "$T/before"; run
check "an unreadable saved file stays" cmp -s "$T/before" "$SAVED"
check "and the fragment is still written" [ -f "$FRAGMENT" ]

# A lock step that fails says so and leaves the bar's file written.
fresh; mkdir "$FRAGMENT.new"; printf '{"eDP-1": {"logical": {"width": 3000, "height": 2000}}}' > "$FAKE/one.json"; cp "$FAKE/outputs.json" "$T/outputs.keep"; cp "$FAKE/one.json" "$FAKE/outputs.json"; run; RC=$?
check "a failing lock step does not stop the script" [ "$RC" = 0 ]
check "it says so" grep -q 'lock screen arrangement not updated' "$T/out"
check "the bar's file is written all the same" grep -q 'margin_ends' "$T/home/.config/noctalia/30-lucciola-monitors.toml"
cp "$T/outputs.keep" "$FAKE/outputs.json"

# niri not answering: no fragment from nothing, no failure.
fresh; mv "$T/bin/niri" "$T/niri.off"; run
check "no niri: runs, writes nothing" [ ! -e "$FRAGMENT" ]
mv "$T/niri.off" "$T/bin/niri"

# Noctalia's saved copies of this script's widgets (2026-11-10: the player of
# 5 November stayed through two updates). The first time they all go, a
# widget of the user's own stays and the order is rewritten around it.
RECORD="$T/home/.local/state/lucciola/lock-generated.json"
fresh; touch "$FAKE/enrolled"; cat > "$SAVED" <<'TOML'
config_version = 15

[audio]
sound_volume = 0.3

[lockscreen_widgets]
enabled = true
schema_version = 2
widget_order = [
    "lucciola-clock-edp_1",
    "lucciola-media-edp_1",
    "mine",
    "lockscreen-login-box@eDP-1"
]

    [lockscreen_widgets.grid]
    cell_size = 16

    [lockscreen_widgets.widget."lockscreen-login-box@eDP-1"]
    box_width = 471.0
    cy = 525.0
    type = "login_box"

        [lockscreen_widgets.widget."lockscreen-login-box@eDP-1".settings]
        input_opacity = 0.0

    [lockscreen_widgets.widget.lucciola-media-edp_1]
    box_height = 96.0
    box_width = 420.0
    type = "media_player"

        [lockscreen_widgets.widget.lucciola-media-edp_1.settings]
        background = true

    [lockscreen_widgets.widget.mine]
    cx = 100.0
    type = "label"

        [lockscreen_widgets.widget.mine.settings]
        title = "hello"

[plugins]
enabled = [ "lucciola/keep_awake" ]
TOML
cp "$SAVED" "$T/before"; run
check "first time: the saved copies of Lucciola's widgets go" saved '[k for k in d["lockscreen_widgets"]["widget"]] == ["mine"]'
check "a widget of the user's own stays, with its settings" saved 'd["lockscreen_widgets"]["widget"]["mine"]["settings"]["title"] == "hello"'
check "the order is this arrangement's widgets, then theirs" saved 'd["lockscreen_widgets"]["widget_order"][0] == "lucciola-clock-dp_3" and d["lockscreen_widgets"]["widget_order"][-1] == "mine" and "lucciola-media-edp_1" in d["lockscreen_widgets"]["widget_order"] and "lockscreen-login-box@eDP-1" in d["lockscreen_widgets"]["widget_order"]'
check "the rest of the saved file is untouched" saved 'd["audio"]["sound_volume"] == 0.3 and d["plugins"]["enabled"] == ["lucciola/keep_awake"] and d["lockscreen_widgets"]["grid"]["cell_size"] == 16 and d["lockscreen_widgets"]["enabled"] is True'
check "a copy of what was there, and a record of what was generated" bash -c "cmp -s '$T/before' '$SAVED.bak-lock-release' && grep -q 'lucciola-media-edp_1' '$RECORD'"
check "so the new player shows" q 'w["lucciola-media-edp_1"]["type"] == "lucciola/now_playing:strip"'

# Later: Noctalia saved its copy of what was generated (it adds keys) and the
# user moved the clock. The copy goes, the edit stays, and with nothing of the
# user's own in it the saved order goes too.
/usr/bin/python3 -I - "$FRAGMENT" "$SAVED" <<'PY'
import json, sys, tomllib
w = tomllib.load(open(sys.argv[1], "rb"))["lockscreen_widgets"]["widget"]
def table(wid, t, extra):
    t = dict(t, **extra)
    settings = t.pop("settings", {})
    out = f'[lockscreen_widgets.widget."{wid}"]\n' + "".join(f"{k} = {json.dumps(v)}\n" for k, v in t.items())
    return out + f'[lockscreen_widgets.widget."{wid}".settings]\n' + "".join(f"{k} = {json.dumps(v)}\n" for k, v in settings.items())
text = '[lockscreen_widgets]\nenabled = true\nwidget_order = ["lucciola-clock-edp_1", "lucciola-media-edp_1", "lucciola-name-edp_1"]\n\n'
text += table("lucciola-media-edp_1", w["lucciola-media-edp_1"], {"placement_width": 1440.0, "placement_height": 960.0})
text += table("lucciola-name-edp_1", w["lucciola-name-edp_1"], {"placement_width": 1440.0})
text += table("lucciola-clock-edp_1", w["lucciola-clock-edp_1"], {"cy": 300.0})
open(sys.argv[2], "w").write(text + '\n[plugins]\nenabled = [ "x" ]\n')
PY
run
check "later: Noctalia's own copies go, an edited widget stays" saved '[k for k in d["lockscreen_widgets"].get("widget", {})] == ["lucciola-clock-edp_1"] and d["lockscreen_widgets"]["widget"]["lucciola-clock-edp_1"]["cy"] == 300.0'
check "with nothing of the user's own in it, the saved order goes" saved '"widget_order" not in d["lockscreen_widgets"] and d["plugins"]["enabled"] == ["x"]'
cp "$SAVED" "$T/before"; run
check "and a second run changes nothing more" cmp -s "$T/before" "$SAVED"
fresh; printf 'not toml [[[\n' > "$SAVED"; cp "$SAVED" "$T/before"; run
check "an unreadable saved file stays, the arrangement is still written" bash -c "cmp -s '$T/before' '$SAVED' && [ -f '$FRAGMENT' ]"

# The pieces the strip needs, and the veil behind everything.
N="$ROOT/lucciola/system_files/usr/share/lucciola/noctalia"
check "the strip's plugin is there: a desktop widget called strip" bash -c "grep -q '^id = \"lucciola/now_playing\"' '$N/plugins/now_playing/plugin.toml' && grep -A2 '^\[\[desktop_widget\]\]' '$N/plugins/now_playing/plugin.toml' | grep -q '^id = \"strip\"' && [ -s '$N/plugins/now_playing/strip.luau' ]"
check "the plugin is enabled, and offered to accounts with a saved list" bash -c "grep -q '^enabled = .*\"lucciola/now_playing\"' '$N/27-keep-awake.toml' && grep -qx 'offer_plugin lucciola/now_playing' '$ROOT/lucciola/system_files/usr/libexec/lucciola/session-start'"
check "the strip asks the helper, which is in the image" bash -c "grep -q '/usr/libexec/lucciola/now-playing' '$N/plugins/now_playing/strip.luau' && [ -x '$ROOT/lucciola/system_files/usr/libexec/lucciola/now-playing' ]"
check "the wallpaper behind a soft blur and a dark veil" bash -c "grep -qx 'blur_intensity = 0.5' '$N/24-lock-screen.toml' && grep -qx 'tint_intensity = 0.55' '$N/24-lock-screen.toml'"

if (( fails )); then echo "$fails lock-look case(s) failed"; exit 1; fi
echo "all lock-look cases passed"
