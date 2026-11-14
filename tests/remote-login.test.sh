#!/usr/bin/env bash
# /usr/libexec/lucciola/remote-login on fakes that keep state: firewall-cmd
# (services and SSH rich rules per zone, permanent and running), nmcli (two
# WireGuard profiles, one routing everything, and a Wi-Fi), systemctl (sshd)
# and ip. Covered: status as JSON from off; "on" adopts SSH rules added by
# hand as devices, starts sshd, allows SSH in lucciola-tunnel, closes the old
# open-to-everyone service, moves only the private tunnel into the zone (and
# its interface right away); allow and forget, with their refusals; "off"
# closes everything and gives the tunnel back, keeping the device list; the
# old switch's state reads "everyone". Needs python3.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RL="$ROOT/lucciola/system_files/usr/libexec/lucciola/remote-login"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { local n="$1"; shift; if "$@"; then echo "ok   $n"; else echo "FAIL $n"; sed 's/^/     /' "$T/out" 2>/dev/null | tail -n 12; fails=$((fails+1)); fi; }
mkdir -p "$T/bin" "$T/state"
export FAKE="$T/state"

cat > "$T/bin/firewall-cmd" <<'PY'
#!/usr/bin/python3
import json, os, sys
path = os.path.join(os.environ["FAKE"], "fw.json")
st = json.load(open(path)) if os.path.exists(path) else {}
args = sys.argv[1:]
layer = "permanent" if "--permanent" in args else "runtime"
args = [a for a in args if a != "--permanent"]
zone = "FedoraWorkstation"
for a in args:
    if a.startswith("--zone="):
        zone = a.split("=", 1)[1]
z = st.setdefault(layer, {}).setdefault(zone, {"services": [], "rules": [], "interfaces": []})
out, rc = "", 0
for a in args:
    if a.startswith("--add-service="):
        s = a.split("=", 1)[1]; z["services"] += [s] if s not in z["services"] else []
    elif a.startswith("--remove-service="):
        s = a.split("=", 1)[1]; z["services"] = [x for x in z["services"] if x != s]
    elif a.startswith("--add-rich-rule="):
        r = a.split("=", 1)[1]; z["rules"] += [r] if r not in z["rules"] else []
    elif a.startswith("--remove-rich-rule="):
        r = a.split("=", 1)[1]; z["rules"] = [x for x in z["rules"] if x != r]
    elif a.startswith("--change-interface="):
        z["interfaces"].append(a.split("=", 1)[1])
    elif a.startswith("--remove-interface="):
        i = a.split("=", 1)[1]; z["interfaces"] = [x for x in z["interfaces"] if x != i]
    elif a.startswith("--query-service="):
        yes = a.split("=", 1)[1] in z["services"]; out, rc = ("yes" if yes else "no"), (0 if yes else 1)
    elif a == "--list-rich-rules":
        out = "\n".join(z["rules"])
json.dump(st, open(path, "w"))
open(os.path.join(os.environ["FAKE"], "fw.log"), "a").write(" ".join(sys.argv[1:]) + "\n")
if out:
    print(out)
sys.exit(rc)
PY

cat > "$T/bin/nmcli" <<'PY'
#!/usr/bin/python3
import json, os, sys
path = os.path.join(os.environ["FAKE"], "nm.json")
st = json.load(open(path))
a = sys.argv[1:]
if a[:5] == ["-t", "-f", "UUID,TYPE,NAME,DEVICE", "connection", "show"]:
    for c in st:
        print(":".join([c["uuid"], c["type"], c["name"].replace(":", "\\:"), c["device"]]))
elif a[:1] == ["-g"] and a[2:4] == ["connection", "show"]:
    c = next(c for c in st if c["uuid"] == a[4])
    print(c["peers"] if a[1] == "wireguard.peers" else c["zone"])
elif a[:2] == ["connection", "modify"]:
    c = next(c for c in st if c["uuid"] == a[2]); c["zone"] = a[4]
    json.dump(st, open(path, "w"))
PY

cat > "$T/bin/systemctl" <<'SH'
#!/bin/sh
case "$1 $2" in
  "is-active sshd.service") cat "$FAKE/sshd" 2>/dev/null || echo inactive ;;
  "enable --now") echo active > "$FAKE/sshd" ;;
  "disable --now") echo inactive > "$FAKE/sshd" ;;
esac
SH
printf '#!/bin/sh\nprintf "lo UNKNOWN 127.0.0.1/8\\nwlp1s0 UP 192.168.2.80/24\\nwg-home UNKNOWN 10.66.66.2/32\\npodman0 UP 10.88.0.1/16\\n"\n' > "$T/bin/ip"
chmod +x "$T/bin/"*

cat > "$FAKE/nm.json" <<'J'
[{"uuid": "u-home", "type": "wireguard", "name": "wg-home", "device": "wg-home", "zone": "",
  "peers": "KEY= allowed-ips=192.168.2.0/24;10.66.66.0/24 endpoint=vpn.example:51820"},
 {"uuid": "u-proton", "type": "wireguard", "name": "Proton: IT#1", "device": "", "zone": "",
  "peers": "KEY= allowed-ips=0.0.0.0/0;::/0 endpoint=1.2.3.4:51820"},
 {"uuid": "u-wifi", "type": "802-11-wireless", "name": "Casetta", "device": "wlp1s0", "zone": "", "peers": ""}]
J
# Two rules added by hand on 2026-11-05, in both layers.
python3 - "$FAKE/fw.json" <<'PY'
import json, sys
rules = ['rule family="ipv4" source address="192.168.2.85/32" service name="ssh" accept',
         'rule family="ipv4" source address="10.66.66.7/32" service name="ssh" accept']
z = {"services": ["dhcpv6-client"], "rules": rules, "interfaces": []}
json.dump({"permanent": {"FedoraWorkstation": dict(z)}, "runtime": {"FedoraWorkstation": dict(z)}}, open(sys.argv[1], "w"))
PY

export REMOTE_LOGIN_TEST=1 REMOTE_LOGIN_DEVICES="$T/etc/devices"
run() { RC=0; PATH="$T/bin:/usr/bin:/bin" USER=daniel python3 -I "$RL" "$@" > "$T/out" 2>&1 || RC=$?; }
js() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$T/out" "$1"; }
fw() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$FAKE/fw.json" "$1"; }
nm() { python3 -I -c 'import json,sys; d={c["uuid"]: c for c in json.load(open(sys.argv[1]))}; print(eval(sys.argv[2], {"d": d}))' "$FAKE/nm.json" "$1"; }

run status --json
check "status from off (rc $RC)" [ "$RC" = 0 ]
check "off, sshd stopped" [ "$(js 'd["state"] + str(d["sshd"])')" = "offFalse" ]
check "rules added by hand show as devices before the first change" [ "$(js '[(x["address"], x["name"]) for x in d["devices"]]')" = "[('192.168.2.85', 'Added by hand'), ('10.66.66.7', 'Added by hand')]" ]
check "and status writes nothing" [ ! -e "$T/etc/devices" ]
check "tunnels: the home one is ours, the full-route VPN is not" [ "$(js '[(t["name"], t["own"], t["active"]) for t in d["tunnels"]]')" = "[('wg-home', True, True), ('Proton: IT#1', False, False)]" ]
check "addresses skip loopback and containers" [ "$(js '[a["address"] for a in d["addresses"]]')" = "['192.168.2.80', '10.66.66.2']" ]

run on
check "on (rc $RC)" [ "$RC" = 0 ]
check "the hand-made rules became devices" bash -c "grep -qx '192.168.2.85 Added by hand' '$T/etc/devices' && grep -qx '10.66.66.7 Added by hand' '$T/etc/devices'"
check "sshd started" [ "$(cat "$FAKE/sshd")" = active ]
check "SSH allowed in lucciola-tunnel, both layers" [ "$(fw '"ssh" in d["permanent"]["lucciola-tunnel"]["services"] and "ssh" in d["runtime"]["lucciola-tunnel"]["services"]')" = True ]
check "SSH not open to the whole default zone" [ "$(fw '"ssh" in d["permanent"]["FedoraWorkstation"]["services"] or "ssh" in d["runtime"]["FedoraWorkstation"]["services"]')" = False ]
check "device rules kept, in both layers" [ "$(fw 'len(d["permanent"]["FedoraWorkstation"]["rules"]), len(d["runtime"]["FedoraWorkstation"]["rules"])')" = "(2, 2)" ]
check "the private tunnel moved to the zone, now and for its next connection" [ "$(nm 'd["u-home"]["zone"]')$(fw 'd["runtime"]["lucciola-tunnel"]["interfaces"]')" = "lucciola-tunnel['wg-home']" ]
check "the full-route VPN and the Wi-Fi untouched" [ "$(nm 'd["u-proton"]["zone"] + d["u-wifi"]["zone"]')" = "" ]
run status --json
check "status: on, tunnel covered, devices live" [ "$(js 'd["state"] + str(d["tunnels"][0]["covered"]) + str(all(x["live"] for x in d["devices"]))')" = "onTrueTrue" ]
run status
check "plain status names who and how" bash -c "grep -q 'ON: your tunnels' '$T/out' && grep -q 'Tunnels: wg-home$' '$T/out' && grep -q 'ssh daniel@10.66.66.2' '$T/out'"

run allow 192.168.2.40 "Windows PC (home)"
check "allow a device (rc $RC)" [ "$RC" = 0 ]
check "it is listed and allowed at once" bash -c "grep -qx '192.168.2.40 Windows PC (home)' '$T/etc/devices' && [ \"\$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(any(\"192.168.2.40\" in r for r in d[\"runtime\"][\"FedoraWorkstation\"][\"rules\"]))' '$FAKE/fw.json')\" = True ]"
run allow 192.168.2.40/32 "Windows PC"
check "the same address again replaces its name" [ "$(grep -c '^192.168.2.40 ' "$T/etc/devices")$(grep -c 'Windows PC$' "$T/etc/devices")" = "11" ]
run allow 0.0.0.0/0 "Everyone"
check "the whole internet is refused (rc $RC)" bash -c "[ '$RC' != 0 ] && ! grep -q '0.0.0.0' '$T/etc/devices'"
run allow 10.0.0.0/8 "Too wide"
check "a network wider than /16 is refused (rc $RC)" [ "$RC" != 0 ]
run allow 192.168.3.0/24 "Lab"
check "a /24 network is accepted (rc $RC)" bash -c "[ '$RC' = 0 ] && grep -qx '192.168.3.0/24 Lab' '$T/etc/devices'"
run allow fd00::5 "Phone; rm -rf /"
check "a name with shell characters is refused (rc $RC)" [ "$RC" != 0 ]
run allow "not an ip" Name
check "a non-address is refused (rc $RC)" [ "$RC" != 0 ]
run forget 10.66.66.7
check "forget a device (rc $RC)" bash -c "[ '$RC' = 0 ] && ! grep -q '^10.66.66.7 ' '$T/etc/devices' && ! grep -q '10.66.66.7' '$FAKE/fw.json'"
run forget 10.9.9.9
check "forgetting an unknown address says so (rc $RC)" bash -c "[ '$RC' != 0 ] && grep -q 'not in the list' '$T/out'"

run off
check "off (rc $RC)" [ "$RC" = 0 ]
check "sshd stopped" [ "$(cat "$FAKE/sshd")" = inactive ]
check "nothing lets SSH in any more" [ "$(fw '"ssh" in d["permanent"]["lucciola-tunnel"]["services"] or "ssh" in d["runtime"]["lucciola-tunnel"]["services"] or bool(d["permanent"]["FedoraWorkstation"]["rules"] + d["runtime"]["FedoraWorkstation"]["rules"])')" = False ]
check "the tunnel went back to the default zone" [ "$(nm 'd["u-home"]["zone"]')$(fw 'd["runtime"]["lucciola-tunnel"]["interfaces"]')" = "[]" ]
check "the device list survives off" [ "$(grep -c -v '^#' "$T/etc/devices")" = 3 ]
run on
check "on again restores the devices from the list" [ "$(fw 'len(d["runtime"]["FedoraWorkstation"]["rules"])')" = 3 ]

# The old switch: sshd on and SSH in the default zone, open to every network.
PATH="$T/bin:/usr/bin:/bin" firewall-cmd --add-service=ssh >/dev/null
run status --json
check "the old way reads 'everyone'" [ "$(js 'd["state"]')" = everyone ]
run on
check "on closes the open-to-everyone service" [ "$(fw '"ssh" in d["runtime"]["FedoraWorkstation"]["services"]')" = False ]

run bogus; check "an unknown verb is refused (rc $RC)" [ "$RC" = 2 ]

# The bar icon is the control: it stays when remote login is off (dim), or
# there is nothing left to turn it back on with (2026-11-14: it hid itself,
# and a right click that turned it off could not be undone from the bar).
PLUG="$ROOT/lucciola/system_files/usr/share/lucciola/noctalia/plugins/remote_login"
check "the bar icon never hides itself" bash -c "grep -q 'barWidget.setVisible(true)' '$PLUG/indicator.luau' && ! grep -q 'setVisible(false)' '$PLUG/indicator.luau'"
check "...off has its own glyph and colour" bash -c "grep -q 'setGlyph(common.GLYPH_OFF)' '$PLUG/indicator.luau' && grep -q 'on_surface_variant' '$PLUG/indicator.luau'"
check "...a right click turns it on as well as off" grep -q 'common.send(common.isOn(common.snapshot()) and "off" or "on")' "$PLUG/indicator.luau"
for lang in en it; do
  check "...the tooltip's words exist in $lang" python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if all(d.get(k) for k in ("tooltip.off","tooltip.hint_label","tooltip.hint_on","tooltip.hint_off")) else 1)' "$PLUG/translations/$lang.json"
done

echo; [ "$fails" = 0 ] && echo "remote-login: all checks passed" || { echo "remote-login: $fails failed"; exit 1; }
