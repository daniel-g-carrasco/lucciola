#!/usr/bin/env bash
# prune_stray_module_dirs (00-common.sh), on temp folders with a fake rpm that
# owns the folders named owned-*. What must hold: the skeleton the base carries
# goes, anything that could be a kernel stays for the build's check to refuse.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null || true; fails=$((fails + 1)); fi
}
absent() { [ ! -e "$1" ]; }

mkdir "$T/bin"
cat > "$T/bin/rpm" <<'RPM'
#!/bin/sh
case "$2" in */owned-*) echo some-package; exit 0 ;; esac
echo "file $2 is not owned by any package"; exit 1
RPM
chmod +x "$T/bin/rpm"

prune() {
  env PATH="$T/bin:$PATH" SOURCE_DATE_EPOCH=1 FEDORA_VER=45 MARGINE_MODULES_DIR="$T/modules" \
    bash -c ". '$ROOT/build_files/00-common.sh'; prune_stray_module_dirs" > "$T/out" 2>&1
}
kernel() { mkdir -p "$T/modules/$1/kernel/drivers"; : > "$T/modules/$1/vmlinuz"; : > "$T/modules/$1/kernel/drivers/a.ko.zst"; }
skeleton() { mkdir -p "$T/modules/$1/kernel/drivers/usb"; : > "$T/modules/$1/modules.dep"; printf '# Aliases\n' > "$T/modules/$1/modules.alias"; }
fresh() { rm -rf "$T/modules"; mkdir "$T/modules"; }

fresh; kernel 7.2.13; skeleton 7.2.15; prune
check "the skeleton beside the real kernel goes" absent "$T/modules/7.2.15"
check "the real kernel stays" [ -f "$T/modules/7.2.13/vmlinuz" ]
check "what was removed is said" grep -q 'removing .*7.2.15' "$T/out"

fresh; kernel 7.2.13; prune
check "one kernel alone is left as it is, in silence" [ ! -s "$T/out" ]
check "one kernel alone stays" [ -f "$T/modules/7.2.13/vmlinuz" ]

fresh; kernel 7.2.13; kernel 7.2.15; prune
check "a second real kernel stays, for the build's check to refuse" [ -f "$T/modules/7.2.15/vmlinuz" ]

fresh; kernel 7.2.13; mkdir -p "$T/modules/extra/updates"; : > "$T/modules/extra/updates/b.ko.xz"; prune
check "a folder with a module stays" [ -f "$T/modules/extra/updates/b.ko.xz" ]

fresh; kernel 7.2.13; mkdir "$T/modules/owned-by-a-package"; prune
check "a folder a package owns stays" [ -d "$T/modules/owned-by-a-package" ]

fresh; prune
check "an empty modules folder is no error" [ ! -s "$T/out" ]

if (( fails )); then echo "$fails stray-module-dirs case(s) failed"; exit 1; fi
echo "all stray-module-dirs cases passed"
