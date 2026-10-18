#!/usr/bin/env bash
# Does the gaming-native layer resolve against this image, the way
# `ujust lucciola-gaming-native` will layer it?
#
#   usage: gaming-native-resolve.sh <image-ref>
#   exit:  0 resolves, 1 does not resolve (or no package list), 2 could not
#          tell (the repositories did not load, three attempts)
#
# Until 2026-10-18 the image carried steam's 32-bit chain (about 200 i686
# packages), so the layer only ever added the applications. Now the layer
# brings the chain, and it must fit the image as it is: the moment one
# i686 library needs a newer version of something the image ships,
# `ujust lucciola-gaming-native` and every update of a machine that has the
# layer stop depsolving. smoke-boot's rpm-ostree dry run checks this on the
# booted image; this check runs right after the build, before anything is
# pushed, and needs no VM.
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

IMAGE_REF="${1:?usage: gaming-native-resolve.sh <image-ref>}"

podman run --rm --network=host --entrypoint /usr/bin/bash "$IMAGE_REF" -c '
set -uo pipefail
list=/usr/share/margine/gaming-native-packages.txt
if [[ ! -r "$list" ]]; then
  echo "MARGINE-GAMING-RESOLVE: FAIL $list is missing: ujust lucciola-gaming-native cannot run"; exit 1
fi
mapfile -t pkgs < <(grep -vE "^[[:space:]]*(#|$)" "$list")
if (( ${#pkgs[@]} == 0 )); then
  echo "MARGINE-GAMING-RESOLVE: FAIL $list lists no package"; exit 1
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
  if grep -q "^Transaction Summary" <<<"$out"; then
    # Installs only: an upgrade, downgrade, replacement or removal of an
    # image package is something rpm-ostree cannot do while layering.
    bad="$(grep -E "^ ?(Upgrading|Downgrading|Replacing|Reinstalling|Removing)" <<<"$out" || true)"
    if [[ -n "$bad" ]]; then
      echo "$out" | tail -n 60
      echo "MARGINE-GAMING-RESOLVE: FAIL the layer would change image packages: $(tr -s " \n" " " <<<"$bad")"
      exit 1
    fi
    rows="$(grep -E "^ [^ ]+ +(x86_64|i686|noarch) +[^ ]+ +[^ ]+ " <<<"$out" || true)"
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
    echo "MARGINE-GAMING-RESOLVE: PASS (${#pkgs[@]} requested, $n packages to install, $n686 of them i686, ${#skew[@]} i686 off their twin version, ${size:-download size unknown})"
    exit 0
  fi
  if grep -qE "^Failed to resolve the transaction|^Problem" <<<"$out"; then
    echo "$out" | tail -n 60
    why="$(grep -E "^Problem|^  - " <<<"$out" | head -n 4 | tr -s " \n" " ")"
    echo "MARGINE-GAMING-RESOLVE: FAIL does not resolve: ${why}"
    exit 1
  fi
  echo "attempt $attempt: no verdict from dnf (repositories?):"
  echo "$out" | tail -n 15
  sleep 20
done
echo "MARGINE-GAMING-RESOLVE: UNKNOWN dnf gave no verdict in three attempts"
exit 2
'
