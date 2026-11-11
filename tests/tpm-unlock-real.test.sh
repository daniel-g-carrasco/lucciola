#!/usr/bin/env bash
# /usr/bin/lucciola-tpm-unlock with the real systemd-cryptenroll and
# cryptsetup, against a software TPM (swtpm) and a LUKS2 header in a file.
# tests/tpm-unlock.test.sh says how the tool calls systemd-cryptenroll; this
# says the call does what the owner was promised:
# - after `pin` the TPM gives the disk key with the PIN and refuses without;
# - `enable` afterwards keeps the PIN, `no-pin` takes it away;
# - the passphrase opens the disk before, between and after;
# - the token in the header says "tpm2-pin" the way status reads it.
# Only the detection of the disk is faked (findmnt, lsblk, cryptsetup
# status): there is no encrypted root here. systemd-cryptenroll is the real
# one, reached through a wrapper that points --tpm2-device=auto at swtpm.
# Needs root (a container's is enough: nothing here needs device-mapper),
# swtpm, swtpm_setup, cryptsetup, systemd-cryptenroll, jq.
# TPM_REAL_REQUIRED=1 (CI, a Fedora container) turns a missing tool into a
# failure instead of a skip.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/build_files/system_files/usr/bin/lucciola-tpm-unlock"
missing=""
for t in swtpm swtpm_setup cryptsetup systemd-cryptenroll jq blkid; do command -v "$t" >/dev/null || missing="$missing $t"; done
[ "$(id -u)" = 0 ] || missing="$missing root"
if [ -n "$missing" ]; then
  if [ "${TPM_REAL_REQUIRED:-0}" = 1 ]; then echo "FAIL missing:$missing"; exit 1; fi
  echo "SKIP tpm-unlock-real: missing$missing (runs in the Fedora job of lint.yml, or: podman run fedora with swtpm swtpm-tools cryptsetup systemd-udev tpm2-tss jq)"
  exit 0
fi
T="$(mktemp -d)"
cleanup() { [ -n "${SWTPM_PID:-}" ] && kill "$SWTPM_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 12; fails=$((fails+1)); fi; }
says() { grep -qE -- "$1" "$T/out"; }

DISK="$T/disk.img"
mkdir -p "$T/bin" "$T/tpm" "$T/root/sys/class/tpm/tpm0" "$T/root/etc" "$T/root/boot/grub2"
echo 2 > "$T/root/sys/class/tpm/tpm0/tpm_version_major"
printf 'the old passphrase' > "$T/pw"; chmod 600 "$T/pw"
truncate -s 32M "$DISK"
cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 -q "$DISK" "$T/pw"
UUID="$(blkid -s UUID -o value "$DISK")"
printf 'luks-test UUID=%s none discard\n' "$UUID" > "$T/root/etc/crypttab"

swtpm_setup --tpm2 --tpmstate "$T/tpm" --createek --allow-signing --decryption --overwrite > "$T/swtpm-setup.log" 2>&1
swtpm socket --tpm2 --tpmstate dir="$T/tpm" --server type=tcp,port=2321 --ctrl type=tcp,port=2322 \
  --flags not-need-init,startup-clear > "$T/swtpm.log" 2>&1 &
SWTPM_PID=$!
sleep 1
# The TCTI's default address is the one swtpm listens on (127.0.0.1:2321).
TPM="swtpm:"

REAL_CRYPTSETUP="$(command -v cryptsetup)"; REAL_CRYPTENROLL="$(command -v systemd-cryptenroll)"
export DISK REAL_CRYPTSETUP REAL_CRYPTENROLL TPM
cat > "$T/bin/findmnt" <<'SH'
#!/bin/sh
[ "$3" = /sysroot ] && echo /dev/mapper/luks-test
exit 0
SH
cat > "$T/bin/lsblk" <<'SH'
#!/bin/sh
case "$*" in
  "-prno FSTYPE $DISK") echo crypto_LUKS ;;
  "-prno NAME,TYPE $DISK") printf '%s part\n/dev/mapper/luks-test crypt\n' "$DISK" ;;
  "-prno NAME /dev/mapper/luks-test -s") printf '/dev/mapper/luks-test\n%s\n' "$DISK" ;;
  "-prno NAME,FSTYPE /dev/mapper/luks-test -s") printf '/dev/mapper/luks-test btrfs\n%s crypto_LUKS\n' "$DISK" ;;
  "-prno NAME,FSTYPE") printf '%s crypto_LUKS\n' "$DISK" ;;
esac
SH
cat > "$T/bin/cryptsetup" <<'SH'
#!/bin/sh
if [ "$1" = status ]; then printf '  type:    LUKS2\n  device:  %s\n' "$DISK"; exit 0; fi
exec "$REAL_CRYPTSETUP" "$@"
SH
cat > "$T/bin/systemd-cryptenroll" <<'SH'
#!/bin/bash
args=()
for a in "$@"; do [ "$a" = --tpm2-device=auto ] && a="--tpm2-device=$TPM"; args+=("$a"); done
exec "$REAL_CRYPTENROLL" "${args[@]}"
SH
chmod +x "$T/bin"/*

run() {  # run [VAR=value ...] -- ACTION [ARGS]
  local -a env=()
  while [ "$1" != -- ]; do env+=("$1"); shift; done; shift
  RC=0
  env -i PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" DISK="$DISK" TPM="$TPM" REAL_CRYPTSETUP="$REAL_CRYPTSETUP" REAL_CRYPTENROLL="$REAL_CRYPTENROLL" \
    LUCCIOLA_TPM_UNLOCK_TEST_ROOT="$T/root" CONFIRM=yes LUCCIOLA_UNLOCK_KEY_FILE="$T/pw" "${env[@]}" \
    timeout 120 bash "$TOOL" "$@" > "$T/out" 2>&1 < /dev/null || RC=$?
}
token_pin() { "$REAL_CRYPTSETUP" luksDump --dump-json-metadata "$DISK" | jq -r '[.tokens[] | select(.type=="systemd-tpm2")] | if length == 0 then "none" else (.[0]["tpm2-pin"] // false | tostring) end'; }
passphrase_opens() { "$REAL_CRYPTSETUP" open --test-passphrase --key-file "$T/pw" "$DISK" > "$T/out" 2>&1; }
# Does the TPM give the disk key? Asked the way systemd does at startup: use
# the TPM enrollment to unlock, here to add (and at once remove) a recovery
# key. PIN="" means "no PIN given". A wrong PIN makes systemd-cryptenroll ask
# again on a terminal that is not there, so a refusal is also a timeout.
tpm_gives_key() {
  local pin="$1" rc=0
  if [ -n "$pin" ]; then
    PIN="$pin" timeout 12 "$REAL_CRYPTENROLL" --unlock-tpm2-device="$TPM" --recovery-key "$DISK" > "$T/out" 2>&1 < /dev/null || rc=$?
  else
    timeout 12 "$REAL_CRYPTENROLL" --unlock-tpm2-device="$TPM" --recovery-key "$DISK" > "$T/out" 2>&1 < /dev/null || rc=$?
  fi
  [ "$rc" = 0 ] || return 1
  "$REAL_CRYPTENROLL" --unlock-key-file="$T/pw" --wipe-slot=recovery "$DISK" > /dev/null 2>&1 || true
}
tpm_refuses() { ! tpm_gives_key "$1"; }
pinfile() { printf '%s' "$1" > "$T/pin"; chmod 600 "$T/pin"; }

check "before anything: the passphrase opens the disk" passphrase_opens

run -- enable
check "enable, the default: no PIN (rc $RC)" [ "$RC" = 0 ]
check "...the token says so" [ "$(token_pin)" = false ]
check "...and the TPM gives the key unattended" tpm_gives_key ""
check "...the startup is wired" grep -q "UUID=$UUID .*tpm2-device=auto" "$T/root/etc/crypttab"

pinfile 'c0ffee42'
run LUCCIOLA_TPM_PIN_FILE="$T/pin" -- pin
check "pin (rc $RC)" [ "$RC" = 0 ]
check "...the token asks a PIN" [ "$(token_pin)" = true ]
check "...one TPM key, not two" [ "$("$REAL_CRYPTSETUP" luksDump --dump-json-metadata "$DISK" | jq '[.tokens[] | select(.type=="systemd-tpm2")] | length')" = 1 ]
check "...the TPM gives the key with the PIN" tpm_gives_key 'c0ffee42'
check "...refuses without one" tpm_refuses ""
check "...and refuses with a wrong one" tpm_refuses 'c0ffee43'
check "...the right one still works after a wrong one" tpm_gives_key 'c0ffee42'
check "...the passphrase still opens the disk" passphrase_opens
run -- status
check "...status says the PIN is asked" says '^  PIN at startup             ✓ asked'

pinfile 'another-1'
run LUCCIOLA_TPM_PIN_FILE="$T/pin" -- enable
check "enable again, as after a Secure Boot change: the PIN stays (rc $RC)" bash -c "[ '$RC' = 0 ] && [ \"\$1\" = true ]" _ "$(token_pin)"
check "...it is the new PIN that opens" tpm_gives_key 'another-1'
run -- enable
check "enable with no PIN to give stops, and the PIN is still there (rc $RC)" bash -c "[ '$RC' != 0 ] && [ \"\$1\" = true ]" _ "$(token_pin)"

run -- no-pin
check "no-pin (rc $RC)" [ "$RC" = 0 ]
check "...the token asks none" [ "$(token_pin)" = false ]
check "...the TPM gives the key unattended again" tpm_gives_key ""
check "...the passphrase still opens the disk" passphrase_opens

run -- disable
check "disable (rc $RC)" [ "$RC" = 0 ]
check "...no TPM key left" [ "$(token_pin)" = none ]
check "...the passphrase still opens the disk" passphrase_opens

if (( fails )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
