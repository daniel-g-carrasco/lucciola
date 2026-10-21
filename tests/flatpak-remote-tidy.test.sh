#!/usr/bin/env bash
# flatpak-remote-tidy: the fedora remotes of a stock Fedora start go, unless
# apps came from them; Flathub and unknown remotes are never touched.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
tidy="$here/build_files/system_files/usr/libexec/margine/flatpak-remote-tidy"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
mkstub() { # remotes origins
  cat > "$T/flatpak" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "remotes --system") printf '%b' '$1' ;;
  "list --system") printf '%b' '$2' ;;
  "remote-delete --system") echo "\$3" >> "$T/deleted" ;;
  *) echo "unexpected: \$*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$T/flatpak"; rm -f "$T/deleted"
}
run() { FLATPAK="$T/flatpak" bash "$tidy" >"$T/out" 2>&1; echo $?; }
deleted() { [[ -f "$T/deleted" ]] && tr '\n' ' ' < "$T/deleted" | sed 's/ $//'; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got [$2], want [$3]"; fail=1; fi; }

mkstub 'flathub\nfedora\nfedora-testing\n' 'flathub\nflathub\n'
check "stock start, nothing from fedora: both removed" "$(run):$(deleted)" "0:fedora fedora-testing"
mkstub 'flathub\nfedora\n' 'flathub\nfedora\n'
check "an app from fedora: the remote stays" "$(run):$(deleted)" "0:"
grep -q "stays" "$T/out" || { echo "FAIL no notice that it stays"; fail=1; }
mkstub 'flathub\n' 'flathub\n'
check "flathub alone: nothing to do" "$(run):$(deleted)" "0:"
mkstub 'flathub\nmyrepo\n' ''
check "an unknown remote is never touched" "$(run):$(deleted)" "0:"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/flatpak"; chmod +x "$T/flatpak"
check "flatpak unusable: exits 0, deletes nothing" "$(run):$(deleted)" "0:"
[[ -x "$tidy" ]] || { echo "FAIL helper not executable"; fail=1; }
grep -q '^ExecStartPre=-/usr/libexec/margine/flatpak-remote-tidy$' \
  "$here/build_files/system_files/usr/lib/systemd/system/flatpak-preinstall.service.d/10-margine.conf" \
  || { echo "FAIL not wired into the preinstall drop-in"; fail=1; }
[[ $fail = 0 ]] && echo "all flatpak-remote-tidy tests passed"
exit $fail
