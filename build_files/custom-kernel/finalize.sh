#!/usr/bin/env bash
# Put the MOK-signed kernel and modules in place, write the initramfs and
# check both. Runs in the Containerfile's last RUN, after lucciola/build.sh
# and before 99-cleanup.sh, with the mok-sign stage's output mounted
# read-only at /ctx/signed (review N1, 2026-10-20). No secret here: the
# mok-sign stage hands over signed files and their certificate only.
#
# What it refuses:
#   - a file the image holds now that is not the one the mok-sign stage
#     signed (its sha256 before signing, from the manifest): something
#     changed the kernel or a module after custom-kernel listed it;
#   - a manifest that is not exactly custom-kernel's list;
#   - on the CachyOS flavour, a module of the kernel the list missed, and a
#     vmlinuz sbverify does not accept with the MOK certificate;
#   - on the Fedora flavour, a vmlinuz that is no longer Fedora's bytes;
#   - a signed module whose signer is not the MOK certificate's name.
# Then the initramfs (moved here from 50-branding: it packs the modules, so
# it must be written after the signed ones are in place) and a last check
# that dracut left vmlinuz alone.
#
# MODULES_DIR, SIGN_LIST, SIGNED_DIR and FINALIZE_STEPS=install (only put
# the files in place, as tests do on a fake tree) are for tests.
set -euo pipefail
# shellcheck source=build_files/00-common.sh
. "${COMMON_SH:-/ctx/00-common.sh}"
log() { printf '[kernel-finalize] %s\n' "$*"; }
err() { printf '[kernel-finalize] ERROR: %s\n' "$*" >&2; }
refuse_signing_key

MODULES_DIR="${MODULES_DIR:-/usr/lib/modules}"
SIGN_LIST="${SIGN_LIST:-/usr/share/margine/mok-sign.list}"
SIGNED_DIR="${SIGNED_DIR:-/ctx/signed}"
STEPS="${FINALIZE_STEPS:-all}"

[[ -f "$SIGN_LIST" ]] || { err "no $SIGN_LIST: custom-kernel/install.sh did not run"; exit 1; }
[[ -f "$SIGNED_DIR/manifest" && -f "$SIGNED_DIR/MOK.der" && -f "$SIGNED_DIR/MOK.pem" ]] \
  || { err "no mok-sign output in $SIGNED_DIR"; exit 1; }

flavor="" kver="" mtime_epoch="" vmlinuz_sha=""
listed=()
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    flavor=*)         flavor="${line#flavor=}" ;;
    kver=*)           kver="${line#kver=}" ;;
    mtime_epoch=*)    mtime_epoch="${line#mtime_epoch=}" ;;
    vmlinuz_sha256=*) vmlinuz_sha="${line#vmlinuz_sha256=}" ;;
    sign=*)           listed+=("${line#sign=}") ;;
  esac
done < "$SIGN_LIST"
[[ "$flavor" == cachyos || "$flavor" == fedora ]] || { err "unknown flavor '$flavor' in $SIGN_LIST"; exit 1; }
[[ -n "$kver" && -d "$MODULES_DIR/$kver" ]] || { err "kernel '$kver' of $SIGN_LIST is not in $MODULES_DIR"; exit 1; }
[[ "$mtime_epoch" =~ ^[0-9]+$ ]] || { err "bad mtime_epoch in $SIGN_LIST"; exit 1; }
[[ "$vmlinuz_sha" =~ ^[0-9a-f]{64}$ ]] || { err "no vmlinuz checksum in $SIGN_LIST"; exit 1; }
VMLINUZ="$MODULES_DIR/$kver/vmlinuz"

# The manifest names exactly the listed files.
if ! diff <(printf '%s\n' "${listed[@]}" | sed '/^$/d' | LC_ALL=C sort) \
          <(awk '{print $3}' "$SIGNED_DIR/manifest" | LC_ALL=C sort) >/dev/null; then
  err "the mok-sign manifest does not name exactly the files custom-kernel listed"
  exit 1
fi

# Every module of the CachyOS kernel was listed: none ships unsigned.
if [[ "$flavor" == cachyos ]]; then
  missing="$(cd "$MODULES_DIR" && find "$kver" -type f \( -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) \
             | LC_ALL=C sort | LC_ALL=C comm -23 - <(printf '%s\n' "${listed[@]}" | LC_ALL=C sort))"
  [[ -z "$missing" ]] || { err "modules the MOK did not sign: $(head -n5 <<<"$missing" | tr '\n' ' ')"; exit 1; }
  # (A here-string, not printf | grep -q: with pipefail, grep leaving early
  # makes printf of six thousand lines die of SIGPIPE and the test fail.)
  grep -qxF "$kver/vmlinuz" <<<"$(printf '%s\n' "${listed[@]}")" || { err "vmlinuz was not listed for the MOK"; exit 1; }
fi

# vmlinuz is still what the kernel step left (unsigned CachyOS, or Fedora's).
[[ "$(sha256sum < "$VMLINUZ" | cut -d' ' -f1)" == "$vmlinuz_sha" ]] \
  || { err "vmlinuz changed after the kernel step"; exit 1; }

# In place, by content: the same inode, mode, owner and xattrs.
n=0
while read -r before after rel; do
  f="$MODULES_DIR/$rel"
  [[ -f "$f" && ! -L "$f" ]] || { err "$rel: not a regular file in the image"; exit 1; }
  [[ "$(sha256sum < "$f" | cut -d' ' -f1)" == "$before" ]] \
    || { err "$rel changed after it was listed for signing: refusing to put a signature on other bytes"; exit 1; }
  cat -- "$SIGNED_DIR/files/$rel" > "$f"
  [[ "$(sha256sum < "$f" | cut -d' ' -f1)" == "$after" ]] || { err "$rel: signed copy damaged"; exit 1; }
  touch -h -d "@${mtime_epoch}" "$f"
  n=$((n + 1))
done < "$SIGNED_DIR/manifest"
log "$n MOK-signed files in place for $kver ($flavor)"

install -D -m0644 "$SIGNED_DIR/MOK.der" "${MOK_DER:-/usr/share/cert/MOK.der}"
log "MOK certificate installed: $(openssl x509 -in "$SIGNED_DIR/MOK.pem" -noout -subject)"

[[ "$STEPS" == install ]] && exit 0

# ---------------------------------------------------------------------------
# Checks with the tools of the image
# ---------------------------------------------------------------------------
cn="$(openssl x509 -in "$SIGNED_DIR/MOK.pem" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p')"
[[ -n "$cn" ]] || { err "no CN in the MOK certificate"; exit 1; }
if [[ "$flavor" == cachyos ]]; then
  sbverify --cert "$SIGNED_DIR/MOK.pem" "$VMLINUZ" >/dev/null \
    || { err "sbverify does not accept vmlinuz with the MOK certificate"; exit 1; }
  log "vmlinuz: signature verified against the MOK certificate ($cn)"
else
  grep -q 'Fedora' <<<"$(sbverify --list "$VMLINUZ" 2>&1 || true)" \
    || { err "the reserve's vmlinuz no longer carries Fedora's signature"; exit 1; }
  log "vmlinuz: Fedora's signature, untouched"
fi
mapfile -t mods < <(awk '$3 !~ /\/vmlinuz$/ {print $3}' "$SIGNED_DIR/manifest")
if (( ${#mods[@]} )); then
  signers="$(cd "$MODULES_DIR" && printf '%s\0' "${mods[@]}" | xargs -0 -n 256 modinfo -F signer | sort | uniq -c)"
  if [[ "$(wc -l <<<"$signers")" != 1 || "$(awk '{print $1}' <<<"$signers")" != "${#mods[@]}" \
        || "$(sed -E 's/^ *[0-9]+ //' <<<"$signers")" != "$cn" ]]; then
    err "modules not all signed by '$cn': $(head -n5 <<<"$signers" | tr '\n' ' ')"
    exit 1
  fi
  log "${#mods[@]} modules: signer '$cn'"
fi
# sbsigntools was only for the checks above (custom-kernel installs it).
rpm -e sbsigntools

# ---------------------------------------------------------------------------
# The initramfs
# ---------------------------------------------------------------------------
# THE initramfs of the build (2026-10-18: custom-kernel no longer makes a
# first one that this run always replaced; 2026-10-20: written here rather
# than in 50-branding, after the signed modules). Output goes to
# /usr/lib/modules/<KVER>/initramfs.img, the bootc/ostree-expected path.
# regenerate_initramfs (00-common.sh): generic (custom-kernel's
# 01-margine-no-hostonly.conf), --add ostree (without which switch-root
# fails, see custom-kernel/install.sh), zstd, and byte-reproducible (same
# packages, same bytes, whatever the build date).
command -v dracut >/dev/null 2>&1 || { err "dracut missing: no initramfs, no boot"; exit 1; }
for kver_dir in "$MODULES_DIR"/*/; do
  k=$(basename "$kver_dir")
  regenerate_initramfs "$k" || { err "dracut failed for $k"; exit 1; }
  [[ -s "${kver_dir}initramfs.img" ]] || { err "no initramfs written for $k"; exit 1; }
  # The splash is only what the initramfs carries: the theme 50-branding
  # installed, its plugin, the text renderer and the configuration with
  # DeviceScale.
  ird="$(lsinitrd "${kver_dir}initramfs.img" 2>/dev/null || true)"
  for want in usr/share/plymouth/themes/lucciola/lucciola.script usr/share/plymouth/themes/lucciola/wordmark-720.png \
              usr/lib64/plymouth/script.so usr/lib64/plymouth/label-freetype.so; do
    grep -q " ${want}\$" <<<"$ird" || { err "the initramfs for $k lacks $want"; exit 1; }
  done
  lsinitrd -f etc/plymouth/plymouthd.conf "${kver_dir}initramfs.img" 2>/dev/null | grep -qx 'DeviceScale=1' \
    || { err "the initramfs for $k has no DeviceScale=1 in plymouthd.conf"; exit 1; }
  log "Wrote ${kver_dir}initramfs.img ($(du -h "${kver_dir}initramfs.img" | cut -f1), Plymouth theme lucciola)"
done

# vmlinuz must still be the bytes the mok-sign stage signed (or Fedora's):
# a rewrite would ship a kernel Secure Boot rejects with the cryptic "bad
# shim signature".
want="$(awk -v r="$kver/vmlinuz" '$3 == r {print $2}' "$SIGNED_DIR/manifest")"
[[ -n "$want" ]] || want="$vmlinuz_sha"
[[ "$(sha256sum < "$VMLINUZ" | cut -d' ' -f1)" == "$want" ]] || { err "vmlinuz changed after signing"; exit 1; }
log "vmlinuz still the signed bytes after dracut"

rm -f "$SIGN_LIST"
