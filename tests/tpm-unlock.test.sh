#!/usr/bin/env bash
# /usr/bin/lucciola-tpm-unlock with the PIN option (register decision D1), on
# fakes: a LUKS header that is a JSON file, a systemd-cryptenroll that records
# how it was called and edits that file, a root that is a directory
# (LUCCIOLA_TPM_UNLOCK_TEST_ROOT). What must hold:
# - the PIN is an option: `enable` on a disk without one enrolls without;
# - `pin` enrolls with --tpm2-with-pin=yes, the PIN in $NEWPIN and never in
#   the arguments, replacing an existing TPM key in one call;
# - a PIN that is short, absent, or on two lines stops before anything changes;
# - `enable` on an enrollment that asks a PIN keeps asking one, and stops
#   when it has no PIN to enroll with: it never drops it quietly;
# - `no-pin` goes back, and the result is checked both ways (a key enrolled
#   without the PIN that was asked for is an error, not a success);
# - the passphrase slot is required before and still there after;
# - status says whether a PIN is asked, in the words Lucciola System reads.
# The real systemd-cryptenroll against a software TPM is in
# tests/tpm-unlock-real.test.sh.
# Needs jq.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/build_files/system_files/usr/bin/lucciola-tpm-unlock"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 10; fails=$((fails+1)); fi; }
says() { grep -qE -- "$1" "$T/out"; }
quiet() { ! grep -qE -- "$1" "$T/out"; }

mkdir -p "$T/bin" "$T/fake" "$T/root/sys/class/tpm/tpm0" "$T/root/dev" "$T/root/etc" "$T/root/boot/grub2"
export FAKE="$T/fake"
UUID=11111111-2222-3333-4444-555555555555
echo 2 > "$T/root/sys/class/tpm/tpm0/tpm_version_major"

cat > "$T/bin/id" <<'SH'
#!/bin/sh
[ "$1" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
SH
cat > "$T/bin/findmnt" <<'SH'
#!/bin/sh
# findmnt -no SOURCE /sysroot
[ "$3" = /sysroot ] && echo /dev/mapper/luks-test
exit 0
SH
cat > "$T/bin/lsblk" <<'SH'
#!/bin/sh
case "$*" in
  "-prno FSTYPE /dev/fake0p3") echo crypto_LUKS ;;
  "-prno NAME,TYPE /dev/fake0p3") printf '/dev/fake0p3 part\n/dev/mapper/luks-test crypt\n' ;;
  "-prno NAME /dev/mapper/luks-test -s") printf '/dev/mapper/luks-test\n/dev/fake0p3\n/dev/fake0\n' ;;
  "-prno NAME,FSTYPE /dev/mapper/luks-test -s") printf '/dev/mapper/luks-test btrfs\n/dev/fake0p3 crypto_LUKS\n/dev/fake0 \n' ;;
  "-prno NAME,FSTYPE") printf '/dev/fake0 \n/dev/fake0p3 crypto_LUKS\n' ;;
esac
SH
cat > "$T/bin/blkid" <<'SH'
#!/bin/sh
echo 11111111-2222-3333-4444-555555555555
SH
cat > "$T/bin/cryptsetup" <<'SH'
#!/bin/sh
case "$1" in
  status) printf '/dev/mapper/%s is active and is in use.\n  type:    LUKS2\n  device:  /dev/fake0p3\n' "$2" ;;
  luksDump) cat "$FAKE/header.json" ;;
  *) echo "fake cryptsetup: unexpected $*" >&2; exit 9 ;;
esac
SH
# The fake systemd-cryptenroll: one line per call in $FAKE/calls (its
# arguments), the PIN it was handed in $FAKE/newpin (or "unset"), and the
# header rewritten the way the real one does: --wipe-slot=tpm2 drops the old
# TPM key, an enrollment adds one in a new slot, with "tpm2-pin" as asked.
# FAKE_CRYPTENROLL_RC makes it fail before touching anything;
# FAKE_IGNORE_PIN makes it enroll without the PIN it was asked for.
cat > "$T/bin/systemd-cryptenroll" <<'SH'
#!/bin/bash
echo "$*" >> "$FAKE/calls"
if [ -n "${NEWPIN+x}" ]; then printf '%s' "$NEWPIN" > "$FAKE/newpin"; else echo unset > "$FAKE/newpin"; fi
[ -n "${LUCCIOLA_UNLOCK_KEY_FILE:-}" ] && cat "$LUCCIOLA_UNLOCK_KEY_FILE" > "$FAKE/passphrase-seen" 2>/dev/null
[ "${FAKE_CRYPTENROLL_RC:-0}" = 0 ] || exit "$FAKE_CRYPTENROLL_RC"
wipe=0; enroll=0; pin=false
for a in "$@"; do
  case "$a" in
    --wipe-slot=tpm2) wipe=1 ;;
    --tpm2-device=*) enroll=1 ;;
    --tpm2-with-pin=yes) pin=true ;;
  esac
done
[ -n "${FAKE_IGNORE_PIN:-}" ] && pin=false
h="$FAKE/header.json"
# As the real one: the new key enters first, then the old one leaves.
old="$(jq -c '[.tokens // {} | to_entries[] | select(.value.type=="systemd-tpm2") | .key]' "$h")"
if [ "$enroll" = 1 ]; then
  jq --argjson pin "$pin" '((.keyslots | keys | map(tonumber) | max) + 1 | tostring) as $n
      | .keyslots[$n] = {"type":"luks2"}
      | .tokens[((.tokens // {} | keys | map(tonumber) | (max // -1)) + 1 | tostring)] = {"type":"systemd-tpm2","keyslots":[$n],"tpm2-pcrs":[7],"tpm2-pin":$pin}' "$h" > "$h.new" && mv "$h.new" "$h"
fi
if [ "$wipe" = 1 ]; then
  jq --argjson old "$old" '([.tokens | to_entries[] | select(.key as $k | $old | index($k)) | .value.keyslots[]]) as $s
      | .tokens |= with_entries(select(.key as $k | ($old | index($k)) | not))
      | .keyslots |= with_entries(select(.key as $k | ($s | index($k)) | not))' "$h" > "$h.new" && mv "$h.new" "$h"
fi
exit 0
SH
chmod +x "$T/bin"/*

header() {  # header none|plain|pin|only-tpm
  case "$1" in
    none)     echo '{"keyslots":{"0":{"type":"luks2"}},"tokens":{}}' ;;
    plain)    echo '{"keyslots":{"0":{"type":"luks2"},"1":{"type":"luks2"}},"tokens":{"0":{"type":"systemd-tpm2","keyslots":["1"],"tpm2-pcrs":[7],"tpm2-pin":false}}}' ;;
    pin)      echo '{"keyslots":{"0":{"type":"luks2"},"1":{"type":"luks2"}},"tokens":{"0":{"type":"systemd-tpm2","keyslots":["1"],"tpm2-pcrs":[7],"tpm2-pin":true}}}' ;;
    only-tpm) echo '{"keyslots":{"1":{"type":"luks2"}},"tokens":{"0":{"type":"systemd-tpm2","keyslots":["1"],"tpm2-pcrs":[7],"tpm2-pin":false}}}' ;;
  esac > "$FAKE/header.json"
  rm -f "$FAKE/calls" "$FAKE/newpin" "$FAKE/passphrase-seen"
  # A disk the TPM already unlocks has its startup wired; a fresh one has not.
  case "$1" in
    none) printf 'luks-test UUID=%s none discard\n' "$UUID" ;;
    *)    printf 'luks-test UUID=%s none discard,tpm2-device=auto\n' "$UUID" ;;
  esac > "$T/root/etc/crypttab"
}
pinfile() { printf '%s' "$1" > "$T/pin"; }
# run [VAR=value ...] -- ACTION [ARGS]: no terminal on stdin, a clean
# environment plus what the helper would set.
run() {
  local -a env=()
  while [ "$1" != -- ]; do env+=("$1"); shift; done; shift
  RC=0
  env -i PATH="$T/bin:/usr/bin:/bin" FAKE="$FAKE" LUCCIOLA_TPM_UNLOCK_TEST_ROOT="$T/root" CONFIRM=yes "${env[@]}" \
    bash "$TOOL" "$@" > "$T/out" 2>&1 < /dev/null || RC=$?
}
token() { jq -r '[.tokens[] | select(.type=="systemd-tpm2")] | if length == 0 then "none" else (.[0]["tpm2-pin"] | tostring) end' "$FAKE/header.json"; }
slots() { jq -r '.keyslots | keys | join(",")' "$FAKE/header.json"; }
calls() { [ -e "$FAKE/calls" ] && wc -l < "$FAKE/calls" || echo 0; }
wired() { grep -qE "UUID=$UUID .*tpm2-device=auto" "$T/root/etc/crypttab"; }

# ── status ────────────────────────────────────────────────────────────
header plain; run -- status
check "status, a TPM key without a PIN (rc $RC)" [ "$RC" = 0 ]
check "...says the PIN is not asked, in the words the window reads" says '^  PIN at startup             — not asked'
check "...and how to add one" says 'ujust lucciola-tpm-unlock pin'
header pin; run -- status
check "status, a TPM key with a PIN: asked" says '^  PIN at startup             ✓ asked'
check "...and how to go back" says 'ujust lucciola-tpm-unlock no-pin'
header none; run -- status
check "status, no TPM key: no PIN line at all" quiet 'PIN at startup'

# ── the default stays without a PIN ───────────────────────────────────
header none; run -- enable
check "enable on a disk with no TPM key (rc $RC)" [ "$RC" = 0 ]
check "...enrolls without a PIN, saying so to systemd-cryptenroll" grep -qE -- '--tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=no /dev/fake0p3$' "$FAKE/calls"
check "...hands it no PIN" [ "$(cat "$FAKE/newpin")" = unset ]
check "...the token asks none" [ "$(token)" = false ]
check "...the startup is wired" wired
check "...and the passphrase slot is still there" [ "$(slots)" = "0,1" ]

# ── pin ───────────────────────────────────────────────────────────────
header plain; pinfile 'c0ffee42'; printf 'the passphrase' > "$T/pw"
run LUCCIOLA_TPM_PIN_FILE="$T/pin" LUCCIOLA_UNLOCK_KEY_FILE="$T/pw" -- pin
check "pin on a disk the TPM already unlocks (rc $RC)" [ "$RC" = 0 ]
check "...one call: the old key leaves and the new one enters together" [ "$(calls)" = 1 ]
check "...with --wipe-slot=tpm2 and --tpm2-with-pin=yes" grep -qE -- '--wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=yes /dev/fake0p3$' "$FAKE/calls"
check "...the PIN reaches systemd-cryptenroll in NEWPIN" [ "$(cat "$FAKE/newpin")" = c0ffee42 ]
check "...and never in its arguments" bash -c "! grep -q c0ffee42 '$FAKE/calls'"
check "...nor in what the tool prints" quiet 'c0ffee42'
check "...the tool sets NEWPIN itself, with no env in front (whose arguments anyone can read)" \
  bash -c "grep -q '      NEWPIN=\"\$NEW_PIN\" systemd-cryptenroll \"\$@\"' '$TOOL' && ! grep -qE '(^|[^a-z_])env +NEWPIN=' '$TOOL'"
check "...the passphrase goes as a key file" grep -q -- "--unlock-key-file=$T/pw" "$FAKE/calls"
check "...the token asks the PIN" [ "$(token)" = true ]
check "...the passphrase slot is untouched" [ "$(slots)" = "0,2" ]
check "...and the owner is told the PIN is asked at every startup" says 'The PIN is asked at every startup'
check "...and that an empty PIN goes to the passphrase" says 'Enter on an empty PIN'

header none; pinfile '123456'
run LUCCIOLA_TPM_PIN_FILE="$T/pin" -- pin 7+14
check "pin on a disk with no TPM key yet, PCRs 7+14 (rc $RC)" [ "$RC" = 0 ]
check "...enrolls, nothing to wipe" grep -qE -- '^--tpm2-device=auto --tpm2-pcrs=7\+14 --tpm2-with-pin=yes /dev/fake0p3$' "$FAKE/calls"
check "...six characters are enough" [ "$(token)" = true ]

# ── a PIN that cannot be used stops before anything changes ───────────
header plain; pinfile '12345'
run LUCCIOLA_TPM_PIN_FILE="$T/pin" -- pin
check "a five-character PIN is refused (rc $RC)" [ "$RC" != 0 ]
check "...saying the minimum" says 'at least 6 characters'
check "...systemd-cryptenroll is never called" [ "$(calls)" = 0 ]
check "...and the old key is as it was" [ "$(token)" = false ]
header plain; run -- pin
check "pin with no PIN file and no terminal is refused (rc $RC)" [ "$RC" != 0 ]
check "...saying where to run it from" says 'no terminal to ask it on'
check "...and never reaches systemd-cryptenroll, which would wait forever" [ "$(calls)" = 0 ]
header plain; printf '123456\n654321' > "$T/pin"
run LUCCIOLA_TPM_PIN_FILE="$T/pin" -- pin
check "a PIN on two lines is refused (rc $RC)" bash -c "[ '$RC' != 0 ] && [ \"\$(cat '$FAKE/calls' 2>/dev/null | wc -l)\" = 0 ]"
header plain; run LUCCIOLA_TPM_PIN_FILE="$T/absent" -- pin
check "a PIN file that is not there is refused (rc $RC)" bash -c "[ '$RC' != 0 ] && [ ! -e '$FAKE/calls' ]"

# ── enable never drops a PIN quietly ──────────────────────────────────
header pin; run -- enable
check "enable on a key that asks a PIN, with no PIN to give: refused (rc $RC)" [ "$RC" != 0 ]
check "...it says the disk keeps asking one" says 'keeps asking one'
check "...nothing is enrolled" [ "$(calls)" = 0 ]
check "...and the PIN is still there" [ "$(token)" = true ]
header pin; pinfile 'abcdef'
run LUCCIOLA_TPM_PIN_FILE="$T/pin" -- enable
check "enable on a key that asks a PIN, with a PIN: enrolls with it (rc $RC)" [ "$RC" = 0 ]
check "...--tpm2-with-pin=yes" grep -q -- '--wipe-slot=tpm2 .*--tpm2-with-pin=yes' "$FAKE/calls"
check "...and the token still asks it" [ "$(token)" = true ]
header plain; pinfile 'abcdef'
run LUCCIOLA_TPM_PIN_FILE="$T/pin" -- enable
check "enable on a key without a PIN stays without, PIN file or not (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -q -- '--tpm2-with-pin=no' '$FAKE/calls'"
check "...and hands systemd-cryptenroll no PIN" [ "$(cat "$FAKE/newpin")" = unset ]

# ── no-pin ────────────────────────────────────────────────────────────
header pin; run -- no-pin
check "no-pin on a key that asks one (rc $RC)" [ "$RC" = 0 ]
check "...re-enrolls in one call with --tpm2-with-pin=no" grep -qE -- '--wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=no /dev/fake0p3$' "$FAKE/calls"
check "...no PIN is handed over" [ "$(cat "$FAKE/newpin")" = unset ]
check "...the token asks none" [ "$(token)" = false ]
check "...the passphrase slot is untouched" [ "$(slots)" = "0,2" ]

# ── the result is checked, both ways ──────────────────────────────────
header plain; pinfile 'c0ffee42'
run LUCCIOLA_TPM_PIN_FILE="$T/pin" FAKE_IGNORE_PIN=1 -- pin
check "a key enrolled without the PIN that was asked for is an error (rc $RC)" [ "$RC" != 0 ]
check "...said in so many words" says 'WITHOUT a PIN'
header plain; pinfile 'c0ffee42'
run LUCCIOLA_TPM_PIN_FILE="$T/pin" FAKE_CRYPTENROLL_RC=1 -- pin
check "systemd-cryptenroll failing: the tool fails (rc $RC)" [ "$RC" != 0 ]
check "...the old key is intact" [ "$(token)" = false ]
check "...and the owner is told nothing was lost" says 'Nothing was lost'

# ── the passphrase stays the way in ───────────────────────────────────
header only-tpm; pinfile 'c0ffee42'
run LUCCIOLA_TPM_PIN_FILE="$T/pin" -- pin
check "no passphrase slot: pin refuses, as enable does (rc $RC)" [ "$RC" != 0 ]
check "...before anything is enrolled" [ "$(calls)" = 0 ]
check "...naming the missing fallback" says 'no human fallback keyslot'

# ── the edges ─────────────────────────────────────────────────────────
run -- pinn
check "an unknown action names the PIN ones (rc $RC)" bash -c "[ '$RC' != 0 ] && grep -q 'pin \[PCRS\] | no-pin \[PCRS\]' '$T/out'"
run -- help
check "help explains pin and no-pin" bash -c "grep -q '^  pin \[PCRS\]' '$T/out' && grep -q '^  no-pin \[PCRS\]' '$T/out'"
rm -rf "$T/root/sys/class/tpm/tpm0"; header none; pinfile 'c0ffee42'
run LUCCIOLA_TPM_PIN_FILE="$T/pin" -- pin
check "no TPM: pin refuses (rc $RC)" bash -c "[ '$RC' != 0 ] && [ ! -e '$FAKE/calls' ]"

if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
