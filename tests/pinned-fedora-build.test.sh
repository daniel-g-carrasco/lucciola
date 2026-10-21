#!/usr/bin/env bash
# Tests for the pinned-build helpers in build_files/00-common.sh
# (dnf_install_pinned, fetch_signed_rpm, verify_fedora_signature) against
# fake dnf5, curl, rpmkeys, rpm, gpg and sleep. What they must do: install
# the exact build from the repositories when they have it, and never talk
# to Koji then; otherwise fetch Fedora's signed copy from Koji at the right
# URL, refuse it unless rpmkeys says digests and signature are OK and the
# signer is the release key, and only then hand the local file to dnf in
# the same transaction as the other packages; and fail at once, saying
# why, when Koji has no such file.
set -euo pipefail
COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build_files/00-common.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
mkdir -p "$T/bin" "$T/keys" "$T/nokeys" "$T/tmp"
# Fedora 45's release key: the stubbed gpg reports this fingerprint, Koji
# files the signed copies under its last 8 digits.
FPR=4F50A6114CD5C6976A7F1179655A4B02F577861E
SIGNER=4f50a6114cd5c6976a7f1179655a4b02f577861e
printf 'not a key: gpg is a stub\n' > "$T/keys/RPM-GPG-KEY-fedora-45-primary"
KOJI=https://kojipkgs.fedoraproject.org/packages
NOCTALIA_URL="$KOJI/noctalia/5.3.0/1.fc45/data/signed/f577861e/x86_64/noctalia-5.3.0-1.fc45.x86_64.rpm"

# shellcheck disable=SC2016
cat > "$T/bin/rpm" <<'STUB'
#!/bin/sh
case "$1" in
  -E) case "$2" in %fedora) echo 45 ;; %_arch) echo x86_64 ;; esac ;;
esac
STUB
# shellcheck disable=SC2016
cat > "$T/bin/gpg" <<'STUB'
#!/bin/sh
printf 'pub:-:4096:1:655A4B02F577861E:::::::::\nfpr:::::::::%s:\n' "$FAKE_FPR"
STUB
# shellcheck disable=SC2016
cat > "$T/bin/dnf5" <<'STUB'
#!/bin/sh
echo "dnf5 $*" >> "$FAKE_LOG"
cmd=""
for a in "$@"; do case "$a" in repoquery|install) cmd=$a; break ;; esac; done
case "$cmd" in
  repoquery) [ "$FAKE_REPOQUERY" = fail ] && exit 1; printf '%s\n' $FAKE_HAVE ;;
  install) [ "$FAKE_INSTALL" != fail ] ;;
esac
STUB
# shellcheck disable=SC2016
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
echo "curl $*" >> "$FAKE_LOG"
head=no; out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head|-I) head=yes ;;
    -o) out=$2; shift ;;
    -w) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
if [ "$head" = yes ]; then printf '%s' "${FAKE_HTTP:-200}"; exit 0; fi
[ "${FAKE_HTTP:-200}" = 200 ] || exit 22
printf 'fake rpm from %s\n' "$url" > "$out"
STUB
# shellcheck disable=SC2016
cat > "$T/bin/rpmkeys" <<'STUB'
#!/bin/sh
echo "rpmkeys $*" >> "$FAKE_LOG"
case "$1" in
  --import) exit 0 ;;
  --checksig)
    f=$2; v=no; [ "$2" = -v ] && { v=yes; f=$3; }
    if [ "$FAKE_SIG" = bad ]; then
      if [ $v = yes ]; then printf '%s:\n    Header OpenPGP V4 RSA/SHA256 signature, key fingerprint: %s: OK\n    Payload SHA256 digest: BAD\n' "$f" "$FAKE_SIGNER"
      else printf '%s: DIGESTS SIGNATURES NOT OK\n' "$f"; fi
      exit 1
    fi
    if [ $v = yes ]; then
      if [ "$FAKE_SIGFMT" = rpm4 ]; then
        printf '%s:\n    Header V4 RSA/SHA256 Signature, key ID %s: OK\n    Header SHA256 digest: OK\n    Payload SHA256 digest: OK\n' "$f" "$(printf %s "$FAKE_SIGNER" | tail -c 8)"
      else
        printf '%s:\n    Header OpenPGP V4 RSA/SHA256 signature, key fingerprint: %s: OK\n    Header SHA256 digest: OK\n    Payload SHA256 digest: OK\n' "$f" "$FAKE_SIGNER"
      fi
    else printf '%s: digests signatures OK\n' "$f"; fi ;;
esac
STUB
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "sleep $*" >> "$FAKE_LOG"\n' > "$T/bin/sleep"
chmod +x "$T/bin/"*

# run_case <name> <want-rc> <bash code> [KEY=VALUE...]
# Keys: have=<space-separated version-release.arch the repositories offer>,
# http=<HEAD status>, sig=bad, signer=<40 hex>, fmt=rpm4, repoquery=fail,
# install=fail, keys=none; checks: expect=<text in the output>,
# log=<text in the stub log>, nolog=<text absent from it>,
# before=<text>|<text> (first logged before second), exists=<path>,
# tmpclean=yes (nothing left under TMPDIR).
run_case() {
  local name="$1" want_rc="$2" code="$3" rc=0
  shift 3
  local have="" http=200 sig=ok signer="$SIGNER" fmt=rpm6 rq=ok inst=ok keys="$T/keys" tmpclean=""
  local -a expect=() want_log=() nolog=() before=() exists=()
  local kv
  for kv in "$@"; do
    case "$kv" in
      have=*) have="${kv#*=}" ;; http=*) http="${kv#*=}" ;; sig=*) sig="${kv#*=}" ;;
      signer=*) signer="${kv#*=}" ;; fmt=*) fmt="${kv#*=}" ;; repoquery=*) rq="${kv#*=}" ;;
      install=*) inst="${kv#*=}" ;; keys=none) keys="$T/nokeys" ;; tmpclean=yes) tmpclean=yes ;;
      expect=*) expect+=("${kv#*=}") ;; log=*) want_log+=("${kv#*=}") ;; nolog=*) nolog+=("${kv#*=}") ;;
      before=*) before+=("${kv#*=}") ;; exists=*) exists+=("${kv#*=}") ;;
    esac
  done
  : > "$T/log"; rm -rf "$T/tmp"; mkdir -p "$T/tmp"
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" TMPDIR="$T/tmp" GNUPGHOME="$T/gnupg" \
    FAKE_LOG="$T/log" FAKE_FPR="$FPR" FAKE_HAVE="$have" FAKE_HTTP="$http" FAKE_SIG="$sig" \
    FAKE_SIGNER="$signer" FAKE_SIGFMT="$fmt" FAKE_REPOQUERY="$rq" FAKE_INSTALL="$inst" \
    MARGINE_RPM_GPG_DIRS="$keys" \
    bash -c ". '$COMMON'; $code" > "$T/out" 2>&1 || rc=$?
  local bad=""
  [ "$rc" = "$want_rc" ] || bad="rc=$rc (want $want_rc)"
  local e
  for e in "${expect[@]}"; do grep -qF -- "$e" "$T/out" || bad="$bad; output lacks '$e'"; done
  for e in "${want_log[@]}"; do grep -qF -- "$e" "$T/log" || bad="$bad; log lacks '$e'"; done
  for e in "${nolog[@]}"; do ! grep -qF -- "$e" "$T/log" || bad="$bad; log has '$e'"; done
  for e in "${before[@]}"; do
    local first second n1 n2
    first="${e%%|*}"; second="${e#*|}"
    n1="$(grep -nF -- "$first" "$T/log" | head -n1 | cut -d: -f1)"
    n2="$(grep -nF -- "$second" "$T/log" | head -n1 | cut -d: -f1)"
    { [ -n "$n1" ] && [ -n "$n2" ] && [ "$n1" -lt "$n2" ]; } || bad="$bad; '$first' not before '$second'"
  done
  for e in "${exists[@]}"; do [ -s "$e" ] || bad="$bad; missing $e"; done
  if [ -n "$tmpclean" ] && [ -n "$(ls -A "$T/tmp")" ]; then bad="$bad; left behind: $(ls -A "$T/tmp" | tr '\n' ' ')"; fi
  if [ -z "$bad" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: ${bad#; }"
    sed 's/^/     out: /' "$T/out"; sed 's/^/     log: /' "$T/log"; fails=$((fails+1))
  fi
}

INSTALL='dnf_install_pinned noctalia 5.3.0-1.fc45 x86_64 --setopt=install_weak_deps=False niri xwayland-satellite ddcutil'
TX='dnf5 -y install --setopt=install_weak_deps=False niri xwayland-satellite ddcutil'

run_case "repositories have the build: installed from there, Koji never asked" 0 "$INSTALL" \
  have="5.2.1-1.fc45.x86_64 5.3.0-1.fc45.x86_64" \
  log="dnf5 -q --refresh repoquery --qf" log="$TX noctalia-5.3.0-1.fc45" \
  nolog="curl" nolog="rpmkeys" expect="the repositories have it"
run_case "the same build for another arch does not count" 0 "$INSTALL" \
  have="5.3.0-1.fc45.i686" log="curl" log="$TX $T/tmp/" expect="Koji"
run_case "repositories lack it: Koji's signed copy, checked, in the same transaction" 0 "$INSTALL" \
  have="5.2.1-1.fc45.x86_64 5.4.0-1.fc45.x86_64" \
  expect="not in the repositories (they have: 5.2.1-1.fc45.x86_64 5.4.0-1.fc45.x86_64)" \
  expect="fetching noctalia-5.3.0-1.fc45.x86_64 from Koji: $NOCTALIA_URL" \
  log="--head -o /dev/null -w %{http_code} $NOCTALIA_URL" \
  log="curl --fail --silent --show-error -L $NOCTALIA_URL -o $T/tmp/" \
  log="rpmkeys --import $T/keys/RPM-GPG-KEY-fedora-45-primary" \
  log="rpmkeys --checksig $T/tmp/" log="rpmkeys --checksig -v $T/tmp/" \
  log="$TX $T/tmp/" \
  before="rpmkeys --checksig|dnf5 -y install" before="curl --fail|rpmkeys --checksig" \
  expect="signatures OK (Fedora 45 release key f577861e)" nolog="sleep" tmpclean=yes
run_case "repositories empty of it altogether: still Koji" 0 "$INSTALL" \
  have="" expect="(they have: nothing)" log="$TX $T/tmp/"
run_case "bad digests or signature: refused, nothing installed" 1 "$INSTALL" \
  have="5.2.1-1.fc45.x86_64" sig=bad \
  expect="does not carry a valid Fedora 45 signature" expect="neither the repositories nor Koji" \
  nolog="dnf5 -y install" tmpclean=yes
run_case "signed by another key the rpmdb may hold: refused" 1 "$INSTALL" \
  have="5.2.1-1.fc45.x86_64" signer=ab4670779555943799be7ed916bc8535a444a78a \
  expect="not by Fedora 45's release key (f577861e)" nolog="dnf5 -y install" tmpclean=yes
run_case "rpm 4's wording of the verbose report is accepted" 0 "$INSTALL" \
  have="5.2.1-1.fc45.x86_64" fmt=rpm4 log="$TX $T/tmp/"
run_case "Koji has no such file (404): fails at once, no retry, nothing installed" 1 "$INSTALL" \
  have="5.2.1-1.fc45.x86_64" http=404 \
  expect="Koji has no signed noctalia-5.3.0-1.fc45.x86_64 (HTTP 404): $NOCTALIA_URL" \
  expect="never went through Bodhi" \
  nolog="curl --fail" nolog="sleep" nolog="rpmkeys" nolog="dnf5 -y install" tmpclean=yes
run_case "Koji unreachable (503): retried, then fails, nothing installed" 1 "$INSTALL" \
  have="5.2.1-1.fc45.x86_64" http=503 \
  log="sleep 30" log="sleep 120" expect="retry_curl FAILED after 5 attempts" \
  nolog="rpmkeys --checksig" nolog="dnf5 -y install" tmpclean=yes
run_case "dnf fails on Koji's file: the failure is reported, nothing left behind" 1 "$INSTALL" \
  have="5.2.1-1.fc45.x86_64" install=fail expect="dnf5 install of Koji's noctalia-5.3.0-1.fc45.x86_64 failed" tmpclean=yes
run_case "repoquery fails: no guess, no Koji" 1 "$INSTALL" \
  repoquery=fail expect="dnf5 repoquery noctalia failed" nolog="curl" nolog="dnf5 -y install"
run_case "no release key in the image: fails before any download" 1 "$INSTALL" \
  have="5.2.1-1.fc45.x86_64" keys=none expect="no Fedora 45 release key in the image" \
  nolog="curl --fail" nolog="dnf5 -y install"
run_case "fetch_signed_rpm: a subpackage names its source build (kernel-devel from kernel)" 0 \
  "fetch_signed_rpm kernel-devel 7.2.9-300.fc45 x86_64 \"\$TMPDIR/kd\" kernel" \
  log="--head -o /dev/null -w %{http_code} $KOJI/kernel/7.2.9/300.fc45/data/signed/f577861e/x86_64/kernel-devel-7.2.9-300.fc45.x86_64.rpm" \
  log="rpmkeys --checksig $T/tmp/kd/kernel-devel-7.2.9-300.fc45.x86_64.rpm" \
  exists="$T/tmp/kd/kernel-devel-7.2.9-300.fc45.x86_64.rpm"
run_case "fetch_signed_rpm: the package is the build when none is named" 0 \
  "fetch_signed_rpm noctalia 5.3.0-1.fc45 x86_64 \"\$TMPDIR/n\"" \
  log="--head -o /dev/null -w %{http_code} $NOCTALIA_URL" exists="$T/tmp/n/noctalia-5.3.0-1.fc45.x86_64.rpm"
run_case "fetch_signed_rpm: a version without a release is refused" 1 \
  "fetch_signed_rpm noctalia 5.3.0 x86_64 \"\$TMPDIR/n\"" \
  expect="is not <version>-<release>" nolog="curl"
run_case "verify_fedora_signature: the first bad file stops the lot" 1 \
  "printf x > \"\$TMPDIR/a.rpm\"; printf x > \"\$TMPDIR/b.rpm\"; verify_fedora_signature \"\$TMPDIR/a.rpm\" \"\$TMPDIR/b.rpm\"" \
  sig=bad expect="a.rpm does not carry a valid Fedora 45 signature" nolog="rpmkeys --checksig $T/tmp/b.rpm"

if (( fails )); then echo "$fails pinned-fedora-build case(s) failed"; exit 1; fi
echo "all pinned-fedora-build cases passed"
