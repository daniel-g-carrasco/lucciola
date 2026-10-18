#!/usr/bin/env bash
# Tests for /usr/libexec/margine/kernel-switch (ujust lucciola-kernel)
# against a fake rpm-ostree, mokutil, MOK helper and glibc loader.
# What it must do: move only a tag of this repository between :stable and
# the kernel reserve, on the signed transport when the policy allows it,
# keep pins and other images alone, refuse the CachyOS kernel where it
# cannot boot, and say before anything changes that TPM unlock will ask
# for the passphrase once (and what to run afterwards).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/build_files/system_files/usr/libexec/margine/kernel-switch"
TAGFILE="$ROOT/build_files/system_files/usr/share/margine/kernel-reserve-tag"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
mkdir -p "$T/bin"
# shellcheck disable=SC2016
cat > "$T/bin/rpm-ostree" <<'STUB'
#!/bin/sh
case "$1" in
  status)
    if [ -n "$FAKE_STAGED" ]; then
      printf '{"deployments":[{"staged":true,"booted":false,"container-image-reference":"%s"},{"booted":true,"container-image-reference":"%s"}]}\n' "$FAKE_STAGED" "$FAKE_BOOTED"
    else
      printf '{"deployments":[{"booted":true,"container-image-reference":"%s"}]}\n' "$FAKE_BOOTED"
    fi ;;
  rebase)  echo "rebase $2" >> "$FAKE_LOG"; [ -z "${FAKE_FAIL:-}" ] ;;
  cleanup) echo "cleanup $2" >> "$FAKE_LOG" ;;
esac
STUB
# shellcheck disable=SC2016
printf '#!/bin/sh\n[ "$FAKE_SB" = on ] && echo "SecureBoot enabled" || echo "SecureBoot disabled"\n' > "$T/bin/mokutil"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$FAKE_MOK"\n' > "$T/mok-enroll"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "Subdirectories of glibc-hwcaps directories, in priority order:"\nif [ "$FAKE_V3" = yes ]; then echo "  x86-64-v3 (supported, searched)"; else echo "  x86-64-v3"; fi\necho "  x86-64-v2 (supported, searched)"\n' > "$T/ld.so"
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "$FAKE_UNAME"\n' > "$T/bin/uname"
chmod +x "$T/bin/"* "$T/mok-enroll" "$T/ld.so"
printf '{"default":[{"type":"reject"}],"transports":{"docker":{"ghcr.io/daniel-g-carrasco/lucciola":[{"type":"sigstoreSigned","keyPath":"/usr/lib/pki/containers/margine.pub","signedIdentity":{"type":"matchRepository"}}]}}}\n' > "$T/policy.json"
printf '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{}}}\n' > "$T/policy-none.json"
printf 'luks-1234 UUID=1234 none discard,tpm2-device=auto\n' > "$T/crypttab-tpm"
printf 'luks-1234 UUID=1234 none discard\n' > "$T/crypttab-plain"

R=ghcr.io/daniel-g-carrasco/lucciola
RES="$(head -n1 "$TAGFILE")"
S="ostree-image-signed:docker://$R"

# run_case <name> <action> <booted> <want: rebase target | cleanup | -> <want-rc> [KEY=VALUE...]
# Defaults: Secure Boot on, Margine key enrolled, x86-64-v3 CPU, no TPM
# unlock, the signature policy present, answer "y".
run_case() {
  local name="$1" action="$2" booted="$3" want="$4" want_rc="$5" rc=0
  shift 5
  local staged="" sb=on mok=enrolled v3=yes crypttab="$T/crypttab-plain" pol="$T/policy.json" answer=y ff="" uname=7.2.9-cachyos1.fc45.x86_64 expect=""
  local kv
  for kv in "$@"; do
    case "$kv" in
      staged=*) staged="${kv#*=}" ;; sb=*) sb="${kv#*=}" ;; mok=*) mok="${kv#*=}" ;;
      v3=*) v3="${kv#*=}" ;; tpm=yes) crypttab="$T/crypttab-tpm" ;; policy=none) pol="$T/policy-none.json" ;;
      answer=*) answer="${kv#*=}" ;; fail=yes) ff=yes ;; uname=*) uname="${kv#*=}" ;; expect=*) expect="${kv#*=}" ;;
    esac
  done
  : > "$T/log"
  printf '%s\n' "$answer" | env -i PATH="$T/bin:/usr/bin:/bin" FAKE_BOOTED="$booted" FAKE_STAGED="$staged" \
    FAKE_LOG="$T/log" FAKE_FAIL="$ff" FAKE_SB="$sb" FAKE_MOK="$mok" FAKE_V3="$v3" FAKE_UNAME="$uname" \
    MARGINE_POLICY="$pol" MARGINE_CRYPTTAB="$crypttab" MARGINE_LDSO="$T/ld.so" MARGINE_CPUINFO=/dev/null \
    MARGINE_MOK_HELPER="$T/mok-enroll" MARGINE_KERNEL_RESERVE_TAG_FILE="$TAGFILE" \
    MARGINE_KERNEL_FLAVOR_FILE=/dev/null \
    bash "$HELPER" "$action" > "$T/out" 2>&1 || rc=$?
  local got
  got="$(sed -n 's/^rebase //p; s/^cleanup .*/cleanup/p' "$T/log")"; [ -n "$got" ] || got="-"
  if [ "$got" = "$want" ] && [ "$rc" = "$want_rc" ] && { [ -z "$expect" ] || grep -qF -- "$expect" "$T/out"; }; then
    echo "ok   $name"
  else
    echo "FAIL $name: action=$got (want $want) rc=$rc (want $want_rc)${expect:+ expect='$expect'}"
    sed 's/^/     /' "$T/out"; fails=$((fails+1))
  fi
}

run_case "status reads, changes nothing"                    status  "$S:stable" - 0 expect="ujust lucciola-kernel fedora"
run_case "status on the reserve offers the way back"        status  "$S:$RES"   - 0 uname=7.2.9-300.fc45.x86_64 expect="ujust lucciola-kernel cachyos"
run_case ":stable -> reserve, signed transport kept"        fedora  "$S:stable" "$S:$RES" 0
run_case "unverified install -> reserve on the signed transport" fedora "ostree-unverified-registry:$R:stable" "$S:$RES" 0
run_case "no policy scope: the install's own transport"     fedora  "ostree-unverified-registry:$R:stable" "ostree-unverified-registry:$R:$RES" 0 policy=none
run_case "unverified-image form without a scope stays so"   fedora  "ostree-unverified-image:docker://$R:stable" "ostree-unverified-image:docker://$R:$RES" 0 policy=none
run_case "reserve -> :stable"                               cachyos "$S:$RES"   "$S:stable" 0
run_case "dated reserve tag counts as the reserve"          cachyos "$S:$RES.20261101" "$S:stable" 0
run_case ":candidate is CachyOS already: nothing"           cachyos "$S:candidate" - 0 expect="Already on the CachyOS kernel"
run_case "already on the reserve: nothing"                  fedora  "$S:$RES"   - 0
run_case "CPU without x86-64-v3: CachyOS refused"           cachyos "$S:$RES"   - 1 v3=no expect="x86-64-v3"
run_case "Secure Boot on, key absent: CachyOS refused"      cachyos "$S:$RES"   - 1 mok=absent expect="lucciola-secureboot enroll"
run_case "Secure Boot on, key pending: CachyOS refused"     cachyos "$S:$RES"   - 1 mok=pending
run_case "Secure Boot off, key absent: CachyOS allowed"     cachyos "$S:$RES"   "$S:stable" 0 sb=off mok=absent
run_case "the reserve needs neither the key nor v3"         fedora  "$S:stable" "$S:$RES" 0 mok=absent v3=no
run_case "another image: refused"                           fedora  "ostree-image-signed:docker://ghcr.io/ublue-os/silverblue-main:45" - 1
run_case "Margine's repository: refused"                    fedora  "ostree-unverified-registry:ghcr.io/daniel-g-carrasco/margine:lucciola" - 1
run_case "digest pin: refused"                              fedora  "$S@sha256:$(printf '%064d' 0)" - 1 expect="pinned to a digest"
run_case "ostree remote: refused"                           fedora  "ostree-remote-image:fedora:docker://$R:stable" - 1
run_case "no image reference: refused"                      fedora  "" - 1
run_case "TPM + Secure Boot: warned, 'yes' needed"          fedora  "$S:stable" - 1 tpm=yes answer=y expect="ujust lucciola-tpm-unlock enable"
run_case "TPM + Secure Boot: 'yes' switches"                fedora  "$S:stable" "$S:$RES" 0 tpm=yes answer=yes expect="After that first boot: ujust lucciola-tpm-unlock enable"
run_case "TPM, Secure Boot off: no 'yes' needed"            fedora  "$S:stable" "$S:$RES" 0 tpm=yes sb=off expect="should keep unlocking"
run_case "answer no: nothing changes"                       fedora  "$S:stable" - 1 answer=n expect="Nothing changed"
run_case "rebase fails: reported, rc 1"                     fedora  "$S:stable" "$S:$RES" 1 fail=yes expect="Nothing changed"
run_case "switch staged: asking again changes nothing"      fedora  "$S:stable" - 0 staged="$S:$RES" expect="already staged"
run_case "switch staged, other kernel: staged one dropped"  cachyos "$S:stable" cleanup 0 staged="$S:$RES"
if (( fails )); then echo "$fails kernel-switch case(s) failed"; exit 1; fi
echo "all kernel-switch cases passed"
