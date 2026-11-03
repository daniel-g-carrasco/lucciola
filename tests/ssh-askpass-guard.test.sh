#!/usr/bin/env bash
# /usr/libexec/lucciola/ssh-askpass-guard with the real ssh-add and ssh-agent
# on a throwaway key: secret-tool and gcr's askpass are stubs on files, where
# the stub answers what the keyring would (the saved passphrase, or the user's
# when nothing is saved). Covered: a right saved passphrase stays, a wrong one
# is cleared and the user is asked, the loop ends, the key loads; a user who
# cancels ends ssh-add; other prompts are passed on untouched.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/lucciola/system_files/usr/libexec/lucciola/ssh-askpass-guard"
T="$(mktemp -d)"; trap '[ -n "${SSH_AGENT_PID:-}" ] && kill "$SSH_AGENT_PID" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/log" 2>/dev/null | tail -n 8; fails=$((fails+1)); fi; }
mkdir -p "$T/bin"
cat > "$T/bin/secret-tool" <<SH
#!/bin/sh
echo "clear \$*" >> "$T/log"
[ "\$1 \$2 \$3" = "clear unique ssh-store:$T/key" ] && rm -f "$T/saved"
SH
cat > "$T/real" <<SH
#!/bin/sh
echo "ask \$1" >> "$T/log"
if [ -e "$T/saved" ]; then cat "$T/saved"; else cat "$T/typed"; fi
SH
chmod +x "$T/bin/secret-tool" "$T/real"
sed "s|/usr/libexec/gcr4-ssh-askpass.real|$T/real|" "$GUARD" > "$T/guard"; chmod +x "$T/guard"
ssh-keygen -q -t ed25519 -N right -f "$T/key"
eval "$(ssh-agent -s)" >/dev/null
run() { : > "$T/log"; RC=0; PATH="$T/bin:$PATH" SSH_ASKPASS="$T/guard" SSH_ASKPASS_REQUIRE=force timeout 30 ssh-add "$T/key" </dev/null >/dev/null 2>&1 || RC=$?; }
loaded() { ssh-add -l 2>/dev/null | grep -q "$(ssh-keygen -lf "$T/key.pub" | awk '{print $2}')"; }
asked() { grep -c '^ask ' "$T/log"; }

echo right > "$T/saved"; : > "$T/typed"
run
check "right saved passphrase: loads (rc $RC)" [ "$RC" = 0 ]
check "right saved passphrase: asked once" [ "$(asked)" = 1 ]
check "right saved passphrase: it stays" [ -e "$T/saved" ]
check "right saved passphrase: nothing cleared" bash -c "! grep -q '^clear' '$T/log'"
ssh-add -D >/dev/null 2>&1

echo wrong > "$T/saved"; echo right > "$T/typed"
run
check "wrong saved passphrase: the loop ends and the key loads (rc $RC)" [ "$RC" = 0 ]
check "wrong saved passphrase: in the agent" loaded
check "wrong saved passphrase: cleared by the key's own path" grep -qx "clear clear unique ssh-store:$T/key" "$T/log"
check "wrong saved passphrase: gone" [ ! -e "$T/saved" ]
check "wrong saved passphrase: asked twice, the second time as a retry" bash -c "[ \$(grep -c '^ask ' '$T/log') = 2 ] && grep -q '^ask Bad passphrase, try again for ' '$T/log'"
ssh-add -D >/dev/null 2>&1

echo wrong > "$T/saved"; : > "$T/typed"
run
check "wrong saved passphrase, the user cancels: ssh-add ends (rc $RC)" [ "$RC" != 0 ] && [ "$RC" != 124 ]
check "wrong saved passphrase, the user cancels: not loaded" bash -c "! ssh-add -l 2>/dev/null | grep -q '$(ssh-keygen -lf "$T/key.pub" | awk '{print $2}')'"

: > "$T/log"; PATH="$T/bin:$PATH" "$T/guard" "Enter passphrase for $T/key: " > "$T/out" 2>&1 || true
check "first prompt: passed on, nothing cleared" bash -c "grep -qx 'ask Enter passphrase for $T/key: ' '$T/log' && ! grep -q '^clear' '$T/log'"
: > "$T/log"; echo right > "$T/saved"; PATH="$T/bin:$PATH" "$T/guard" "Bad passphrase, try again for /other/key (will confirm each use): " > "$T/out" 2>&1 || true
check "another key's retry: only that key is cleared" bash -c "grep -qx 'clear clear unique ssh-store:/other/key' '$T/log' && [ -e '$T/saved' ]"

echo; [ "$fails" = 0 ] && echo "ssh-askpass-guard: all checks passed" || { echo "ssh-askpass-guard: $fails failed"; exit 1; }
