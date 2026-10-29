#!/usr/bin/env bash
# local-models (/usr/libexec/lucciola/local-models) against fake curl,
# systemctl and lspci, in a throwaway home: the archive is used only when
# its sha256 is the pinned one; NVIDIA's CUDA libraries go unless an NVIDIA
# GPU is there; `current` points at the pinned release, older ones are
# deleted; ~/.local/bin/ollama is ours or left alone; update acts only when
# the pin moved, and --if-installed does nothing for users without it;
# remove keeps the models unless asked; the service runs on 127.0.0.1 with
# Vulkan and integrated GPUs on.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LM="$ROOT/build_files/system_files/usr/libexec/lucciola/local-models"
UNIT="$ROOT/build_files/system_files/usr/lib/systemd/user/lucciola-ollama.service"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() {  # check <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/     /' "$T/out" 2>/dev/null; fails=$((fails+1)); fi
}

# A fake release archive: bin/ollama, a Vulkan backend, two CUDA folders.
make_archive() {  # make_archive <version> -> $T/srv/v<version>/ollama-linux-amd64.tar.zst
  local v=$1 d="$T/build-$1"
  mkdir -p "$d/bin" "$d/lib/ollama/vulkan" "$d/lib/ollama/cuda_v12" "$d/lib/ollama/cuda_v13" "$T/srv/v$v"
  printf '#!/bin/sh\necho ollama %s\n' "$v" > "$d/bin/ollama"; chmod +x "$d/bin/ollama"
  echo vk > "$d/lib/ollama/vulkan/libggml-vulkan.so"; echo cu > "$d/lib/ollama/cuda_v12/libcublas.so"
  tar --zstd -cf "$T/srv/v$v/ollama-linux-amd64.tar.zst" -C "$d" .
}
pin() {  # pin <version> [sha256]
  local sha="${2:-$(sha256sum "$T/srv/v$1/ollama-linux-amd64.tar.zst" | cut -d' ' -f1)}"
  printf 'OLLAMA_VERSION=%s\nOLLAMA_SHA256=%s\n' "$1" "$sha" > "$T/release"
}
mkdir -p "$T/bin" "$T/home"
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
# -o <file> <url>: copy from the fake server; any other call (the API probe) succeeds
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift ;; -*) ;; *) url=$1 ;; esac; shift; done
echo "curl $url" >> "$FAKE_LOG"
[ -z "$out" ] && exit 0
src="$FAKE_SRV/${url#https://fake/}"
[ -f "$src" ] || exit 22
cp "$src" "$out"
SH
cat > "$T/bin/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >> "$FAKE_LOG"
case "$*" in *is-active*) [ -f "$FAKE_ACTIVE" ] ;; *) exit 0 ;; esac
SH
cat > "$T/bin/lspci" <<'SH'
#!/bin/sh
echo "c1:00.0 VGA compatible controller: $FAKE_GPU"
SH
chmod +x "$T/bin/"*
run() {  # run <args...>; RC, output in $T/out
  RC=0
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" FAKE_LOG="$T/log" FAKE_SRV="$T/srv" FAKE_ACTIVE="$T/active" \
    FAKE_GPU="${GPU:-Advanced Micro Devices, Inc. [AMD/ATI] Phoenix1}" \
    LUCCIOLA_MODELS_RELEASE="$T/release" LUCCIOLA_MODELS_URL_BASE="https://fake" \
    bash "$LM" "$@" > "$T/out" 2>&1 || RC=$?
}
D="$T/home/.local/share/lucciola/ollama"

make_archive 0.40.11; make_archive 0.41.0
pin 0.40.11
run status;  check "nothing installed: absent" grep -qx absent "$T/out"
run update --if-installed; check "update --if-installed without it: nothing, rc 0 (rc $RC)" bash -c "[ $RC = 0 ] && ! grep -q 'curl https' '$T/log' 2>/dev/null"

pin 0.40.11 0000000000000000000000000000000000000000000000000000000000000000
run install; check "an archive that is not the pinned one is refused (rc $RC)" bash -c "[ $RC != 0 ] && grep -q 'does not match the sha256' '$T/out' && [ ! -e '$D/current' ]"

pin 0.40.11
run install; check "install: rc 0 ($RC)" [ "$RC" = 0 ]
check "install: current points at the pinned release" bash -c "[ \"\$(readlink '$D/current')\" = 0.40.11 ] && [ -x '$D/0.40.11/bin/ollama' ]"
check "install, AMD: the CUDA libraries are left out, Vulkan stays" bash -c "! ls -d '$D/0.40.11/lib/ollama/'cuda_* 2>/dev/null && [ -f '$D/0.40.11/lib/ollama/vulkan/libggml-vulkan.so' ]"
check "install: ~/.local/bin/ollama points at it" bash -c "[ \"\$(readlink '$T/home/.local/bin/ollama')\" = '$D/current/bin/ollama' ]"
check "install: the service is enabled and restarted" bash -c "grep -q 'systemctl --user enable lucciola-ollama.service' '$T/log' && grep -q 'systemctl --user restart lucciola-ollama.service' '$T/log'"
check "install: the downloaded archive is not kept" bash -c "! ls '$T/home/.cache/lucciola/'*.tar.zst* 2>/dev/null"
touch "$T/active"; run status; check "status: installed, version, running" grep -qx 'installed 0.40.11 running' "$T/out"; rm -f "$T/active"

: > "$T/log"; run update --if-installed
check "update at the pinned release: no download" bash -c "! grep -q 'curl https' '$T/log' && grep -q 'is the release Lucciola pins' '$T/out'"
pin 0.41.0; GPU="NVIDIA Corporation AD107" run update --if-installed
check "update after the pin moved: the new release, the old one deleted" bash -c "[ \"\$(readlink '$D/current')\" = 0.41.0 ] && [ ! -e '$D/0.40.11' ]"
check "install, NVIDIA: the CUDA libraries stay" bash -c "ls -d '$D/0.41.0/lib/ollama/cuda_v12' >/dev/null 2>&1"

rm -f "$T/home/.local/bin/ollama"; echo '#!/bin/sh' > "$T/home/.local/bin/ollama"
run install; check "a ~/.local/bin/ollama of the user's own is left alone" bash -c "[ ! -L '$T/home/.local/bin/ollama' ]"
mkdir -p "$T/home/.ollama/models"; echo m > "$T/home/.ollama/models/blob"
run remove; check "remove: Ollama gone, the user's own command kept, the models kept" bash -c "[ ! -e '$D' ] && [ -f '$T/home/.local/bin/ollama' ] && [ -f '$T/home/.ollama/models/blob' ] && grep -q 'systemctl --user disable --now lucciola-ollama.service' '$T/log'"
run install; rm -f "$T/home/.local/bin/ollama"; run install; run remove --models
check "remove --models: the models too, and our link" bash -c "[ ! -e '$T/home/.ollama' ] && [ ! -e '$T/home/.local/bin/ollama' ]"

RC=0; env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" bash -c "id() { echo 0; }; export -f id; LUCCIOLA_MODELS_RELEASE='$T/release' bash '$LM' install" > "$T/out" 2>&1 || RC=$?
check "never as root (rc $RC)" bash -c "[ $RC != 0 ] && grep -q 'not as root' '$T/out'"

check "service: this PC only, Vulkan, integrated GPUs, a 16k context" bash -c "grep -qx 'Environment=OLLAMA_HOST=127.0.0.1:11434' '$UNIT' && grep -qx 'Environment=OLLAMA_VULKAN=1' '$UNIT' && grep -qx 'Environment=OLLAMA_IGPU_ENABLE=1' '$UNIT' && grep -qx 'Environment=OLLAMA_CONTEXT_LENGTH=16384' '$UNIT'"
check "the image pins a version and a sha256" bash -c "grep -qE '^OLLAMA_VERSION=[0-9.]+\$' '$ROOT/build_files/system_files/usr/share/lucciola/models/ollama.release' && grep -qE '^OLLAMA_SHA256=[0-9a-f]{64}\$' '$ROOT/build_files/system_files/usr/share/lucciola/models/ollama.release'"
check "the build enables the update timer for every user" grep -qx 'systemctl --global enable lucciola-ollama-update.timer' "$ROOT/lucciola/build.sh"

if (( fails )); then echo "$fails local-models check(s) failed"; exit 1; fi
echo "local-models: all checks passed"
