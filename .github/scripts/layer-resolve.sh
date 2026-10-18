#!/usr/bin/env bash
# Does an on-demand layer resolve against this image, the way its ujust
# recipe will layer it?
#
#   usage: layer-resolve.sh <image-ref> <layer>
#          layer: gaming-native  (ujust lucciola-gaming-native)
#                 developer      (ujust lucciola-devmode)
#   exit:  0 resolves, 1 does not resolve (or no package list, or the
#          layer's repository cannot be set up), 2 could not tell (the
#          repositories did not load, three attempts)
#
# Each layer's package list lives in the image (/usr/share/margine/), the
# same file its recipe reads. The developer layer needs a repository the
# image does not enable (Microsoft's, for VS Code): the check adds it with
# the image's own helper, `devmode repo`, as the recipe does, so a rotated
# signing key fails here before it fails on users' machines.
#
# Until 2026-10-18 the image carried steam's 32-bit chain (about 200 i686
# packages), so the gaming layer only ever added the applications. Now the
# layer brings the chain, and it must fit the image as it is: the moment
# one i686 library needs a newer version of something the image ships,
# `ujust lucciola-gaming-native` and every update of a machine that has the
# layer stop depsolving. The developer layer (VS Code, gcc, flatpak-builder)
# has the same edge in a smaller way: gcc must match the image's glibc and
# libgcc exactly. smoke-boot's rpm-ostree dry runs check this on the booted
# image; this check runs right after the build, before anything is pushed,
# and needs no VM.
#
# rpm-ostree cannot change a package of the image when it layers. dnf in a
# container could, so it is held to the same rule: every installed package
# is version-locked at its installed version and architecture, while the
# other architecture of the same name (the i686 twin of an x86_64 library)
# stays free, as it is for rpm-ostree. Then `dnf install --assumeno` of the
# recipe's list, in a throwaway container: only metadata is downloaded,
# nothing is kept.
#
# The verdict is the depsolve, as for the smoke-boot dry run. On top of it
# the check names every i686 package that would land at a version other
# than its x86_64 twin's: rpm-ostree accepts the pair only when the files
# the two share are identical, so the list is where an install could still
# fail with "File exists".
set -euo pipefail

IMAGE_REF="${1:?usage: layer-resolve.sh <image-ref> <gaming-native|developer>}"
LAYER="${2:?usage: layer-resolve.sh <image-ref> <gaming-native|developer>}"

case "$LAYER" in
  gaming-native)
    LIST=/usr/share/margine/gaming-native-packages.txt
    MARK=MARGINE-GAMING-RESOLVE
    RECIPE="ujust lucciola-gaming-native"
    SETUP="" ;;
  developer)
    LIST=/usr/share/margine/developer-packages.txt
    MARK=MARGINE-DEVELOPER-RESOLVE
    RECIPE="ujust lucciola-devmode"
    SETUP="/usr/libexec/margine/devmode repo" ;;
  *) echo "layer-resolve.sh: unknown layer '$LAYER'" >&2; exit 2 ;;
esac

podman run --rm --network=host --entrypoint /usr/bin/bash \
  -e LIST="$LIST" -e MARK="$MARK" -e RECIPE="$RECIPE" -e SETUP="$SETUP" \
  "$IMAGE_REF" -c '
set -uo pipefail
if [[ ! -r "$LIST" ]]; then
  echo "$MARK: FAIL $LIST is missing: $RECIPE cannot run"; exit 1
fi
mapfile -t pkgs < <(grep -vE "^[[:space:]]*(#|$)" "$LIST")
if (( ${#pkgs[@]} == 0 )); then
  echo "$MARK: FAIL $LIST lists no package"; exit 1
fi

# The repository the layer needs, set up by the image itself. A refused
# key is a failure (the recipe would refuse too); a download that does not
# happen is no verdict, like an unreachable Fedora mirror.
if [[ -n "$SETUP" ]]; then
  if ! out="$($SETUP 2>&1)"; then
    echo "$out" | tail -n 10
    if grep -q "fingerprint mismatch" <<<"$out"; then
      echo "$MARK: FAIL $SETUP refused the repository signing key: $RECIPE cannot run"; exit 1
    fi
    echo "$MARK: UNKNOWN $SETUP could not set up the repository (network?)"; exit 2
  fi
  echo "$out"
fi

# Each installed package at its version and architecture; for an x86_64
# package, its i686 twin unconstrained. gpg-pubkey is not a package any
# repository serves.
entry() {  # name, then key=value conditions
  local name="$1" kv; shift
  printf "\n[[packages]]\nname = \"%s\"\n" "$name"
  for kv in "$@"; do
    printf "\n[[packages.conditions]]\nkey = \"%s\"\ncomparator = \"=\"\nvalue = \"%s\"\n" "${kv%%=*}" "${kv#*=}"
  done
}
rpm -qa --qf "%{NAME} %{ARCH} %{EPOCHNUM}:%{VERSION}-%{RELEASE}\n" | grep -v "^gpg-pubkey " | sort -u > /tmp/installed
mkdir -p /etc/dnf
{
  echo "version = \"1.0\""
  while read -r name arch evr; do
    entry "$name" "evr=${evr#0:}" "arch=$arch"
  done < /tmp/installed
  awk "\$2 == \"x86_64\" {print \$1}" /tmp/installed | sort -u | comm -23 - <(awk "\$2 == \"i686\" {print \$1}" /tmp/installed | sort -u) |
  while read -r name; do
    entry "$name" "arch=i686"
  done
} > /etc/dnf/versionlock.toml
echo "locked $(wc -l < /tmp/installed) installed packages at their version and architecture"

for attempt in 1 2 3; do
  out="$(dnf5 install --assumeno "${pkgs[@]}" 2>&1)"
  if grep -q "^Nothing to do" <<<"$out"; then
    echo "$MARK: PASS (${#pkgs[@]} requested, all already in the image)"
    exit 0
  fi
  if grep -q "^Transaction Summary" <<<"$out"; then
    # Installs only: an upgrade, downgrade, replacement or removal of an
    # image package is something rpm-ostree cannot do while layering.
    bad="$(grep -E "^ ?(Upgrading|Downgrading|Replacing|Reinstalling|Removing)" <<<"$out" || true)"
    if [[ -n "$bad" ]]; then
      echo "$out" | tail -n 60
      echo "$MARK: FAIL the layer would change image packages: $(tr -s " \n" " " <<<"$bad")"
      exit 1
    fi
    # The table up to "Skipping packages with broken dependencies": the
    # newer builds dnf passed over for the locked ones are not installed.
    rows="$(sed "/^Skipping packages/,\$d" <<<"$out" | grep -E "^ [^ ]+ +(x86_64|i686|noarch) +[^ ]+ +[^ ]+ " || true)"
    # Every requested package lands, or is already there: dnf lists what it
    # passes over under "Skipping", and a run that drops a requested
    # package is not the transaction the recipe asks for.
    dropped=()
    for p in "${pkgs[@]}"; do
      awk -v n="$p" "\$1 == n {f = 1} END {exit !f}" <<<"$rows" && continue
      rpm -q --whatprovides "$p" >/dev/null 2>&1 && continue
      dropped+=("$p")
    done
    if (( ${#dropped[@]} )); then
      echo "$out" | tail -n 60
      echo "$MARK: FAIL dnf would leave out ${dropped[*]}: not installable against this image"
      exit 1
    fi
    n="$(grep -c . <<<"$rows" || true)"
    n686="$(awk "\$2 == \"i686\"" <<<"$rows" | grep -c . || true)"
    skew=()
    while read -r name arch evr _; do
      [[ "$arch" == i686 ]] || continue
      twin="$(awk -v n="$name" "\$1 == n && \$2 == \"x86_64\" {print \$3}" /tmp/installed)"
      [[ -n "$twin" && "$twin" != "$evr" ]] && skew+=("$name ($evr, image $twin)")
    done <<<"$rows"
    size="$(grep -E "^Total size of inbound packages" <<<"$out" | sed -E "s/^Total size of inbound packages is ([^.]+)\..*/\1/" || true)"
    echo "$out" | sed -n "/^Transaction Summary/,\$p" | head -n 8
    if (( ${#skew[@]} )); then
      echo "i686 packages at a version other than their x86_64 twin in the image (${#skew[@]}):"
      printf "  %s\n" "${skew[@]}"
    fi
    echo "$MARK: PASS (${#pkgs[@]} requested, $n packages to install, $n686 of them i686, ${#skew[@]} i686 off their twin version, ${size:-download size unknown})"
    exit 0
  fi
  if grep -qE "^Failed to resolve the transaction|^Problem" <<<"$out"; then
    echo "$out" | tail -n 60
    why="$(grep -E "^Problem|^  - " <<<"$out" | head -n 4 | tr -s " \n" " ")"
    echo "$MARK: FAIL does not resolve: ${why}"
    exit 1
  fi
  echo "attempt $attempt: no verdict from dnf (repositories?):"
  echo "$out" | tail -n 15
  sleep 20
done
echo "$MARK: UNKNOWN dnf gave no verdict in three attempts"
exit 2
'
