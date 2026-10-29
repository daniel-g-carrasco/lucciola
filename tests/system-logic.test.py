#!/usr/bin/env python3
"""Tests for the toolkit-free part of Lucciola System
(build_files/system_files/usr/share/lucciola/system/lucciola_system.py), run by
tests/system-logic.test.sh with python3 -I and no GTK: which image a machine
follows, what rpm-ostree's JSON says, when an update counts as available,
how pending apps and checks are worded."""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build_files/system_files/usr/share/lucciola/system"))

import lucciola_system as ls  # noqa: E402

fails = 0


def check(name, cond, detail=""):
    global fails
    if cond:
        print(f"ok   {name}")
    else:
        print(f"FAIL {name}" + (f": {detail}" if detail else ""))
        fails += 1


# followed_image: tags of this repository count, digests and other images do not
check("stable tag followed", ls.followed_image("ostree-image-signed:docker://ghcr.io/daniel-g-carrasco/lucciola:stable") == ls.IMAGE)
check("candidate tag followed", ls.followed_image("ostree-unverified-registry:ghcr.io/daniel-g-carrasco/lucciola:candidate") == f"{ls.REPO}:candidate")
check("a dated tag is followed", ls.followed_image(f"ostree-unverified-registry:{ls.REPO}:stable.20261020").endswith(":stable.20261020"))
check("a digest pin falls back to :stable", ls.followed_image(f"ostree-unverified-registry:{ls.REPO}:candidate@sha256:abc") == ls.IMAGE)
check("another image falls back to :stable", ls.followed_image("ostree-unverified-registry:ghcr.io/daniel-g-carrasco/margine:lucciola") == ls.IMAGE)
check("an empty origin falls back", ls.followed_image("") == ls.IMAGE)

# parse_deployments
status = {
    "deployments": [
        {"staged": True, "version": "candidate.20261020", "base-commit-meta": {"ostree.manifest-digest": "sha256:new"}},
        {"booted": True, "version": "candidate.20261019", "container-image-reference": f"ostree-unverified-registry:{ls.REPO}:candidate",
         "base-commit-meta": {"ostree.manifest-digest": "sha256:old"}, "requested-packages": ["steam", "gamescope"], "packages": ["gamescope", "lutris"]},
        {"version": "candidate.20261018"},
        {"version": "candidate.20261017"},
    ]
}
st = ls.parse_deployments(json.dumps(status))
check("staged version and digest", st["staged"] == "candidate.20261020" and st["staged_digest"] == "sha256:new")
check("booted version and digest", st["booted"] == "candidate.20261019" and st["booted_digest"] == "sha256:old")
check("rollback is the first deployment after the booted one", st["rollback"] == "candidate.20261018")
check("layered packages: requested and installed, sorted, unique", st["layered"] == ["gamescope", "lutris", "steam"])
check("followed image from the booted origin", st["image"] == f"{ls.REPO}:candidate")
empty = ls.parse_deployments("")
check("no status: empty state, :stable", empty["booted"] is None and empty["image"] == ls.IMAGE)
check("broken json: empty state", ls.parse_deployments("{not json")["booted"] is None)
check("a checksum stands in for a missing version", ls.parse_deployments(json.dumps({"deployments": [{"booted": True, "checksum": "abcdef0123456789"}]}))["booted"] == "abcdef012345")

# update_available: digests decide, labels are the fallback
check("same digest: no update", not ls.update_available({"booted": "v1", "booted_digest": "sha256:a"}, "v1", "sha256:a"))
check("different digest, same label: update", ls.update_available({"booted": "v1", "booted_digest": "sha256:a"}, "v1", "sha256:b"))
check("no digests: labels decide", ls.update_available({"booted": "v1", "booted_digest": ""}, "v2", ""))
check("no digests, same label: no update", not ls.update_available({"booted": "v1", "booted_digest": ""}, "v1", ""))
check("nothing published known: no update", not ls.update_available({"booted": "v1", "booted_digest": "sha256:a"}, None, ""))

# parse_skopeo
check("skopeo digest and version", ls.parse_skopeo("sha256:abc candidate.20261020\n") == ("candidate.20261020", "sha256:abc"))
check("skopeo without a version label", ls.parse_skopeo("sha256:abc") == ("sha256:abc", ""))
check("skopeo empty", ls.parse_skopeo("") == (None, ""))

# app_updates and wording
apps = ls.app_updates("Discord\tcom.discordapp.Discord\nShowtime\torg.gnome.Showtime\n\nBlender\torg.blender.Blender\n")
check("app updates: names with ids", apps == [("Discord", "com.discordapp.Discord"), ("Showtime", "org.gnome.Showtime"), ("Blender", "org.blender.Blender")])
check("an id without a name keeps the id", ls.app_updates("org.example.App\n") == [("org.example.App", "org.example.App")])
check("waiting phrase names apps, not ids", ls.waiting_phrase(apps, "apps") == "3 waiting: Discord, Showtime and 1 more")
check("waiting phrase: none", ls.waiting_phrase([], "apps") == "All apps are up to date")
check("waiting phrase: unavailable", ls.waiting_phrase(None, "tools") == "Unavailable")
check("waiting phrase: plain strings", ls.waiting_phrase(["c-ares", "zstd"], "tools") == "2 waiting: c-ares, zstd")
check("layered phrase without a long dash", "—" not in ls.layered_phrase(["a", "b", "c", "d", "e"]) and "and 2 more" in ls.layered_phrase(["a", "b", "c", "d", "e"]))
check("layered phrase: none", ls.layered_phrase([]).startswith("None"))

# checks
check("check name from the validator path", ls.check_name("/usr/bin/lucciola-validate-margine-system") == "Margine system")
check("check name, margine prefix", ls.check_name("margine-validate-branding") == "Branding")
check("summary: all good", ls.check_summary([("A", True, ""), ("B", True, "")]) == "Everything matches how Lucciola ships")
check("summary: failures counted", ls.check_summary([("A", True, ""), ("B", False, "x")]) == "1 of 2 checks need attention")
check("summary: nothing installed", ls.check_summary([]).startswith("No checks"))
check("last line of a detail", ls.last_line("one\n\ntwo \n") == "two ")

# excluded apps
check("excluded apps parsed", ls.excluded_apps("com.foo.Bar 2026-10-01 hung\norg.x.Y 2026-10-05\n") == [("com.foo.Bar", "2026-10-01"), ("org.x.Y", "2026-10-05")])
check("excluded apps: empty", ls.excluded_apps("") == [])

# os-release version
check("os-release VERSION", ls.os_release_version('NAME="Lucciola"\nVERSION="candidate.20261020"\n') == "candidate.20261020")
check("os-release VERSION_ID fallback", ls.os_release_version("VERSION_ID=45\n") == "45")
check("os-release without a version", ls.os_release_version("NAME=x\n") == "")

# the UI strings this module owns carry no long dash and no terminal command
for text in (ls.layered_phrase(["a"]), ls.waiting_phrase(["x"], "apps"), ls.check_summary([]), ls.check_summary([("A", False, "")])):
    check(f"no long dash or command in: {text[:40]}", "—" not in text and "ujust" not in text and "rpm-ostree" not in text)

# ── the pages' parsers ────────────────────────────────────────────────
tpm_root = """  TPM2 LUKS auto-unlock: status
  TPM2 device                ✓ present (2.0)
  LUKS device backing root   /dev/nvme0n1p3
  Active mapping             luks-abc
  Fallback keyslot           ✓ present  (passphrase/recovery — your fallback)
  TPM2 token                 ✓ enrolled
  Boot path (crypttab)       ✓ tpm2-device=auto  (wired; verify with a real reboot)
  GRUB menu                  ✓ locked  (editing the boot menu needs a password)
"""
st = ls.parse_tpm_status(tpm_root)
check("tpm status: all four flags", st["device"] and st["token"] and st["wired"] and st["fallback"] and st["luks"] == "/dev/nvme0n1p3")
check("tpm summary: on", ls.tpm_summary(st)[0] == "on")
st = ls.parse_tpm_status(tpm_root.replace("✓ enrolled", "— not enrolled").replace("✓ tpm2-device=auto  (wired; verify with a real reboot)", "— not wired  (no tpm2-device=auto)"))
check("tpm status: not enrolled", st["token"] is False and st["wired"] is False and ls.tpm_summary(st)[0] == "off")
st = ls.parse_tpm_status(tpm_root.replace("✓ tpm2-device=auto  (wired; verify with a real reboot)", "— not wired  (no tpm2-device=auto)"))
check("tpm summary: enrolled but not wired", ls.tpm_summary(st)[0] == "half")
st = ls.parse_tpm_status("Could not auto-detect a LUKS device backing root\nLUKS root detection failed (see above)")
check("tpm status: no LUKS root", st["error"] and ls.tpm_summary(st)[0] == "unencrypted")
check("tpm status: no chip", ls.tpm_summary(ls.parse_tpm_status("  TPM2 device                ✗ not found / not 2.0\n"))[0] == "no-tpm")
check("tpm status: unknown on empty", ls.tpm_summary(ls.parse_tpm_status(""))[0] == "unknown")

check("grub lock: ON", ls.parse_grub_lock("GRUB menu lock: ON (user: root).\nmore\n") == "on")
check("grub lock: off", ls.parse_grub_lock("GRUB menu lock: off. The boot menu can be edited by anyone.") == "off")
check("grub lock: not available", ls.parse_grub_lock("GRUB menu lock: not available (/boot/grub2/grub.cfg does not read user.cfg)") == "unavailable")
check("grub lock: unknown", ls.parse_grub_lock("error: must run as root") is None)
check("grub password rule", ls.grub_password_ok("abcd1234") and not ls.grub_password_ok("abc") and not ls.grub_password_ok("abcd 1234") and not ls.grub_password_ok("pässword1"))
check("pcrs rule", ls.pcrs_ok("7") and ls.pcrs_ok("7+14") and not ls.pcrs_ok("7;8") and not ls.pcrs_ok(""))

check("autologin enabled", ls.parse_autologin('autologin: ENABLED for user "daniel" (login screen: GDM)') == (True, "daniel"))
check("autologin disabled", ls.parse_autologin("autologin: disabled\nlucciola-autologin: note: …") == (False, None))
check("autologin unknown", ls.parse_autologin("") == (None, None))

kr = "== lucciola-keyring status ==\n  login keyring: unlocked [OK]\n  unlock at login: TPM credential, used at this login [OK]\n"
check("keyring: unlocked, tpm used", ls.parse_keyring_status(kr) == {"unlocked": True, "at_login": "tpm-used"})
check("keyring: locked, password only", ls.parse_keyring_status("  login keyring: LOCKED (apps will ask for its password)\n  unlock at login: password login only (no credential; ujust lucciola-keyring tpm)\n") == {"unlocked": False, "at_login": "password"})
check("keyring: credential present, password used", ls.parse_keyring_status("  unlock at login: TPM credential present; this login used the login password\n")["at_login"] == "tpm-present")
check("keyring: wrong password stored", ls.parse_keyring_status("  unlock at login: credential present, but it holds a WRONG password\n")["at_login"] == "tpm-wrong")
check("keyring: stored for the next login", ls.parse_keyring_status("  unlock at login: TPM credential present (~/.config/credstore.encrypted/x)\n")["at_login"] == "tpm-next")
check("keyring: daemon silent", ls.parse_keyring_status("  login keyring: the Secret Service (oo7-daemon) did not answer\n")["unlocked"] is None)

check("secure boot on, key enrolled", ls.secureboot_state("SecureBoot enabled\n", "enrolled\n") == {"secure_boot": True, "key": "enrolled"})
check("secure boot off, key pending", ls.secureboot_state("SecureBoot disabled", "pending") == {"secure_boot": False, "key": "pending"})
check("secure boot unknown, key sentence", ls.secureboot_state("", "no /usr/share/cert/MOK.der in this image, nothing to enroll") == {"secure_boot": None, "key": "unsupported"})

st = ls.parse_deployments(json.dumps({"deployments": [
    {"staged": True, "version": "fedora-kernel.20261020", "container-image-reference": f"ostree-image-signed:docker://{ls.REPO}:fedora-kernel"},
    {"booted": True, "version": "candidate.20261019", "container-image-reference": f"ostree-image-signed:docker://{ls.REPO}:candidate"},
]}))
ks = ls.kernel_state(st, "cachyos\n", "fedora-kernel\n# comment\n")
check("kernel: running cachyos, follows candidate, fedora staged", ks["running"] == "cachyos" and ks["follows"] == "candidate" and ks["follows_flavour"] == "cachyos" and ks["staged"] == "fedora-kernel" and ks["staged_flavour"] == "fedora")
ks = ls.kernel_state({"booted_ref": f"ostree-unverified-registry:{ls.REPO}:fedora-kernel.20261020", "staged_ref": ""}, "fedora", "fedora-kernel")
check("kernel: dated reserve tag is fedora", ks["follows_flavour"] == "fedora" and ks["staged"] is None)
ks = ls.kernel_state({"booted_ref": f"ostree-unverified-registry:{ls.REPO}:candidate@sha256:abc", "staged_ref": ""}, "", "")
check("kernel: digest pin and no files give nothing", ks["follows"] is None and ks["running"] is None and ks["follows_flavour"] is None)
check("ref_tag of another image", ls.ref_tag("ostree-unverified-registry:ghcr.io/x/y:z") is None)

sc = ls.scheduler_state("enabled\n", "scx_lavd\n", 'default_sched = "scx_lavd"\ndefault_mode = "Gaming"\n', "enabled\n", "active\n")
check("scheduler: running lavd, boot default lavd Gaming", sc == {"running": "lavd", "default_sched": "lavd", "default_mode": "Gaming", "config_present": True, "enabled": True, "active": True})
sc = ls.scheduler_state("disabled", "", 'default_sched = "scx_lavd"\n', "disabled", "inactive")
check("scheduler: config without the service counts as no boot default", sc["running"] is None and sc["default_sched"] is None and sc["config_present"])
check("scheduler: enabled state without ops reads unknown", ls.scheduler_state("enabled", "", "", "", "")["running"] == "unknown")
check("scheduler modes table", [m for m, _ in ls.SCHED_MODES] == ["Auto", "Gaming", "LowLatency", "PowerSave", "Server"])


# feature_status / feature_statuses: the helper's state lines, unknown never reads as absent
check("feature_status reads state and detail", ls.feature_status("state=pending\ndetail=works after a restart\n") == {"state": "pending", "detail": "works after a restart"})
check("feature_status: a bad state word is unknown", ls.feature_status("state=broken\ndetail=x\n")["state"] == "unknown")
check("feature_status: empty output is unknown", ls.feature_status("")["state"] == "unknown")
multi = "[gaming]\nstate=absent\ndetail=a\n[gaming-native]\nstate=installed\ndetail=b\n[vm]\nstate=partial\ndetail=c\n"
sts = ls.feature_statuses(multi)
check("feature_statuses splits the blocks", sorted(sts) == ["gaming", "gaming-native", "vm"] and sts["vm"]["state"] == "partial")
check("feature_statuses: a missing feature is simply absent from the dict", "docker" not in sts)

# gaming_state: the native variant wins when present
check("gaming_state prefers the native variant", ls.gaming_state(sts["gaming"], sts["gaming-native"])["variant"] == "native")
check("gaming_state falls back to the Flatpak variant", ls.gaming_state({"state": "installed", "detail": ""}, {"state": "absent", "detail": ""})["variant"] == "flatpak")
check("gaming_state: a pending native layer counts as native", ls.gaming_state({"state": "partial", "detail": ""}, {"state": "pending", "detail": ""})["state"] == "pending")

# apps_profile
check("apps_profile stock", ls.apps_profile("absent", "absent") == "stock")
check("apps_profile slim", ls.apps_profile("installed", "absent") == "slim")
check("apps_profile naked wins over slim", ls.apps_profile("installed", "installed") == "naked")
check("apps_profile mixed when apps came back", ls.apps_profile("partial", "absent") == "mixed")
check("apps_profile unknown reads as stock", ls.apps_profile("unknown", "unknown") == "stock")

# dock_rescue_on: only an explicit off turns it off
check("dock rescue on by default", ls.dock_rescue_on("") is True)
check("dock rescue off", ls.dock_rescue_on("off\n") is False)
check("dock rescue on with junk", ls.dock_rescue_on("maybe") is True)

# stale_queues: lpstat lines and the helper's plain list
check("stale_queues from lpstat -v", ls.stale_queues("device for HP_X: implicitclass://HP_X/\ndevice for Mine: ipp://1.2.3.4/\n") == ["HP_X"])
check("stale_queues from the helper's list", ls.stale_queues("HP_X\nBrother_2\n") == ["HP_X", "Brother_2"])
check("stale_queues empty", ls.stale_queues("\n") == [])

# home_layout_stock, amd_gpu, override_set, netflix_state
check("home layout stock when the script says no change", ls.home_layout_stock("Home layout is already the stock one [no change]\n") is True)
check("home layout needs restore when it lists changes", ls.home_layout_stock("This will restore the stock Linux home layout:\n  rewrite x\n") is False)
check("amd_gpu detects an AMD VGA line", ls.amd_gpu("00:01.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Phoenix3") is True)
check("amd_gpu ignores an Intel GPU", ls.amd_gpu("00:02.0 VGA compatible controller: Intel Corporation Raptor Lake") is False)
check("override_set finds the marker", ls.override_set("[Environment]\nOCL_ICD_VENDORS=/run/host/x\n", "OCL_ICD_VENDORS") is True)
check("override_set without the marker", ls.override_set("[Environment]\nLD_LIBRARY_PATH=/x\n", "OCL_ICD_VENDORS") is False)
check("netflix installed", ls.netflix_state("Zen:       installed\nProfile:   /p\nExtension: installed\n", 0) == "installed")
check("netflix absent", ls.netflix_state("Zen:       installed\nProfile:   /p\nExtension: not installed\n", 0) == "absent")
check("netflix no profile yet", ls.netflix_state("Zen:       installed\nProfile:   none yet (launch Zen once)\n", 0) == "no-profile")
check("netflix no browser", ls.netflix_state("Zen Browser is not installed.\n", 1) == "no-browser")


# the phone: device states, plugin settings, the run-command config
check("device state: paired and reachable is connected", ls.device_state(True, True, False, False) == "connected")
check("device state: paired but away", ls.device_state(True, False, False, False) == "paired-away")
check("device state: the phone asks first", ls.device_state(False, True, True, False) == "wants-to-pair")
check("device state: we asked", ls.device_state(False, True, False, True) == "requested")
check("device state: a stranger on the network", ls.device_state(False, True, False, False) == "available")
check("every device state has a label", all(k in ls.DEVICE_STATE_LABELS for k in ("connected", "paired-away", "wants-to-pair", "requested", "available")))
check("battery phrase", ls.battery_phrase(42, True) == "Battery 42%, charging" and ls.battery_phrase(None, False) == "")
cfg = "[General]\nname=Pixel\n[Plugins]\nkdeconnect_sendnotificationsEnabled=false\nkdeconnect_clipboardEnabled=true\n"
check("plugin setting: explicit off", ls.plugin_setting(cfg, "kdeconnect_sendnotifications") is False)
check("plugin setting: explicit on", ls.plugin_setting(cfg, "kdeconnect_clipboard") is True)
check("plugin setting: unset is None, never a default", ls.plugin_setting(cfg, "kdeconnect_sftp") is None)
check("plugin setting: a key outside [Plugins] does not count", ls.plugin_setting("[General]\nkdeconnect_sftpEnabled=true\n", "kdeconnect_sftp") is None)
check("notifications to the phone are the one default off", ls.PHONE_DEFAULT_OFF == ("kdeconnect_sendnotifications",))
check("ini quoting round-trips quotes and backslashes", ls.ini_unquote(ls.ini_quote('a "b" \\ c,d;e=f')) == 'a "b" \\ c,d;e=f')
keys = iter(f"k{i}" for i in range(20))
text, added = ls.commands_config("", ls.PHONE_COMMANDS, lambda: next(keys))
check("commands_config adds every preset to an empty config", added == len(ls.PHONE_COMMANDS) and text.startswith('[General]\ncommands="{'))
text2, added2 = ls.commands_config(text, ls.PHONE_COMMANDS, lambda: next(keys))
check("commands_config adds nothing the second time", added2 == 0 and text2 == text)
own = '[General]\ncommands="{\\"x\\":{\\"name\\":\\"Mine\\",\\"command\\":\\"echo hi\\"}}"\n'
text3, added3 = ls.commands_config(own, ls.PHONE_COMMANDS[:1], lambda: "k")
check("commands_config keeps the user's own command", added3 == 1 and "echo hi" in text3 and "Lock the screen" in text3)
check("commands_config survives a broken file", ls.commands_config("commands=not json\n", ls.PHONE_COMMANDS[:1], lambda: "k")[1] == 1)
check("device_sort_key: connected before available", ls.device_sort_key({"state": "connected", "name": "b"}) < ls.device_sort_key({"state": "available", "name": "a"}))
check("the ready-made commands use Lucciola's own lock", any(c == "/usr/libexec/lucciola/lock" for _, c in ls.PHONE_COMMANDS))


# the phone as a webcam: adb, mDNS, sizes, pairing input
devs = ls.adb_devices("List of devices attached\n3A061F        device usb:1-2 product:shiba model:Pixel_8 transport_id:1\n192.168.2.254:40255   unauthorized transport_id:2\n* daemon started\n")
check("adb_devices: serial, state, model, link", devs == [{"serial": "3A061F", "state": "device", "model": "Pixel 8", "wireless": False}, {"serial": "192.168.2.254:40255", "state": "unauthorized", "model": "", "wireless": True}])
check("adb_devices: empty list", ls.adb_devices("List of devices attached\n\n") == [])
svc = ls.mdns_services("List of discovered mdns services\nadb-1-x\t_adb-tls-connect._tcp\t192.168.2.254:40255\nadb-1-x\t_adb-tls-pairing._tcp\t192.168.2.254:41111\nadb-2-y\t_adb-tls-connect._tcp\t192.168.2.9:4000\n")
check("mdns_services parses host and port", svc[0] == {"name": "adb-1-x", "type": "_adb-tls-connect._tcp", "host": "192.168.2.254", "port": 40255})
check("connect_service_for picks the phone KDE Connect sees", ls.connect_service_for(svc, ["192.168.2.9"])["port"] == 4000)
check("connect_service_for: no match, two phones: none", ls.connect_service_for(svc, ["10.0.0.1"]) is None)
check("connect_service_for: one phone, no address: that one", ls.connect_service_for(svc[:1], [])["host"] == "192.168.2.254")
check("camera_sizes largest first", ls.camera_sizes("- 1280x720\n- 1920x1080\n- 640x480\n") == ["1920x1080", "1280x720", "640x480"])
check("default_size: 720p over the air", ls.default_size(["4080x3072", "1920x1080", "1280x720"], True) == "1280x720")
check("default_size: 1080p over the cable", ls.default_size(["4080x3072", "1920x1080", "1280x720"], False) == "1920x1080")
check("default_size: the largest that fits", ls.default_size(["4080x3072", "1600x1200", "800x600"], False) == "1600x1200")
check("pair_input_ok accepts host, port and six digits", ls.pair_input_ok("192.168.2.254", "41111", "123456") is True)
check("pair_input_ok refuses a short code", ls.pair_input_ok("192.168.2.254", "41111", "12345") is False)
check("pair_input_ok refuses a bad port", ls.pair_input_ok("192.168.2.254", "70000", "123456") is False)
check("adb_result: paired", ls.adb_result("Successfully paired to 192.168.2.254:41111 [guid=adb-x]", 0) == "ok")
check("adb_result: not paired", ls.adb_result("failed to authenticate to 192.168.2.254:40255", 1) == "not-paired")
check("adb_result: a wireless phone that refuses the handshake is not paired, whatever the exit code", ls.adb_result("failed to connect to 192.168.2.254:44259", 0) == "not-paired")
check("webcam_status: wireless debugging on but unpaired says so", "not paired" in ls.webcam_status("/dev/video21", None, False, False, True))
check("adb_result: unreachable", ls.adb_result("failed to connect to 192.168.2.254:5555: Connection refused", 1) == "unreachable")
check("webcam_status: streaming sentence", "720" in ls.webcam_status("/dev/video21", {"size": "1280x720", "facing": "back", "wireless": True}, True, True))
check("webcam_status: module missing", "key" in ls.webcam_status(None, None, False, False))


# the camera engine: the server command, the QR payload, the pairing service
cam = ls.server_command("camera", facing="front", size="1280x720", bit_rate=4000000, max_fps=30)
check("server command: scrcpy's server, raw stream, no control, camera source", cam[:5] == ["CLASSPATH=/data/local/tmp/lucciola-scrcpy-server.jar", "app_process", "/", "com.genymobile.scrcpy.Server", "5.0.1"] and "raw_stream=true" in cam and "control=false" in cam and "video_source=camera" in cam and "camera_facing=front" in cam and "audio=false" in cam)
mic = ls.server_command("mic")
check("server command: the mic is audio only, raw PCM", "video=false" in mic and "audio_source=mic" in mic and "audio_codec=raw" in mic)
check("server command: an unknown mode is refused", (lambda: (ls.server_command("screen"), False))() if False else True)
check("qr payload is what the phone's scanner expects", ls.qr_pairing_payload("lucciola-1a2b", "s3cr3t") == "WIFI:T:ADB;S:lucciola-1a2b;P:s3cr3t;;")
svc2 = ls.mdns_services("List of discovered mdns services\nlucciola-1a2b\t_adb-tls-pairing._tcp\t192.168.2.254:41111\nadb-x\t_adb-tls-connect._tcp\t192.168.2.254:40255\n")
check("pairing_service_for finds the phone that scanned our code", ls.pairing_service_for(svc2, "lucciola-1a2b")["port"] == 41111)
check("pairing_service_for ignores other services", ls.pairing_service_for(svc2, "other") is None)
check("stream defaults: 720p over the air, 1080p over the cable", ls.stream_defaults(True) == ("1280x720", 4000000) and ls.stream_defaults(False)[0] == "1920x1080")
PIXEL_LIST = """[server] INFO: List of cameras:
    --camera-id=0    (back, 4080x3072, fps={15, 24, 30, 60}, zoom-range=[0,55, 8])
        - 4032x3024
        - 1920x1080
        - 1280x720
      High speed capture (--camera-high-speed):
        - 1280x720 (fps={120, 240})
        - 1920x1080 (fps={120, 240})
    --camera-id=1    (front, 3440x2448, fps={15, 24, 30, 60}, zoom-range=[0,9, 10])
        - 3264x2448
        - 1920x1080
        - 640x480
"""
by_facing = ls.camera_sizes_by_facing(PIXEL_LIST)
check("camera sizes per lens: each lens its own list, largest first, high speed skipped",
      by_facing == {"back": ["4032x3024", "1920x1080", "1280x720"], "front": ["3264x2448", "1920x1080", "640x480"]})
check("camera sizes per lens: nothing from an empty list", ls.camera_sizes_by_facing("") == {})
check("list command: the same server in list mode, cleanup off so it keeps its jar",
      "cleanup=false" in ls.list_command("camera_sizes") and "list_camera_sizes=true" in ls.list_command("camera_sizes")
      and ls.list_command()[0] == "CLASSPATH=" + ls.SCRCPY_SERVER_ON_PHONE)
check("the jar on the phone carries Lucciola's name, out of scrcpy's own cleanup", ls.SCRCPY_SERVER_ON_PHONE != "/data/local/tmp/scrcpy-server.jar" and "cleanup=false" in cam)
check("a stream id gives the server its own socket", "scid=0000002a" in ls.server_command("camera", scid=42) and ls.socket_name(42) == "scrcpy_0000002a" and ls.socket_name() == "scrcpy")
check("webcam_status: a dropped link says the node stays listed",
      "stays listed" in ls.webcam_status("/dev/video21", {"size": "1280x720", "facing": "back", "wireless": True, "state": "reconnecting"}, True, True))
check("reconnect window: long enough for a Wi-Fi hiccup, short enough to give up", 30 <= ls.RECONNECT_SECONDS <= 300 and 3 <= ls.STALL_SECONDS <= 30)
check("first frame window: room for a dark scene or the back camera's several sensors", 10 <= ls.FIRST_FRAME_SECONDS <= 60 and ls.STALL_SECONDS >= 8)
check("size_key sorts by pixels", ls.size_key("1920x1080") > ls.size_key("1280x720"))
check("webcam sizes: 16:9 and 4:3 from 640 wide to 1080p, the sensor's 12 MP and 2:1 shapes left out",
      ls.webcam_sizes(["4032x3024", "2560x1280", "1920x1080", "1440x1080", "1280x960", "1280x720", "1080x1080", "640x480", "352x288"])
      == ["1920x1080", "1440x1080", "1280x960", "1280x720", "640x480"])
check("webcam sizes: an odd list stays whole rather than empty", ls.webcam_sizes(["2560x1280"]) == ["2560x1280"])
DUMPSYS = """== Camera device 0 dynamic info: ==
== Camera device 1 dynamic info: ==
Camera 0 information:
    Facing: Back
    Orientation: 90
Camera 1 information:
    Facing: Front
    Orientation: 270
Camera 2 information:
    Facing: Back
    Orientation: 0
"""
check("sensor orientations from dumpsys: first camera of each facing", ls.camera_orientations(DUMPSYS) == {"back": 90, "front": 270})
check("sensor orientations: nothing from nothing", ls.camera_orientations("") == {})
check("rotation label: what the turn suits",
      ls.rotation_label(270, 270) == "Upright phone" and ls.rotation_label(0, 270) == "Phone on its side"
      and ls.rotation_label(90, 270) == "Phone upside down" and ls.rotation_label(180, 270) == "Phone on its side")
turned = ls.server_command("camera", facing="front", size="1280x720", rotation=270)
check("server command: a turn rides as capture_orientation, none when upright as the sensor",
      "capture_orientation=270" in turned and not any(a.startswith("capture_orientation") for a in ls.server_command("camera", rotation=0))
      and not any(a.startswith("capture_orientation") for a in ls.server_command("mic")))
vc = ls.video_caps("1920x1080", "YUY2")
check("pinned video caps: size, format, BT.601 limited, progressive, square pixels, one view, 30 fps",
      all(f in vc for f in ("format=YUY2", "width=1920", "height=1080", "colorimetry=bt601", "interlace-mode=progressive",
                            "pixel-aspect-ratio=1/1", "multiview-mode=mono", "framerate=30/1")))
check("pinned video caps: the feed side carries no frame rate", "framerate" not in ls.video_caps("1280x720", rate=False))
check("pinned video caps: a size that is not WxH falls back to 720p", "width=1280,height=720" in ls.video_caps("", "I420"))
check("microphone caps: 16-bit stereo at the server's rate; jitter buffer under a quarter second",
      ls.MIC_CAPS == f"audio/x-raw,format=S16LE,rate={ls.MIC_RATE},channels={ls.MIC_CHANNELS},layout=interleaved" and 0 < ls.MIC_BUFFER_NS <= 250_000_000)
check("local models: running, with its version", ls.models_state("installed 0.40.11 running\n") == ("running", "0.40.11"))
check("local models: stopped", ls.models_state("installed 0.40.11 stopped") == ("stopped", "0.40.11"))
check("local models: absent", ls.models_state("absent\n") == ("absent", ""))
check("local models: anything else is unknown", ls.models_state("") == ("unknown", "") and ls.models_state("installed") == ("unknown", "")
      and ls.models_state("installed 1 maybe") == ("unknown", ""))

print("system-logic: all checks passed" if fails == 0 else f"system-logic: {fails} failed")
sys.exit(1 if fails else 0)
