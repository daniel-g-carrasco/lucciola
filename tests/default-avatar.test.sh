#!/usr/bin/env bash
# shellcheck disable=SC2016  # the bash -c snippets below expand their own $1
# Tests for /usr/libexec/lucciola/default-avatar (the firefly as the picture
# of accounts without one) on throwaway files: DEFAULT_AVATAR_* point it at a
# temp AccountsService directory, a fake passwd and a fake picture.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/lucciola/system_files/usr/libexec/lucciola/default-avatar"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
S="$T/AccountsService"
fails=0

printf 'firefly' > "$T/lucciola.png"
cat > "$T/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
greetd:x:973:973::/var/lib/greetd:/usr/sbin/nologin
alice:x:1000:1000::/var/home/alice:/bin/bash
bob:x:1001:1001::/var/home/bob:/usr/bin/zsh
carol:x:1002:1002::/var/home/carol:/bin/bash
dave:x:1003:1003::/var/home/dave:/bin/bash
erin:x:1004:1004::/var/home/erin:/bin/bash
svc:x:1500:1500::/var/lib/svc:/usr/sbin/nologin
nobody:x:65534:65534:Kernel Overflow User:/:/usr/sbin/nologin
EOF

fresh() {
  rm -rf "$S"; mkdir -p "$S/users" "$S/icons"
  # bob chose a picture; carol removed hers (empty Icon=); dave has a file
  # without Icon=; erin has none of it yet; alice has no file at all.
  printf '[User]\nSession=lucciola\nIcon=/var/lib/AccountsService/icons/bob\n' > "$S/users/bob"
  printf 'bob' > "$S/icons/bob"
  printf '[User]\nIcon=\nSession=lucciola\n' > "$S/users/carol"
  printf '[User]\nSession=lucciola\nSystemAccount=false\n' > "$S/users/dave"
}
run() {
  RC=0
  OUT="$(env -i PATH=/usr/bin:/bin DEFAULT_AVATAR_STATE="$S" DEFAULT_AVATAR_PICTURE="$T/lucciola.png" \
    DEFAULT_AVATAR_PASSWD="$T/passwd" bash "$HELPER" 2>&1)" || RC=$?
}
check() {
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; echo "$OUT" | sed 's/^/     /'; fails=$((fails+1)); fi
}
has_icon()   { grep -qx "Icon=$S/icons/$1" "$S/users/$1" && cmp -s "$T/lucciola.png" "$S/icons/$1"; }
same()       { [ "$(cat "$S/users/$1")" = "$2" ]; }
no_file()    { [ ! -e "$S/users/$1" ] && [ ! -e "$S/icons/$1" ]; }
rc_is()      { [ "$RC" = "$1" ]; }
mode_is()    { [ "$(stat -c %a "$1")" = "$2" ]; }

fresh; run
check "runs cleanly"                                         rc_is 0
check "alice (no file): the firefly, file created"           has_icon alice
check "alice: a [User] keyfile with the Icon= line only"     same alice "$(printf '[User]\nIcon=%s' "$S/icons/alice")"
check "bob (own picture): keyfile untouched"                 same bob "$(printf '[User]\nSession=lucciola\nIcon=/var/lib/AccountsService/icons/bob')"
check "bob: his picture untouched"                           grep -qx bob "$S/icons/bob"
check "carol (picture removed, empty Icon=): untouched"      same carol "$(printf '[User]\nIcon=\nSession=lucciola')"
check "carol: no icon copied"                                test ! -e "$S/icons/carol"
check "dave (no Icon= line): the firefly"                    has_icon dave
check "dave: his other keys kept"                            grep -qx 'SystemAccount=false' "$S/users/dave"
check "dave: Icon= inside [User]"                            same dave "$(printf '[User]\nIcon=%s\nSession=lucciola\nSystemAccount=false' "$S/icons/dave")"
check "erin (no file): the firefly"                          has_icon erin
check "root, greetd, nologin and nobody: left alone"         bash -c 'for u in root greetd svc nobody; do [ ! -e "$1/users/$u" ] || exit 1; done' _ "$S"
check "keyfiles are private (0600)"                          mode_is "$S/users/alice" 600
check "pictures are readable by the login screen (0644)"     mode_is "$S/icons/alice" 644
check "users/ stays private (0700)"                          mode_is "$S/users" 700
check "no temp files left"                                   bash -c '! ls -A "$1/users" | grep -q "^\."' _ "$S"

before="$(cat "$S/users/alice" "$S/users/dave")"
run
check "a second run changes nothing"                         [ "$before" = "$(cat "$S/users/alice" "$S/users/dave")" ]
check "a second run: alice keeps exactly one Icon= line"     [ "$(grep -c '^Icon=' "$S/users/alice")" = 1 ]

# A picture chosen later wins: the helper never touches an Icon= line.
printf 'mine' > "$S/icons/alice.chosen"
printf '[User]\nIcon=%s\n' "$S/icons/alice.chosen" > "$S/users/alice"
run
check "alice's own picture, chosen later, is kept"           grep -qx "Icon=$S/icons/alice.chosen" "$S/users/alice"

# A first boot: AccountsService has not created its directory yet.
rm -rf "$S"; run
check "first boot: directories created"                      bash -c '[ -d "$1/users" ] && [ -d "$1/icons" ]' _ "$S"
check "first boot: alice gets the firefly"                   has_icon alice
check "first boot: users/ private (0700), icons/ 0775"       bash -c '[ "$(stat -c %a "$1/users")" = 700 ] && [ "$(stat -c %a "$1/icons")" = 775 ]' _ "$S"

# No picture in the image: fail, and write nothing.
fresh; rm "$T/lucciola.png"; run
check "no picture: fails"                                    rc_is 1
check "no picture: nothing written for alice"                no_file alice

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all default-avatar tests passed"
