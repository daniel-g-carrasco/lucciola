#!/usr/bin/env bash
# The MOK signer (build_files/custom-kernel/mok-sign.sh) and the step that
# puts its output in place (finalize.sh, install part), on a fake module
# tree with a throwaway key made here (review N1, 2026-10-20):
#   - every module comes out with the kernel's signature trailer, the CMS
#     signature verifies against the certificate over the original bytes,
#     and xz/zstd/gzip modules are packed again;
#   - vmlinuz is signed with systemd-sbsign (when the host has it and a PE
#     image to sign: TEST_PE, the running kernel, or systemd-boot's EFI
#     binary; without them a stub stands in for vmlinuz so that finalize.sh
#     is still exercised, and MOK_TEST_REQUIRE_PE=1 makes that a failure
#     instead of a skip, as lint.yml asks);
#   - paths that leave the tree, go through a symbolic link (one pointing
#     at the key) or name anything but a module or vmlinuz are refused, as
#     are a key that does not match the certificate and a missing key;
#   - no private key material reaches the output;
#   - finalize.sh refuses files that changed after they were listed, a
#     manifest that is not the list, and an unlisted CachyOS module.
# Needs openssl, xz, zstd, gzip and python3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNER="$ROOT/build_files/custom-kernel/mok-sign.sh"
FINALIZE="$ROOT/build_files/custom-kernel/finalize.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 20 || true; fails=$((fails+1)); fi
}

# Throwaway key and certificate (never the project's).
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Throwaway Test MOK" \
  -keyout "$T/MOK.key" -out "$T/MOK.pem" 2>/dev/null
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Other" \
  -keyout "$T/other.key" -out "$T/other.pem" 2>/dev/null

K=6.0.0-test.x86_64
mk_tree() {  # mk_tree <dir>
  local d="$1/$K/kernel/drivers"
  mkdir -p "$d"
  head -c 6000 /dev/urandom > "$d/plain.ko"
  head -c 5000 /dev/urandom > "$T/raw-xz";  xz -z -c --check=crc32 "$T/raw-xz" > "$d/packed.ko.xz"
  head -c 5000 /dev/urandom > "$T/raw-zst"; zstd -q -c "$T/raw-zst" > "$d/packed.ko.zst"
  head -c 5000 /dev/urandom > "$T/raw-gz";  gzip -n -c "$T/raw-gz" > "$d/packed.ko.gz"
}
mk_list() {  # mk_list <tree> <list> [extra sign= lines...]; MK_SKIP_VMLINUZ=1 leaves vmlinuz out of sign=
  local tree="$1" list="$2"; shift 2
  {
    echo "# test list"
    echo "flavor=${FLAVOR:-cachyos}"
    echo "kver=$K"
    echo "sbsign_epoch=1700000000"
    echo "mtime_epoch=1700000000"
    (cd "$tree" && find "$K" -type f \( -name '*.ko*' -o -name vmlinuz \) | LC_ALL=C sort \
       | { if (( ${MK_SKIP_VMLINUZ:-0} )); then sed '/\/vmlinuz$/d'; else cat; fi; } | sed 's/^/sign=/')
    for x in "$@"; do echo "sign=$x"; done
    echo "vmlinuz_sha256=$(sha256sum < "$tree/$K/vmlinuz" | cut -d' ' -f1)"
  } > "$list"
}
sign() {  # sign <tree> <list> <out> [key] [cert] ; sets RC
  RC=0
  rm -rf "$3"
  MOK_KEY="${4:-$T/MOK.key}" MOK_CERT="${5:-$T/MOK.pem}" bash "$SIGNER" "$1" "$2" "$3" > "$T/out" 2>&1 || RC=$?
}

mk_tree "$T/tree"
# A PE image for vmlinuz: TEST_PE, the running kernel (Fedora keeps it
# readable under /usr/lib/modules; Ubuntu's /boot/vmlinuz-* is root-only),
# or systemd-boot's EFI binary.
HAVE_PE=0; PE=""
for cand in "${TEST_PE:-}" "/usr/lib/modules/$(uname -r)/vmlinuz" /usr/lib/systemd/boot/efi/systemd-bootx64.efi; do
  [[ -n "$cand" && -r "$cand" ]] && { PE="$cand"; break; }
done
if [[ -x /usr/lib/systemd/systemd-sbsign && -n "$PE" ]]; then
  cp "$PE" "$T/tree/$K/vmlinuz"; HAVE_PE=1
elif [[ "${MOK_TEST_REQUIRE_PE:-0}" != 0 ]]; then
  echo "FAIL vmlinuz signing cannot run here: no /usr/lib/systemd/systemd-sbsign or no PE image (MOK_TEST_REQUIRE_PE is set)"; exit 1
else
  # The signer cannot take vmlinuz without systemd-sbsign, so it gets the
  # modules only; a stub stands in for vmlinuz where finalize.sh needs one.
  echo "skip vmlinuz signing: no /usr/lib/systemd/systemd-sbsign or no PE image on this host (a stub stands in for finalize.sh)"
  head -c 4096 /dev/urandom > "$T/tree/$K/vmlinuz"
fi
cp -a "$T/tree" "$T/tree.orig"
MK_SKIP_VMLINUZ=$((1 - HAVE_PE)) mk_list "$T/tree" "$T/list"
sign "$T/tree" "$T/list" "$T/o"
check "signs the listed files (rc $RC)" [ "$RC" = 0 ]

# Each module: trailer, CMS signature over the original bytes.
python3 - "$T/o" "$T/tree.orig" "$K" "$T/MOK.pem" > "$T/out" 2>&1 <<'PY' && RC=0 || RC=$?
import gzip, lzma, os, struct, subprocess, sys, tempfile
out, orig, k, cert = sys.argv[1:]
MAGIC = b"~Module signature appended~\n"
def unpack(path, data):
    if path.endswith(".xz"):
        return lzma.decompress(data)
    if path.endswith(".zst"):
        return subprocess.run(["zstd", "-dcq"], input=data, capture_output=True, check=True).stdout
    if path.endswith(".gz"):
        return gzip.decompress(data)
    return data
bad = 0
for dp, _, fs in os.walk(os.path.join(out, "files", k)):
    for f in fs:
        if f == "vmlinuz":
            continue
        p = os.path.join(dp, f)
        rel = os.path.relpath(p, os.path.join(out, "files"))
        if p.endswith(".xz"):
            with open(p, "rb") as fh:
                # CRC32 check type (flag byte 0x01), as the kernel's xz decoder needs
                if fh.read(8)[7] != 0x01:
                    print(f"{rel}: xz check is not CRC32"); bad += 1
        signed = unpack(p, open(p, "rb").read())
        if not signed.endswith(MAGIC):
            print(f"{rel}: no signature magic"); bad += 1; continue
        algo, hsh, idt, sl, kl, siglen = struct.unpack(">BBBBB3xI", signed[-len(MAGIC) - 12:-len(MAGIC)])
        if (algo, hsh, idt, sl, kl) != (0, 0, 2, 0, 0):
            print(f"{rel}: module_signature header {algo, hsh, idt, sl, kl}"); bad += 1
        body_end = len(signed) - len(MAGIC) - 12 - siglen
        content, sig = signed[:body_end], signed[body_end:body_end + siglen]
        original = unpack(p, open(os.path.join(orig, rel), "rb").read())
        if content != original:
            print(f"{rel}: signed content is not the original module"); bad += 1
        with tempfile.TemporaryDirectory() as td:
            open(f"{td}/c", "wb").write(content); open(f"{td}/s", "wb").write(sig)
            r = subprocess.run(["openssl", "cms", "-verify", "-binary", "-inform", "DER", "-in", f"{td}/s",
                                "-content", f"{td}/c", "-certfile", cert, "-noverify", "-out", "/dev/null"],
                               capture_output=True, text=True)
            if r.returncode:
                print(f"{rel}: CMS signature does not verify: {r.stderr.strip()}"); bad += 1
print(f"checked, {bad} bad")
sys.exit(1 if bad else 0)
PY
check "modules: trailer, CRC32 xz, CMS signature over the original bytes" [ "$RC" = 0 ]
check "manifest: one line per listed file" [ "$(wc -l < "$T/o/manifest")" = "$(grep -c '^sign=' "$T/list")" ]
check "certificate handed over (PEM and DER)" test -s "$T/o/MOK.pem" -a -s "$T/o/MOK.der"
if (( HAVE_PE )); then
  check "vmlinuz: signed copy differs and carries the certificate" python3 - "$T/o/files/$K/vmlinuz" "$T/tree.orig/$K/vmlinuz" "$T/o/MOK.der" <<'PY'
import sys
s, o, c = (open(p, "rb").read() for p in sys.argv[1:])
sys.exit(0 if s != o and c in s else 1)
PY
  if command -v sbverify >/dev/null; then
    sbverify --cert "$T/MOK.pem" "$T/o/files/$K/vmlinuz" > "$T/out" 2>&1 && RC=0 || RC=$?
    check "vmlinuz: sbverify accepts it with the certificate" [ "$RC" = 0 ]
  fi
fi
# No private key material in the output.
python3 - "$T/o" "$T/MOK.key" > "$T/out" 2>&1 <<'PY' && RC=0 || RC=$?
import os, subprocess, sys
out, key = sys.argv[1:]
der = subprocess.run(["openssl", "pkey", "-in", key, "-outform", "DER"], capture_output=True, check=True).stdout
needles = [b"PRIVATE KEY", der[-64:], der[len(der) // 2:len(der) // 2 + 64]]
for dp, _, fs in os.walk(out):
    for f in fs:
        data = open(os.path.join(dp, f), "rb").read()
        if any(n in data for n in needles):
            print(f"key material in {f}"); sys.exit(1)
PY
check "no private key material in the output" [ "$RC" = 0 ]

# Refusals: each leaves no signed output.
refused() {  # refused <name> <list-extra-or-setup...>
  local name="$1"
  check "$name (rc $RC)" bash -c "[ '$RC' != 0 ] && [ ! -s '$T/r/manifest' ]"
}
MK_SKIP_VMLINUZ=$((1 - HAVE_PE))
mk_list "$T/tree" "$T/l2" "$K/../$K/kernel/drivers/plain.ko"
sign "$T/tree" "$T/l2" "$T/r"; refused "refuses a path with .."
ln -s "$T/MOK.key" "$T/tree/$K/kernel/drivers/evil.ko"
mk_list "$T/tree" "$T/l2" "$K/kernel/drivers/evil.ko"
sign "$T/tree" "$T/l2" "$T/r"; refused "refuses a module that is a link to the key"
rm "$T/tree/$K/kernel/drivers/evil.ko"
mkdir -p "$T/elsewhere/x"; head -c 100 /dev/urandom > "$T/elsewhere/x/a.ko"
ln -s "$T/elsewhere/x" "$T/tree/$K/linked"
mk_list "$T/tree" "$T/l2" "$K/linked/a.ko"
sign "$T/tree" "$T/l2" "$T/r"; refused "refuses a path through a linked directory"
rm "$T/tree/$K/linked"
head -c 100 /dev/urandom > "$T/tree/$K/notes.txt"
mk_list "$T/tree" "$T/l2" "$K/notes.txt"
sign "$T/tree" "$T/l2" "$T/r"; refused "refuses a file that is neither a module nor vmlinuz"
rm "$T/tree/$K/notes.txt"
mk_list "$T/tree" "$T/l2" "other-kver/kernel/x.ko"
sign "$T/tree" "$T/l2" "$T/r"; refused "refuses a path outside the listed kernel"
sign "$T/tree" "$T/list" "$T/r" "$T/other.key" "$T/MOK.pem"; refused "refuses a key that does not match the certificate"
sign "$T/tree" "$T/list" "$T/r" "$T/missing.key"; refused "refuses to run without the key"
unset MK_SKIP_VMLINUZ

# finalize.sh, install part, on a copy of the tree. The CachyOS flavour
# wants vmlinuz listed and in the manifest: without systemd-sbsign the
# signer never saw it, so the stub goes into a copy of the output by hand,
# the same bytes before and after, as the 2500-module case does below.
sed -n '/^refuse_signing_key() {/,/^}/p' "$ROOT/build_files/00-common.sh" > "$T/common.sh"
fin() {  # fin <tree> <list> <signed> ; sets RC
  RC=0
  env COMMON_SH="$T/common.sh" MODULES_DIR="$1" SIGN_LIST="$2" SIGNED_DIR="$3" \
      MOK_DER="$T/installed/MOK.der" FINALIZE_STEPS=install bash "$FINALIZE" > "$T/out" 2>&1 || RC=$?
}
refused_by() {  # refused_by <name> <reason-regex> ; RC must be 1 and the reason logged
  check "$1 (rc $RC)" bash -c "[ '$RC' = 1 ] && grep -q '$2' '$T/out'"
}
if (( HAVE_PE )); then
  FIN_LIST="$T/list"; FIN_OUT="$T/o"
else
  mk_list "$T/tree.orig" "$T/list.fin"
  cp -a "$T/o" "$T/o.fin"; cp "$T/tree.orig/$K/vmlinuz" "$T/o.fin/files/$K/vmlinuz"
  h="$(sha256sum < "$T/tree.orig/$K/vmlinuz" | cut -d' ' -f1)"; echo "$h $h $K/vmlinuz" >> "$T/o.fin/manifest"
  FIN_LIST="$T/list.fin"; FIN_OUT="$T/o.fin"
fi
cp -a "$T/tree.orig" "$T/img"
fin "$T/img" "$FIN_LIST" "$FIN_OUT"
check "finalize: puts the signed files in place (rc $RC)" [ "$RC" = 0 ]
check "finalize: image files are the signed bytes" diff -r "$T/img/$K" "$FIN_OUT/files/$K"
check "finalize: certificate installed" cmp -s "$T/installed/MOK.der" "$FIN_OUT/MOK.der"
check "finalize: mtime pinned to the kernel's build time" \
  [ "$(stat -c %Y "$T/img/$K/kernel/drivers/plain.ko")" = 1700000000 ]
cp -a "$T/tree.orig" "$T/img2"
head -c 10 /dev/urandom >> "$T/img2/$K/kernel/drivers/packed.ko.zst"
fin "$T/img2" "$FIN_LIST" "$FIN_OUT"
refused_by "finalize: refuses a module that changed after it was listed" 'changed after it was listed for signing'
cp -a "$FIN_OUT" "$T/o-short"; sed -i '1d' "$T/o-short/manifest"
cp -a "$T/tree.orig" "$T/img3"
fin "$T/img3" "$FIN_LIST" "$T/o-short"
refused_by "finalize: refuses a manifest that is not the list" 'does not name exactly the files'
cp -a "$T/tree.orig" "$T/img4"
head -c 100 /dev/urandom > "$T/img4/$K/kernel/drivers/unlisted.ko"
fin "$T/img4" "$FIN_LIST" "$FIN_OUT"
refused_by "finalize: refuses an unlisted CachyOS module" 'modules the MOK did not sign'
cp -a "$T/tree.orig" "$T/img5"
head -c 10 /dev/urandom >> "$T/img5/$K/vmlinuz"
fin "$T/img5" "$FIN_LIST" "$FIN_OUT"
refused_by "finalize: refuses a vmlinuz that is no longer the kernel step's" 'vmlinuz changed after the kernel step'

# Thousands of modules, as a real kernel has (6492): the checks over the
# whole list must not trip on their own size (a pipe into grep -q died of
# SIGPIPE under pipefail on the first real build; 2500 short paths already
# overflow the 64 KiB pipe buffer).
mkdir -p "$T/big/$K/kernel"
for i in $(seq 1 2500); do printf '%s' "$i" > "$T/big/$K/kernel/m$i.ko"; done
cp "$T/tree.orig/$K/vmlinuz" "$T/big/$K/vmlinuz"
# vmlinuz first, as custom-kernel lists it.
{
  echo "flavor=cachyos"; echo "kver=$K"; echo "sbsign_epoch=1700000000"; echo "mtime_epoch=1700000000"
  echo "sign=$K/vmlinuz"
  (cd "$T/big" && find "$K/kernel" -type f | LC_ALL=C sort | sed 's/^/sign=/')
  echo "vmlinuz_sha256=$(sha256sum < "$T/big/$K/vmlinuz" | cut -d' ' -f1)"
} > "$T/big.list"
# A manifest for it as the signer would write one, without signing 7000 files.
mkdir -p "$T/bo/files"
cp -a "$T/big/$K" "$T/bo/files/"
( cd "$T/big" && find "$K" -type f -print0 | xargs -0 sha256sum | awk '{print $1, $1, $2}' ) > "$T/bo/manifest"
cp "$T/o/MOK.pem" "$T/o/MOK.der" "$T/bo/"
fin "$T/big" "$T/big.list" "$T/bo"
check "2500 modules: finalize goes through the whole list (rc $RC)" [ "$RC" = 0 ]

# The kernel reserve (Fedora flavour): only the modules built here are
# listed; vmlinuz and Fedora's modules stay as they are.
cp -a "$T/tree.orig" "$T/fed"
{
  echo "flavor=fedora"; echo "kver=$K"; echo "sbsign_epoch=1700000000"; echo "mtime_epoch=1700000000"
  echo "sign=$K/kernel/drivers/plain.ko"
  echo "vmlinuz_sha256=$(sha256sum < "$T/fed/$K/vmlinuz" | cut -d' ' -f1)"
} > "$T/fed.list"
sign "$T/fed" "$T/fed.list" "$T/fo"
check "fedora flavour: signs the listed module only (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && [ \"\$(cd '$T/fo/files' && find . -type f)\" = './$K/kernel/drivers/plain.ko' ]"
fin "$T/fed" "$T/fed.list" "$T/fo"
check "fedora flavour: finalize installs it, vmlinuz and the other modules untouched (rc $RC)" \
  bash -c "[ '$RC' = 0 ] && cmp -s '$T/fed/$K/vmlinuz' '$T/tree.orig/$K/vmlinuz' \
           && cmp -s '$T/fed/$K/kernel/drivers/packed.ko.zst' '$T/tree.orig/$K/kernel/drivers/packed.ko.zst' \
           && ! cmp -s '$T/fed/$K/kernel/drivers/plain.ko' '$T/tree.orig/$K/kernel/drivers/plain.ko'"
cp -a "$T/tree.orig" "$T/fed2"
head -c 10 /dev/urandom >> "$T/fed2/$K/vmlinuz"
fin "$T/fed2" "$T/fed.list" "$T/fo"
refused_by "fedora flavour: refuses a vmlinuz that is no longer the kernel step's" 'vmlinuz changed after the kernel step'

[ "$fails" = 0 ] && echo "mok-sign: all checks passed" || { echo "mok-sign: $fails failed"; exit 1; }
