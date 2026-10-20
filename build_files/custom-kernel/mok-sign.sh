#!/usr/bin/env bash
# Sign the kernel and its modules with the Margine MOK. The only code that
# ever runs while the private key is mounted (review N1, 2026-10-20).
#
# Until 2026-10-20 the key was mounted in the RUN that installed the kernel
# from COPR, RPM Fusion's release RPM from a URL, and then ran build.sh:
# every package scriptlet and the downloaded scrcpy ran as root next to it.
# Whoever controls one of those could copy the key and sign kernels every
# machine with the MOK enrolled would boot. Now the Containerfile runs this
# script, and nothing else, in the mok-sign stage:
#   - FROM the clean base image (the digest the build resolved), with no
#     package installed and nothing run before it: every program it calls
#     (bash, openssl, systemd-sbsign, xz, zstd, gzip, sha256sum) is the
#     base's own, not something a build step could have replaced;
#   - RUN --network=none, the key and the certificate as secret mounts;
#   - the files to sign come in read-only from the build stage, by the list
#     custom-kernel/install.sh wrote. They are data here, never executed:
#     a path that leaves /usr/lib/modules, goes through a symbolic link or
#     names anything but vmlinuz or a module is refused, so a link planted
#     next to the modules cannot make this script read the key into its
#     output.
# What it writes (the stage's /out) is public: the signed files, a manifest
# with the sha256 of each file before and after signing, and the
# certificate. finalize.sh, in the last RUN, puts them in place only if the
# files in the image are still the ones signed here.
#
# Modules are signed the way the kernel's scripts/sign-file does it, with
# openssl from the base instead of the sign-file binary of the kernel-devel
# package (which comes from the same COPR as the kernel and would run with
# the key): a detached CMS signature, SHA-256, no signed attributes, no
# certificates, the signer named by issuer and serial; then the
# module_signature trailer (id_type PKEY_ID_PKCS7, the signature's length,
# big endian) and the magic string. Byte-identical to sign-file's output
# for the same key and module (RSA PKCS#1 v1.5 is deterministic): checked
# on 2026-10-20 against sign-file of kernel-devel-7.2.11-300.fc45, twenty
# modules, all identical. Compressed modules are unpacked, signed
# and packed again with the settings the kernel's own module install uses.
#
# Usage: mok-sign.sh <modules-dir> <list> <out-dir>
#   MOK_KEY, MOK_CERT override the key and certificate paths (tests).
set -euo pipefail
export LC_ALL=C

log() { printf '[mok-sign] %s\n' "$*"; }
die() { printf '[mok-sign] ERROR: %s\n' "$*" >&2; exit 1; }

KEY="${MOK_KEY:-/run/margine-certs/MOK.key}"
CERT="${MOK_CERT:-/run/margine-certs/MOK.pem}"

# append_signature <raw-module>: sign-file, with openssl.
append_signature() {
  local f="$1" n
  openssl cms -sign -binary -noattr -nocerts -nosmimecap -md sha256 -outform DER \
    -signer "$CERT" -inkey "$KEY" -in "$f" -out "$f.p7s" 2>"$f.err" \
    || { cat "$f.err" >&2; die "openssl could not sign $f"; }
  n=$(stat -c %s "$f.p7s")
  (( n > 0 && n < 65536 )) || die "unexpected signature size $n for $f"
  {
    cat "$f.p7s"
    # struct module_signature: algo, hash, id_type = PKEY_ID_PKCS7 (2),
    # signer_len, key_id_len, pad[3], then sig_len as a big-endian u32
    printf '\x00\x00\x02\x00\x00\x00\x00\x00'
    printf '%b' "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( n >> 24 & 255 )) $(( n >> 16 & 255 )) $(( n >> 8 & 255 )) $(( n & 255 )))"
    printf '~Module signature appended~\n'
  } >> "$f"
  rm -f "$f.p7s" "$f.err"
}

# sign_one <rel>: <in>/<rel> -> <out>/files/<rel>
sign_one() {
  local rel="$1" src="$IN/$1" dst="$OUT/files/$1" raw
  mkdir -p "$(dirname "$dst")"
  case "$rel" in
    */vmlinuz)
      # SOURCE_DATE_EPOCH: systemd-sbsign stamps the signature with it, so
      # the same kernel and key give the same bytes (sbsign uses the clock).
      SOURCE_DATE_EPOCH="$SBSIGN_EPOCH" /usr/lib/systemd/systemd-sbsign sign \
        --private-key "$KEY" --certificate "$CERT" --output "$dst" "$src" >/dev/null \
        || die "systemd-sbsign failed on $rel"
      return ;;
    *.ko)     raw="$dst";        cat -- "$src" > "$raw" ;;
    *.ko.xz)  raw="${dst%.xz}";  xz -dc -- "$src" > "$raw" ;;
    *.ko.zst) raw="${dst%.zst}"; zstd -dcq -- "$src" > "$raw" ;;
    *.ko.gz)  raw="${dst%.gz}";  gzip -dc -- "$src" > "$raw" ;;
    *) die "not a module or vmlinuz: $rel" ;;
  esac
  append_signature "$raw"
  case "$rel" in
    # CRC32 and a 1 MiB dictionary, as scripts/Makefile.modinst does: with
    # CONFIG_MODULE_DECOMPRESS kmod hands the .ko.xz to the kernel, whose
    # xz decoder checks CRC32 only (xz's default, CRC64, would not load).
    *.ko.xz)  xz -z -q --check=crc32 --lzma2=dict=1MiB "$raw" ;;
    *.ko.zst) zstd -q --rm "$raw" ;;
    *.ko.gz)  gzip -q -n "$raw" ;;
  esac
  [[ -s "$dst" ]] || die "no signed output for $rel"
}

if [[ "${1:-}" == _sign ]]; then
  # Worker mode (xargs below): IN, OUT, KEY, CERT, SBSIGN_EPOCH exported.
  shift
  for rel in "$@"; do sign_one "$rel"; done
  exit 0
fi

(( $# == 3 )) || die "usage: mok-sign.sh <modules-dir> <list> <out-dir>"
IN="$(realpath -e "$1")" || die "no modules directory $1"
LIST="$2"
OUT="$3"
[[ -f "$LIST" ]] || die "no list $LIST"

[[ -f "$KEY" ]]  || die "missing MOK key (secret mok-key)"
[[ -f "$CERT" ]] || die "missing MOK certificate (secret mok-cert)"
openssl pkey -in "$KEY" -noout 2>/dev/null || die "MOK.key is not a valid private key"
openssl x509 -in "$CERT" -noout 2>/dev/null || die "MOK.pem is not a valid X509 certificate"
cmp -s <(openssl pkey -in "$KEY" -pubout 2>/dev/null) <(openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null) \
  || die "MOK.key and MOK.pem do not match"

kver="" SBSIGN_EPOCH=""
rels=()
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    ''|'#'*) ;;
    kver=*)         kver="${line#kver=}" ;;
    sbsign_epoch=*) SBSIGN_EPOCH="${line#sbsign_epoch=}" ;;
    sign=*)         rels+=("${line#sign=}") ;;
    *=*) ;;   # flavor, mtime_epoch, vmlinuz_sha256: finalize.sh's
    *) die "unreadable line in $LIST: $line" ;;
  esac
done < "$LIST"
[[ "$kver" =~ ^[A-Za-z0-9._+-]+$ && "$kver" != . && "$kver" != .. ]] || die "bad kver '$kver' in $LIST"
[[ "$SBSIGN_EPOCH" =~ ^[0-9]+$ ]] || die "bad sbsign_epoch '$SBSIGN_EPOCH' in $LIST"

# Every path: under <kver>/, plain names only, vmlinuz or a module, and
# exactly the file it names (realpath equal to the path as written: no
# symbolic link anywhere along it), a regular file.
declare -A seen=()
for rel in "${rels[@]}"; do
  [[ "$rel" == "$kver/"* && "${rel#"$kver"/}" =~ ^([A-Za-z0-9._+-]+/)*[A-Za-z0-9._+-]+$ ]] || die "refused path: $rel"
  [[ "/$rel/" != *"/../"* && "/$rel/" != *"/./"* ]] || die "refused path: $rel"
  case "$rel" in
    "$kver/vmlinuz"|*.ko|*.ko.xz|*.ko.zst|*.ko.gz) ;;
    *) die "refused path (neither vmlinuz nor a module): $rel" ;;
  esac
  real="$(realpath -e -- "$IN/$rel" 2>/dev/null)" || die "missing: $rel"
  [[ "$real" == "$IN/$rel" ]] || die "refused path (goes through a symbolic link): $rel"
  [[ -f "$real" && ! -L "$real" ]] || die "refused path (not a regular file): $rel"
  [[ -z "${seen[$rel]:-}" ]] || die "listed twice: $rel"
  seen[$rel]=1
done

mkdir -p "$OUT/files"
export IN OUT KEY CERT SBSIGN_EPOCH
if (( ${#rels[@]} )); then
  log "signing ${#rels[@]} files of $kver"
  printf '%s\0' "${rels[@]}" | xargs -0 -r -n 64 -P "$(nproc)" bash "$0" _sign
  : > "$OUT/manifest.tmp"
  for rel in "${rels[@]}"; do
    printf '%s %s %s\n' "$(sha256sum < "$IN/$rel" | cut -d' ' -f1)" \
      "$(sha256sum < "$OUT/files/$rel" | cut -d' ' -f1)" "$rel" >> "$OUT/manifest.tmp"
  done
  mv "$OUT/manifest.tmp" "$OUT/manifest"
else
  log "nothing to sign"
  : > "$OUT/manifest"
fi
# Exactly the listed files and nothing else in the output.
extra="$(cd "$OUT/files" && find . -mindepth 1 ! -type d | sed 's|^\./||' | sort \
         | comm -23 - <(printf '%s\n' "${rels[@]}" | sed '/^$/d' | sort))"
[[ -z "$extra" ]] || die "unexpected files in the output: $extra"
openssl x509 -in "$CERT" -out "$OUT/MOK.pem"
openssl x509 -in "$CERT" -outform DER -out "$OUT/MOK.der"
log "done: $(wc -l < "$OUT/manifest") files signed by $(openssl x509 -in "$CERT" -noout -subject)"
