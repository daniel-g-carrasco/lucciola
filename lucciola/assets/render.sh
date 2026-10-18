#!/usr/bin/env bash
# Renders every PNG of Lucciola's brand from the SVG sources in this folder.
# The PNGs are committed: the image build has no SVG renderer, Plymouth reads
# PNG only, and a reviewer sees in the diff exactly what ships. Run this
# after changing a source and commit the result.
#
# Needs rsvg-convert, python3 and (optional, lossless) optipng. Without them,
# in a throwaway Fedora container:
#   podman run --rm --security-opt label=disable -v "$PWD":/repo -w /repo \
#     quay.io/fedora/fedora:45 bash -c \
#     'dnf -y -q install librsvg2-tools python3 optipng && lucciola/assets/render.sh'
#
# Outputs (sizes say why):
#   icons/lucciola-logo-N.png   the tile at the hicolor sizes (16 to 512)
#   icons/lucciola-mark-256.png the firefly alone, for raster-only consumers
#   about/*.png                 GNOME About's distributor logo, 256 px wide:
#                               it draws the PNG's pixels as logical pixels
#   plymouth/wordmark-N.png     the word without its firefly, N px wide
#   plymouth/firefly-N.png      the firefly alone, same scale (lucciola.script)
#   plymouth/field-N.png        the password field, N px high, 9N wide
#   plymouth/bullet-N.png       one typed character for a field N px high
#   wallpaper/lucciola.svg      from make-wallpaper.py, and its PNGs
#   wallpaper/lucciola-login.*  the same scene blurred, for the login screen
set -euo pipefail
cd "$(dirname "$0")"
for t in rsvg-convert python3; do
  command -v "$t" >/dev/null || { echo "render.sh: $t not found (see the header for a container)" >&2; exit 1; }
done
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

png() {  # png SRC.svg OUT.png WIDTH HEIGHT
  rsvg-convert -w "$3" -h "$4" -o "$2" "$1"
}

# --- Icons -------------------------------------------------------------------
mkdir -p icons about plymouth
for n in 16 24 32 48 64 128 256 512; do
  png lucciola-logo.svg "icons/lucciola-logo-$n.png" "$n" "$n"
done
png lucciola-mark.svg icons/lucciola-mark-256.png 256 256

# --- About panel (fedora_logo_med = light background, the dark word) ---------
# 256 wide like Fedora's own (250), height from the 5675 x 1304 canvas.
png lucciola-wordmark-light.svg about/wordmark-on-light.png 256 59
png lucciola-wordmark.svg about/wordmark-on-dark.png 256 59

# --- Plymouth ----------------------------------------------------------------
# Two layers cut from the wordmark: the letters (the three firefly circles
# removed) and the firefly (the letters removed, the canvas cut to x 4600 to
# 5675 so the sprite stays small). lucciola.script knows these numbers.
python3 - lucciola-wordmark.svg "$tmp/letters.svg" "$tmp/firefly.svg" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
if not re.search(r'viewBox="0 0 5675 1304"', src) or src.count("<circle") != 3:
    sys.exit("render.sh: lucciola-wordmark.svg changed shape; update the Plymouth cut and lucciola.script")
letters = re.sub(r'<circle [^>]*/>', '', src)
firefly = re.sub(r'<g fill="[^"]*">.*?</g>', '', src, count=1, flags=re.S)
if firefly.count("<path") != 0:
    sys.exit("render.sh: letters still in the firefly layer")
firefly, n = re.subn(r'viewBox="0 0 5675 1304" width="\d+" height="\d+"',
                    'viewBox="4600 0 1075 1304" width="1075" height="1304"', firefly, count=1)
if n != 1:
    sys.exit("render.sh: could not cut the firefly's canvas")
open(sys.argv[2], "w").write(letters)
open(sys.argv[3], "w").write(firefly)
PY
for n in 320 480 720 1080 1620; do
  h=$(( (n * 1304 + 2837) / 5675 ))
  png "$tmp/letters.svg" "plymouth/wordmark-$n.png" "$n" "$h"
  png "$tmp/firefly.svg" "plymouth/firefly-$n.png" "$(( (n * 1075 + 2837) / 5675 ))" "$h"
done

# The field: the greeter's surface variant (#1f1f1f) with a beige outline at
# half strength, the focused-window border of Lucciola. A typed character: a
# small firefly, the beige dot with its halo, centred in a square cell.
cat > "$tmp/field.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 100">
  <rect x="2" y="2" width="896" height="96" rx="24" fill="#1f1f1f" stroke="#e6d5bf" stroke-opacity="0.5" stroke-width="3"/>
</svg>
SVG
cat > "$tmp/bullet.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <defs><radialGradient id="h"><stop offset="0" stop-color="#f0cf9c" stop-opacity="0.55"/><stop offset="1" stop-color="#f0cf9c" stop-opacity="0"/></radialGradient></defs>
  <circle cx="50" cy="50" r="46" fill="url(#h)"/>
  <circle cx="50" cy="50" r="17" fill="#e6d5bf"/>
</svg>
SVG
for n in 32 48 72 108; do
  png "$tmp/field.svg" "plymouth/field-$n.png" "$(( n * 9 ))" "$n"
  c=$(( (n * 44 + 50) / 100 ))
  png "$tmp/bullet.svg" "plymouth/bullet-$n.png" "$c" "$c"
done

# --- Wallpaper ---------------------------------------------------------------
# make-wallpaper.py writes the 3840x2400 master; each PNG is the same SVG with
# another width/height: preserveAspectRatio slice crops sky or sides, never
# the hills.
python3 -I wallpaper/make-wallpaper.py wallpaper/lucciola.svg wallpaper/lucciola-login.svg
for size in 3840x2160 2880x1920 2560x1600; do
  w="${size%x*}" h="${size#*x}"
  sed -e "0,/width=\"3840\" height=\"2400\"/s//width=\"$w\" height=\"$h\"/" wallpaper/lucciola.svg > "$tmp/wall.svg"
  rsvg-convert -o "wallpaper/lucciola-$size.png" "$tmp/wall.svg"
done

# The login screen's version: one 16:10 file the greeter crops to any
# screen. Blurred, it has no detail a bigger file would keep, so 1920x1200
# looks the same on the 2880x1920 reference as a native render and costs a
# fraction of the bytes in every update.
rsvg-convert -w 1920 -h 1200 -o wallpaper/lucciola-login.png wallpaper/lucciola-login.svg

if command -v optipng >/dev/null; then
  optipng -quiet -o2 -strip all icons/*.png about/*.png plymouth/*.png wallpaper/*.png
fi
echo "render.sh: done"
