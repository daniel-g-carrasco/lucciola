#!/usr/bin/env python3
"""Layer C login driver: the login screen, exercised the way a person uses it.

Runs INSIDE the smoke-boot VM as a root oneshot (margine-greetd-login.service),
injected offline by .github/scripts/inject-gui-probe.sh. Standard library only.
Three phases, each with its own marker on the serial console:

  MARGINE-GREETD: AUTOLOGIN PASS|FAIL|SKIP ...  greetd's [initial_session]
      (what `ujust margine-autologin on` writes) started the smoke user's
      session: niri runs, logind has a wayland session from the greetd PAM
      service, desktop lucciola.
  MARGINE-GREETD: GREETER PASS|FAIL ...  after that session logs out, greetd
      starts the greeter (Noctalia Greeter, as the greetd user, in a logind
      greeter session), as it does after every logout.
  MARGINE-GREETD: LOGIN PASS|FAIL ...  a password login over greetd's IPC
      socket, the protocol the greeter itself speaks (greetd-ipc(7)):
      create_session, the password as the answer to PAM's secret prompt,
      start_session with the session file's command and environment. greetd
      stops the greeter and starts the session through the full greetd PAM
      stack: pam_unix checks the password, pam_oo7 takes it for the keyring,
      pam_selinux, pam_loginuid and pam_systemd set the session up.
  MARGINE-GREETD: SESSION PASS|FAIL ...  that session is a real one: niri
      runs as the user, in a wayland logind session on seat0 opened by the
      greetd service, with the user's audit login uid and an unconfined
      SELinux context (pam_selinux open ran).
  MARGINE-GREETD: SELINUX PASS|WARN ...  AVC denials from greetd and the
      greeter (SELinux runs permissive in this VM, so they are only logged).
  MARGINE-GREETD: DONE

gui-probe.sh and user-smoke-probe.sh are ordered after this unit and check
the password session (and its unlocked Login keyring); gui-probe.sh reads
the result file this script leaves in /run/margine-smoke/. Never powers the
VM off (gui-probe.sh owns that) and always exits 0: the verdicts are the
markers. By hand on a lab VM, without touching its console:
  sudo PROBE_STDOUT=1 SMOKE_USER=<user> SMOKE_PASSWORD_FILE=<file> greetd-login.py
(it logs that user out first when greetd autologged it in).
"""
import glob
import json
import os
import pwd
import shlex
import socket
import struct
import subprocess
import sys
import time

# Standard library since Python 3.11 (ruff, without a target version, sorts
# it as third-party).
import tomllib

USER = os.environ.get("SMOKE_USER", "smoke")
PASSWORD_FILE = os.environ.get("SMOKE_PASSWORD_FILE", "/etc/margine-smoke/smoke-password")
SESSION_FILE = "/usr/share/wayland-sessions/lucciola.desktop"
GREETD_CONF = "/etc/greetd/config.toml"
RESULT_DIR = "/run/margine-smoke"


def out(line):
    """Markers to the serial console and the kernel log (mirrored to
    console=ttyS0), or stdout with PROBE_STDOUT=1: same as the bash probes."""
    if os.environ.get("PROBE_STDOUT") == "1":
        print(line, flush=True)
        return
    for path, text in (("/dev/console", line), ("/dev/kmsg", "<greetd-login> " + line)):
        try:
            with open(path, "w") as f:
                f.write(text + "\n")
        except OSError:
            pass


def mark(step, verdict, detail):
    out(f"MARGINE-GREETD: {step} {verdict} {detail}"[:900])


def sh(*cmd, timeout=30):
    """Run a command, return its stdout stripped ('' on any failure)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout.strip()


def wait_for(test, timeout, step=3):
    end = time.monotonic() + timeout
    while True:
        value = test()
        if value or time.monotonic() > end:
            return value
        time.sleep(step)


def uid_of(user):
    try:
        return pwd.getpwnam(user).pw_uid
    except KeyError:
        return None


def user_pids(user, comm):
    """PIDs of processes of `user` whose command name is exactly `comm`."""
    pids = sh("pgrep", "-u", user, "-x", comm)
    return [int(p) for p in pids.split()] if pids else []


def sessions_of(user):
    """logind sessions of the user, each as a dict of the properties we use."""
    result = []
    for sid in sh("loginctl", "show-user", user, "-p", "Sessions", "--value").split():
        props = {"Id": sid}
        for line in sh("loginctl", "show-session", sid, "-p", "Service", "-p", "Type", "-p", "Class",
                       "-p", "Seat", "-p", "Desktop", "-p", "Remote", "-p", "State", "-p", "Leader").splitlines():
            key, _, value = line.partition("=")
            props[key] = value
        result.append(props)
    return result


def describe(sessions):
    return " ".join(f"[{s.get('Id')} service={s.get('Service') or '?'} class={s.get('Class') or '?'} "
                    f"type={s.get('Type') or '?'} seat={s.get('Seat') or '-'} desktop={s.get('Desktop') or '-'} "
                    f"state={s.get('State') or '?'}]" for s in sessions) or "none"


def graphical_greetd_session(user):
    for s in sessions_of(user):
        if s.get("Service") == "greetd" and s.get("Class") == "user" and s.get("State") in ("active", "online"):
            return s
    return None


def user_env(user, uid, name):
    """A variable of the user manager's environment (niri-session imports the
    session's XDG_* there), '' when the manager does not answer."""
    env = sh("runuser", "-u", user, "--", "env", f"XDG_RUNTIME_DIR=/run/user/{uid}",
             f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus",
             "systemctl", "--user", "show-environment")
    for line in env.splitlines():
        if line.startswith(name + "="):
            return line.split("=", 1)[1]
    return ""


def session_command():
    """What Noctalia Greeter sends greetd for the Lucciola session: the
    session file's Exec split into words, and its DesktopNames, from which it
    derives XDG_CURRENT_DESKTOP (all of them, ':'-joined) and
    XDG_SESSION_DESKTOP (the first)."""
    exec_line, names = "niri-session", ["niri"]
    try:
        with open(SESSION_FILE) as f:
            for line in f:
                if line.startswith("Exec="):
                    exec_line = line.split("=", 1)[1].strip()
                elif line.startswith("DesktopNames="):
                    names = [n for n in line.split("=", 1)[1].strip().split(";") if n] or names
    except OSError:
        pass
    return shlex.split(exec_line), names


class Greetd:
    """greetd-ipc(7): a 32-bit native-endian length, then a JSON payload."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(60)
        self.sock.connect(path)

    def request(self, payload):
        data = json.dumps(payload).encode()
        self.sock.sendall(struct.pack("=I", len(data)) + data)
        size = struct.unpack("=I", self._read(4))[0]
        return json.loads(self._read(size))

    def _read(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("greetd closed the connection")
            buf += chunk
        return buf


def greetd_socket():
    pid = sh("systemctl", "show", "-p", "MainPID", "--value", "greetd.service")
    path = f"/run/greetd-{pid}.sock"
    if pid not in ("", "0") and os.path.exists(path):
        return path
    socks = sorted(glob.glob("/run/greetd-*.sock"), key=os.path.getmtime)
    return socks[-1] if socks else ""


def password_login(password):
    """One login over the IPC socket. Returns (ok, detail)."""
    path = greetd_socket()
    if not path:
        return False, "no greetd socket in /run"
    try:
        g = Greetd(path)
        reply = g.request({"type": "create_session", "username": USER})
        prompts = []
        for _ in range(10):
            kind = reply.get("type")
            if kind == "success":
                break
            if kind == "error":
                g.request({"type": "cancel_session"})
                return False, f"{reply.get('error_type')}: {reply.get('description')} (prompts: {prompts})"
            if kind != "auth_message":
                return False, f"unexpected reply {reply}"
            mtype, text = reply.get("auth_message_type"), reply.get("auth_message", "").strip()
            prompts.append(f"{mtype}:{text}")
            # A greeter answers the questions and acknowledges the messages.
            answer = password if mtype in ("secret", "visible") else None
            reply = g.request({"type": "post_auth_message_response", "response": answer})
        else:
            return False, f"PAM kept asking: {prompts}"
        cmd, names = session_command()
        env = ["XDG_SESSION_TYPE=wayland", f"XDG_SESSION_DESKTOP={names[0]}", f"XDG_CURRENT_DESKTOP={':'.join(names)}"]
        reply = g.request({"type": "start_session", "cmd": cmd, "env": env})
        if reply.get("type") != "success":
            return False, f"start_session refused: {reply}"
        return True, f"prompts {prompts}, start_session {cmd}"
    except (OSError, ValueError, ConnectionError) as e:
        return False, f"{type(e).__name__}: {e} (socket {path})"


def write_result(**fields):
    os.makedirs(RESULT_DIR, exist_ok=True)
    with open(os.path.join(RESULT_DIR, "greetd-login.result"), "w") as f:
        for key, value in fields.items():
            f.write(f"{key}={value}\n")


def avc_report():
    """Denials involving greetd, its greeter or the xdm_t domain they run in."""
    log = sh("journalctl", "-b", "-k", "--no-pager", "-o", "cat", timeout=60)
    hits = {}
    for line in log.splitlines():
        if "avc:  denied" not in line:
            continue
        if not any(k in line for k in ("xdm_t", "greetd", "noctalia-greet", "xdm_var_lib_t")):
            continue
        if "margine-smoke" in line or "unlabeled_t" in line:
            continue  # the injected test files carry no labels
        key = line.split("avc:  denied", 1)[1].split(" pid=")[0].strip()
        comm = line.split('comm="', 1)[1].split('"', 1)[0] if 'comm="' in line else "?"
        hits[f"{comm}: {key}"] = hits.get(f"{comm}: {key}", 0) + 1
    if not hits:
        return "PASS", "no denials from greetd, the greeter or xdm_t"
    top = sorted(hits.items(), key=lambda kv: -kv[1])[:3]
    return "WARN", f"{len(hits)} distinct (would be blocked when enforcing): " + " | ".join(f"{n}x {k}" for k, n in top)


def main():
    uid = uid_of(USER)
    if uid is None:
        mark("LOGIN", "FAIL", f"user {USER} does not exist")
        write_result(login="fail", reason=f"no user {USER}")
        out("MARGINE-GREETD: DONE")
        return 0

    # greetd must be the display manager and running; GDM active means
    # greetd failed repeatedly and its OnFailure= fallback took over.
    dm = os.path.realpath("/etc/systemd/system/display-manager.service")
    active = wait_for(lambda: sh("systemctl", "is-active", "greetd.service") == "active", 180)
    if not active:
        gdm = sh("systemctl", "is-active", "gdm.service")
        why = (f"greetd.service is {sh('systemctl', 'is-active', 'greetd.service') or '?'}, "
               f"display-manager -> {dm}, gdm {gdm or '?'}"
               + (" (GDM fallback took over: greetd failed)" if gdm == "active" else "")
               + "; greetd log: " + sh("journalctl", "-b", "-u", "greetd.service", "-o", "cat", "-n", "4",
                                       "--no-pager").replace("\n", " | "))
        for step in ("AUTOLOGIN", "GREETER", "LOGIN"):
            mark(step, "FAIL", why)
        write_result(login="fail", reason=why)
        out("MARGINE-GREETD: DONE")
        return 0

    # ---- 1. Autologin ([initial_session]) -----------------------------------
    try:
        with open(GREETD_CONF, "rb") as f:
            initial = tomllib.load(f).get("initial_session", {})
    except (OSError, tomllib.TOMLDecodeError) as e:
        initial = {}
        mark("AUTOLOGIN", "FAIL", f"{GREETD_CONF} unreadable: {e}")
    if initial.get("user") == USER:
        # First boot is slow (Flatpak preinstall competes for I/O).
        up = wait_for(lambda: user_pids(USER, "niri") and graphical_greetd_session(USER), 300, 5)
        sess = sessions_of(USER)
        desk = user_env(USER, uid, "XDG_SESSION_DESKTOP")
        s = graphical_greetd_session(USER) or {}
        # The launcher names the session as the greeter does (niri); GDM
        # used the file name (lucciola).
        if up and s.get("Type") == "wayland" and desk in ("niri", "lucciola"):
            mark("AUTOLOGIN", "PASS", f"niri up, desktop={desk}, {describe(sess)}")
        elif up:
            mark("AUTOLOGIN", "FAIL", f"niri up but type={s.get('Type') or '?'} desktop={desk or '?'}: {describe(sess)}")
        else:
            mark("AUTOLOGIN", "FAIL", f"no niri for {USER} within 300 s; sessions: {describe(sess)}; greetd log: "
                 + sh("journalctl", "-b", "-u", "greetd.service", "-o", "cat", "-n", "4", "--no-pager").replace("\n", " | "))
    else:
        mark("AUTOLOGIN", "SKIP", f"no [initial_session] for {USER} in {GREETD_CONF}")

    # ---- 2. Log out, the greeter comes back ---------------------------------
    if sessions_of(USER):
        sh("loginctl", "terminate-user", USER)
        gone = wait_for(lambda: not sessions_of(USER)
                        and sh("systemctl", "is-active", f"user@{uid}.service") != "active", 90)
        if not gone:
            mark("GREETER", "FAIL", f"{USER} still logged in 90 s after terminate-user: {describe(sessions_of(USER))}")
    greeter_user = "greetd"
    try:
        with open(GREETD_CONF, "rb") as f:
            greeter_user = tomllib.load(f).get("default_session", {}).get("user", "greetd")
    except (OSError, tomllib.TOMLDecodeError):
        pass

    def greeter_up():
        procs = sh("pgrep", "-a", "-u", greeter_user)
        return [s for s in sessions_of(greeter_user) if s.get("Class") == "greeter"] and "noctalia-greet" in procs

    if wait_for(greeter_up, 120):
        procs = " ".join(sorted({p.split(" ", 2)[1].rsplit("/", 1)[-1]
                                 for p in sh("pgrep", "-a", "-u", greeter_user).splitlines() if " " in p}))
        mark("GREETER", "PASS", f"{describe(sessions_of(greeter_user))} processes of {greeter_user}: {procs}")
    else:
        mark("GREETER", "FAIL", f"no Noctalia Greeter in a greeter session within 120 s; {greeter_user} sessions: "
             f"{describe(sessions_of(greeter_user))}; processes: "
             + sh("pgrep", "-a", "-u", greeter_user).replace("\n", " | ")[:300]
             + "; greetd log: " + sh("journalctl", "-b", "-u", "greetd.service", "-o", "cat", "-n", "6",
                                     "--no-pager").replace("\n", " | "))

    # ---- 3. Password login over the IPC socket -----------------------------
    try:
        with open(PASSWORD_FILE) as f:
            password = f.read().strip()
    except OSError as e:
        mark("LOGIN", "FAIL", f"no password for {USER}: {e}")
        write_result(login="fail", reason="no password file")
        out("MARGINE-GREETD: DONE")
        return 0
    since = int(time.time())
    ok, detail = password_login(password)
    if not ok:
        # Once more, after the greeter had time to settle: greetd accepts
        # create_session only while a greeter (or session) is running.
        time.sleep(10)
        since = int(time.time())
        ok, detail = password_login(password)
    mark("LOGIN", "PASS" if ok else "FAIL", detail)
    if not ok:
        write_result(login="fail", reason=detail)
        status, avc = avc_report()
        mark("SELINUX", status, avc)
        out("MARGINE-GREETD: DONE")
        return 0

    # ---- 4. The session it started ------------------------------------------
    # greetd gives the greeter 5 s to exit, then terminates it, then starts
    # the session (greetd context.rs, alarm()).
    up = wait_for(lambda: user_pids(USER, "niri") and graphical_greetd_session(USER), 180, 3)
    s = graphical_greetd_session(USER) or {}
    problems = []
    if not up:
        problems.append(f"no niri in a greetd session within 180 s ({describe(sessions_of(USER))})")
    else:
        if s.get("Type") != "wayland":
            problems.append(f"type={s.get('Type')}")
        if s.get("Seat") != "seat0":
            problems.append(f"seat={s.get('Seat') or 'none'}")
        if s.get("Remote") != "no":
            problems.append(f"remote={s.get('Remote')}")
        pid = user_pids(USER, "niri")[0]
        try:
            loginuid = open(f"/proc/{pid}/loginuid").read().strip()
            context = open(f"/proc/{pid}/attr/current").read().strip("\0\n ")
        except OSError as e:
            loginuid, context = "?", f"? ({e})"
        if loginuid != str(uid):
            problems.append(f"niri loginuid={loginuid}, not {uid} (pam_loginuid)")
        if ":unconfined_t:" not in context:
            problems.append(f"niri runs as {context}, not unconfined_t (pam_selinux open)")
    detail = f"{describe([s] if s else sessions_of(USER))}"
    mark("SESSION", "FAIL" if problems else "PASS", ("; ".join(problems) + " | " if problems else "") + detail)
    write_result(login="pass" if not problems else "fail", since=since, session=s.get("Id", ""),
                 reason="; ".join(problems) or "ok")
    status, avc = avc_report()
    mark("SELINUX", status, avc)
    out("MARGINE-GREETD: DONE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
