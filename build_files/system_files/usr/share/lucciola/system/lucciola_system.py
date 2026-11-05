"""Lucciola System: the parts of the app that need no toolkit.

The window (/usr/libexec/margine/system-gui) imports this module for every
decision that can be tested without a display: which published image this
machine follows, what rpm-ostree's JSON says about the deployments, how a
list of pending app updates is worded, how a validator's name reads. The
tests (tests/system-logic.test.py) run it with python3 -I and no GTK.
"""

import json
import re

REPO = "ghcr.io/daniel-g-carrasco/lucciola"
IMAGE = f"{REPO}:stable"
REPORT_PATH = "lucciola-report.txt"
ISSUES_URL = "https://github.com/daniel-g-carrasco/lucciola/issues/new/choose"


def followed_image(origin):
    """The published image to compare against: the tag this machine follows
    (:stable, :candidate, a dated tag...), read from the booted origin.
    Comparing every machine with :stable told every install on another tag
    that an update was available, forever. Same rule as lucciola-status:
    only tags of this image's repository count; a digest pin or another
    image keeps the :stable comparison."""
    ref = origin.partition(":")[2].removeprefix("docker://")
    if ref.startswith(REPO + ":") and "@" not in ref:
        return ref
    return IMAGE


def parse_deployments(status_json):
    """Booted / staged / rollback deployments out of `rpm-ostree status
    --json`. The manifest digest is the only identity that survives two
    builds published under the same version label (both stable builds of
    2026-08-30 were candidate.20260830), so it travels with the version."""
    state = {
        "booted": None, "staged": None, "rollback": None, "layered": [],
        "booted_digest": "", "staged_digest": "", "booted_ref": "", "staged_ref": "", "image": IMAGE,
        "transaction": "", "booted_revision": "", "staged_revision": "", "booted_pinned": False,
        "booted_checksum": "", "staged_checksum": "", "booted_built": None, "staged_built": None,
    }
    try:
        status = json.loads(status_json or "{}")
        deployments = status.get("deployments", [])
    except (json.JSONDecodeError, AttributeError):
        return state
    state["transaction"] = transaction_title(status.get("transaction"))
    seen_booted = False
    for dep in deployments:
        version = dep.get("version") or (dep.get("checksum") or "")[:12]
        digest = (dep.get("base-commit-meta") or {}).get("ostree.manifest-digest") or ""
        if dep.get("staged"):
            state["staged"] = version
            state["staged_digest"] = digest
            state["staged_ref"] = dep.get("container-image-reference") or ""
            state["staged_revision"] = image_revision(dep)
            state["staged_checksum"] = dep.get("checksum") or ""
            state["staged_built"] = image_built(dep)
        elif dep.get("booted"):
            state["booted"] = version
            state["booted_digest"] = digest
            state["booted_ref"] = dep.get("container-image-reference") or ""
            state["booted_revision"] = image_revision(dep)
            state["booted_pinned"] = bool(dep.get("pinned"))
            state["booted_checksum"] = dep.get("checksum") or ""
            state["booted_built"] = image_built(dep)
            state["image"] = followed_image(state["booted_ref"])
            seen_booted = True
            state["layered"] = sorted(
                set(dep.get("requested-packages") or []) | set(dep.get("packages") or [])
            )
        elif seen_booted and state["rollback"] is None:
            state["rollback"] = version
    return state


def image_built(dep):
    """When a deployment's image was built (unix time), or None. On a
    machine with extra packages `timestamp` is when they were applied here
    and `base-timestamp` the image's own; without them only `timestamp`
    exists, and it is the image's."""
    for key in ("base-timestamp", "timestamp"):
        value = dep.get(key)
        if isinstance(value, int) and value > 0:
            return value
    return None


def update_available(state, latest, latest_digest):
    """Digests decide, labels are the fallback (#397): comparing labels
    alone made the button a no-op on the second build of a day."""
    booted_digest = state.get("booted_digest") or ""
    if booted_digest and latest_digest:
        return booted_digest != latest_digest
    return bool(latest) and state.get("booted") != latest


def newer_than_staged(state, latest, latest_digest):
    """A deployment is staged, and the registry already publishes a newer
    one: the staged digest is not the published digest (labels when a
    digest is missing). Until 2026-11-01 the window stopped at "staged,
    restart", however old the staged one had become: rpm-ostree replaces a
    staged deployment with the next `upgrade`, so the newer one is a click
    away, not a restart and a second update."""
    if not state.get("staged"):
        return False
    staged_digest = state.get("staged_digest") or ""
    if staged_digest and latest_digest:
        return staged_digest != latest_digest
    return bool(latest) and state.get("staged") != latest


def hero_state(state, latest, latest_digest, error):
    """What the top of the overview says, in one word: checking, working (a
    transaction runs in rpm-ostreed), staged-older (staged, but a newer one
    is published), staged, offline (the registry could not be asked),
    available, current. The window maps the word to texts and buttons; the
    tests check the word."""
    if not state:
        return "checking"
    if state.get("transaction"):
        return "working"
    if state.get("staged"):
        if newer_than_staged(state, latest, latest_digest):
            return "staged-older"
        return "staged"
    if latest is None and not error:
        return "checking"
    if error:
        return "offline"
    if update_available(state, latest, latest_digest):
        return "available"
    return "current"


def transaction_title(value):
    """rpm-ostree's `transaction` field: null when idle, else the running
    transaction's (title, sender, path), serialized as an array; be lenient
    about the shape and return the title, or '' when idle."""
    if not value:
        return ""
    if isinstance(value, (list, tuple)):
        return str(value[0]) if value else ""
    if isinstance(value, dict):
        return str(value.get("title") or value.get("Title") or "transaction")
    return str(value)


def transaction_phrase(title):
    """The running transaction in plain words."""
    t = (title or "").lower()
    if any(w in t for w in ("upgrade", "deploy", "rebase", "update")):
        return "Downloading and preparing the next version"
    if "rollback" in t:
        return "Preparing the previous version for the next restart"
    if any(w in t for w in ("install", "uninstall", "override", "layer")):
        return "Changing the extra packages"
    return "Working on the system"


def parse_skopeo(output):
    """`skopeo inspect --format '{{.Digest}} {{version label}} [{{revision label}}]'`
    -> (version, digest); the revision, when asked for, is the third word
    (skopeo_revision)."""
    words = (output or "").split()
    if not words:
        return None, ""
    if len(words) == 1:
        return words[0], ""
    return words[1], words[0]


def skopeo_revision(output):
    """The third word of the same skopeo output: the git commit the
    published image was built from, or ''."""
    words = (output or "").split()
    return words[2] if len(words) > 2 and GIT_SHA.match(words[2]) else ""


GIT_SHA = re.compile(r"^[0-9a-f]{7,64}$")
COMPARE_URL = f"https://github.com/{REPO.removeprefix('ghcr.io/')}/compare"


def image_revision(deployment):
    """The git commit an image was built from: the OCI revision label,
    carried inside the deployment's image config (a JSON string in
    base-commit-meta)."""
    meta = deployment.get("base-commit-meta") or {}
    raw = meta.get("ostree.container.image-config")
    try:
        config = json.loads(raw) if isinstance(raw, str) else (raw or {})
    except json.JSONDecodeError:
        return ""
    labels = (config.get("config") or {}).get("Labels") or {}
    rev = labels.get("org.opencontainers.image.revision") or ""
    return rev if GIT_SHA.match(rev) else ""


def compare_url(from_rev, to_rev):
    """Every commit between two builds, on GitHub; '' when a side is
    missing or they are the same commit."""
    if not (from_rev and to_rev) or from_rev == to_rev:
        return ""
    if not (GIT_SHA.match(from_rev) and GIT_SHA.match(to_rev)):
        return ""
    return f"{COMPARE_URL}/{from_rev[:12]}...{to_rev[:12]}"


VERSION_LABEL = re.compile(r"^([a-z][a-z0-9-]*)\.(\d{4})(\d{2})(\d{2})(?:\.\d+)?$")
MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December")


def version_phrase(version, image=""):
    """'lucciola.20261105' -> 'built on 5 November 2026';
    'fedora-kernel.20261104' -> 'built on 4 November 2026, fedora-kernel';
    '' when the label is not one of ours. Until 2026-11-04 every image was
    labelled candidate.DATE, those on :stable too, since a promotion copies the
    same image: on a machine following :stable (`image`, state["image"]) that
    word is left out."""
    m = VERSION_LABEL.match(version or "")
    if not m:
        return ""
    tag, year, month, day = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
    if not 1 <= month <= 12 or not 1 <= day <= 31:
        return ""
    text = f"built on {day} {MONTHS[month - 1]} {year}"
    if tag in ("lucciola", "stable") or (tag == "candidate" and re.fullmatch(r"stable(\.\d{8})?|\d{8}", (image or "").rpartition(":")[2])):
        return text
    return f"{text}, {tag}"


# ── what the next version brings ─────────────────────────────────────────
# rpm-ostree keeps the package diff and the advisories of a staged (or
# downloaded) deployment in the `cached-update` block of its status.
SEVERITIES = {4: "critical", 3: "important", 2: "moderate", 1: "low", 0: "unknown"}
ADVISORY_SECURITY = 1


def cached_update(status_json):
    """{'known': bool, 'counts': {upgraded, downgraded, added, removed},
    'packages': {kind: [(name, old, new)]}, 'security': {severity: n},
    'advisories': [(id, severity word, [packages])]}. known is False when
    rpm-ostree has no cached update (nothing staged or downloaded)."""
    out = {"known": False, "counts": {"upgraded": 0, "downgraded": 0, "added": 0, "removed": 0},
           "packages": {"upgraded": [], "downgraded": [], "added": [], "removed": []},
           "security": {}, "advisories": []}
    try:
        cached = (json.loads(status_json or "{}") or {}).get("cached-update") or {}
    except (json.JSONDecodeError, AttributeError):
        return out
    if not isinstance(cached, dict) or not cached:
        return out
    diff = cached.get("rpm-diff") or {}
    for kind in ("upgraded", "downgraded"):
        for row in diff.get(kind) or []:
            try:
                _, name, old, new = row[:4]
                out["packages"][kind].append((name, old[0] if isinstance(old, list) else str(old), new[0] if isinstance(new, list) else str(new)))
            except (ValueError, TypeError, IndexError):
                continue
    for kind in ("added", "removed"):
        for row in diff.get(kind) or []:
            try:
                _, name, version = row[:3]
                out["packages"][kind].append((name, str(version), ""))
            except (ValueError, TypeError):
                continue
    for kind in out["packages"]:
        out["packages"][kind].sort(key=lambda p: p[0].lower())
        out["counts"][kind] = len(out["packages"][kind])
    for adv in cached.get("advisories") or []:
        try:
            adv_id, kind, severity, packages = adv[0], int(adv[1]), int(adv[2]), list(adv[3] or [])
        except (ValueError, TypeError, IndexError):
            continue
        if kind != ADVISORY_SECURITY:
            continue
        word = SEVERITIES.get(severity, "unknown")
        out["security"][word] = out["security"].get(word, 0) + 1
        out["advisories"].append((str(adv_id), word, packages))
    order = {w: i for i, w in enumerate(SEVERITIES.values())}
    out["advisories"].sort(key=lambda a: (order.get(a[1], 9), a[0]))
    out["known"] = True
    return out


def changes_phrase(cached):
    """'358 packages upgraded, 3 removed. 10 important, 16 moderate, 5 low
    and 2 unrated security fixes'."""
    if not cached.get("known"):
        return ""
    counts = cached["counts"]
    parts = []
    if counts["upgraded"]:
        parts.append(f"{counts['upgraded']} package{'s' if counts['upgraded'] != 1 else ''} upgraded")
    for kind in ("added", "removed", "downgraded"):
        if counts[kind]:
            parts.append(f"{counts[kind]} {kind}")
    text = ", ".join(parts) if parts else "No package changes"
    sec = security_phrase(cached["security"])
    return f"{text}. {sec}" if sec else text


def security_phrase(security):
    if not security:
        return ""
    words = [f"{security[w]} {('unrated' if w == 'unknown' else w)}" for w in SEVERITIES.values() if security.get(w)]
    total = sum(security.values())
    text = words[0] if len(words) == 1 else ", ".join(words[:-1]) + f" and {words[-1]}"
    return f"{text} security fix{'es' if total != 1 else ''}"


# ── the phases of a system update, from rpm-ostree's and bootc's output ──
UPDATE_PHASES = (
    (re.compile(r"Pulling manifest|Pulling from|layers already present|layers needed", re.I), "Checking the new image"),
    (re.compile(r"Fetching (layer|ostree chunk)|Importing:|Fetching:|Downloading layer", re.I), "Downloading the new image"),
    (re.compile(r"Checking out tree|Wrote commit|Writing objects", re.I), "Unpacking the new image"),
    (re.compile(r"Enabled rpm-md|Updating metadata|Importing rpm-md|Resolving dependencies|Preparing pkg txn", re.I), "Resolving the extra packages"),
    (re.compile(r"Downloading from|Importing packages|Downloading packages", re.I), "Downloading the extra packages"),
    (re.compile(r"Applying \d+ overrides|Processing packages|Running pre|Running post|Relabeling|Installing \d+ packages|Applying", re.I), "Applying the extra packages on top"),
    (re.compile(r"Staging deployment|Queued for next boot|Writing OSTree commit", re.I), "Preparing the next restart"),
    (re.compile(r"Run \"systemctl reboot\"|reboot to switch|A new deployment is staged|Nothing new was staged|Already up-to-date|No upgrade available", re.I), "Done"),
)


def update_phase(line):
    """The phase a line of `system-update` output announces, or None."""
    text = (line or "").strip()
    if not text:
        return None
    for pattern, phrase in UPDATE_PHASES:
        if pattern.search(text):
            return phrase
    return None


# ── keeping a version: ostree's pins ─────────────────────────────────────
OSTREE_DEPLOYMENT = re.compile(r"^([* ]) \S+ [0-9a-f]{64}\.\d+")


def pin_index(ostree_admin_status):
    """The index `ostree admin pin` wants for the booted deployment: its
    position in `ostree admin status`, which lists a staged deployment
    first, exactly as the sysroot's deployment list does. None when the
    booted one is not found."""
    index = 0
    for line in (ostree_admin_status or "").splitlines():
        m = OSTREE_DEPLOYMENT.match(line)
        if not m:
            continue
        if m.group(1) == "*":
            return index
        index += 1
    return None


def keep_phrase(pinned, rollback):
    if pinned:
        return "Kept: later updates leave this version in the boot menu until you release it"
    return "Not kept: the second update from now replaces it as the previous version"


# ── automatic updates: the last runs of each channel ────────────────────
# uupd stages the system image (and upgrades distroboxes) daily; Lucciola's
# own timers update the system Flatpak apps twice a day, the user's own
# apps once, Homebrew once a week. Until 2026-11-01 a failed run was a line
# in the journal and nothing else (that day: a distrobox that no longer
# started failed uupd for days, brew failed on a tap without a bottle, and
# the window kept saying everything was fine).

CHANNELS = (
    # key, title, system units, user units, timers (system), timers (user)
    ("system", "System", ("uupd.service",), (), ("uupd.timer",), ()),
    ("apps", "Apps", ("margine-flatpak-update.service",), ("margine-flatpak-user-update.service",),
     ("margine-flatpak-update.timer",), ("margine-flatpak-user-update.timer",)),
    ("tools", "Command-Line Tools", (), ("margine-brew-upgrade.service",), (), ("margine-brew-upgrade.timer",)),
)
SYSTEM_UNITS = tuple(u for ch in CHANNELS for u in ch[2])
USER_UNITS = tuple(u for ch in CHANNELS for u in ch[3])
SYSTEM_TIMERS = tuple(u for ch in CHANNELS for u in ch[4])
USER_TIMERS = tuple(u for ch in CHANNELS for u in ch[5])
UNIT_PROPERTIES = "Id,Result,ActiveState,ExecMainStartTimestamp,ExecMainExitTimestamp"


def parse_unit_show(text):
    """`systemctl show --timestamp=unix -p Id,Result,ActiveState,ExecMain*
    UNIT...` -> {unit: {"result", "active", "started", "exited"}}; the
    timestamps are epoch seconds or None. A unit the manager does not know
    comes back with an empty Id and is skipped."""
    units = {}
    for block in (text or "").split("\n\n"):
        props = {}
        for line in block.splitlines():
            key, sep, value = line.partition("=")
            if sep:
                props[key.strip()] = value.strip()
        unit = props.get("Id")
        if not unit:
            continue
        units[unit] = {
            "result": props.get("Result") or "",
            "active": props.get("ActiveState") or "",
            "started": _unix_stamp(props.get("ExecMainStartTimestamp")),
            "exited": _unix_stamp(props.get("ExecMainExitTimestamp")),
        }
    return units


def _unix_stamp(value):
    value = (value or "").strip()
    if value.startswith("@"):
        value = value[1:]
    try:
        stamp = int(float(value))
    except ValueError:
        return None
    return stamp or None


def parse_timers(text):
    """`systemctl list-timers --all --output=json TIMER...` -> {timer:
    {"last": epoch or None, "next": epoch or None}} (the JSON carries
    microseconds)."""
    timers = {}
    try:
        rows = json.loads(text or "[]")
    except json.JSONDecodeError:
        return timers
    for row in rows if isinstance(rows, list) else []:
        unit = row.get("unit") if isinstance(row, dict) else None
        if not unit:
            continue
        timers[unit] = {
            "last": _usec(row.get("last")),
            "next": _usec(row.get("next")),
        }
    return timers


def _usec(value):
    if not isinstance(value, (int, float)) or value <= 0:
        return None
    # systemd's "never" is the largest 64-bit value; anything past 2200 is it.
    if value > 7_000_000_000_000_000:
        return None
    return int(value // 1_000_000)


def when_phrase(stamp, now):
    """'today at 10:38', 'yesterday at 23:10', 'on 28 Oct at 04:12',
    'tomorrow at 04:12'; '' for None."""
    if not stamp:
        return ""
    import time as _time
    day = _time.strftime("%Y-%m-%d", _time.localtime(stamp))
    hm = _time.strftime("%H:%M", _time.localtime(stamp))
    today = _time.strftime("%Y-%m-%d", _time.localtime(now))
    offset = round((_time.mktime(_time.strptime(day, "%Y-%m-%d")) - _time.mktime(_time.strptime(today, "%Y-%m-%d"))) / 86400)
    if offset == 0:
        return f"today at {hm}"
    if offset == -1:
        return f"yesterday at {hm}"
    if offset == 1:
        return f"tomorrow at {hm}"
    return f"on {_time.strftime('%-d %b', _time.localtime(stamp))} at {hm}"


# systemd forgets a unit's result at every restart, so right after one every
# channel would read "Not run yet" and a failure would vanish. The manager's
# own lines in the journal keep the last run; systemd-journald answers these
# in milliseconds, so the bar can ask at every poll.
JOURNAL_RUN = re.compile(r"^(\d+)(?:\.\d+)?\s.*?:\s(?:Finished\s|\S+: Failed with result '([^']+)')")


def journal_run_args(unit):
    """journalctl arguments for the manager's last line about a unit's run."""
    name = re.escape(unit)
    return ["-u", unit, "-r", "-n", "1", "-o", "short-unix", "--no-pager", "-q",
            "-g", f"^(Finished {name}|{name}: Failed with result)"]


def parse_journal_run(text):
    """The unit entry for a run read from the journal, or None. A run killed
    by a signal was stopped by the restart that made systemd forget it (15 s
    into uupd, 2026-11-03): interrupted, not failed."""
    found = JOURNAL_RUN.match((text or "").strip().splitlines()[0]) if (text or "").strip() else None
    if not found:
        return None
    result = found.group(2) or "success"
    return {"result": "interrupted" if result == "signal" else result, "active": "inactive",
            "started": None, "exited": int(found.group(1))}


def forgotten_units(units, names):
    """The units of a list with no run in this boot."""
    return [name for name in names if unit_outcome(units.get(name)) == "never"]


def unit_outcome(unit):
    """One word for a unit's last run: ok, failed, hung (killed on timeout),
    interrupted (by a restart), running, never."""
    if not unit:
        return "never"
    if unit.get("active") in ("activating", "active", "deactivating"):
        return "running"
    result = unit.get("result") or ""
    if result == "interrupted":
        return "interrupted"
    if result == "timeout":
        return "hung"
    if result and result != "success":
        return "failed"
    if not unit.get("exited") and not unit.get("started"):
        return "never"
    return "ok"


def channel_health(units, timers, now):
    """One entry per update channel: the worst outcome among its units, the
    unit that set it, when it ran, when the next run is due, and a sentence
    for the row. Reasons (from the journal) are added by the caller."""
    # A failure anywhere names the channel; a run in progress next; a
    # channel is "never" only when none of its units ever ran (a user unit
    # that has not run yet does not hide the system one's last run).
    rank = {"failed": 0, "hung": 1, "running": 2, "interrupted": 3, "ok": 4, "never": 5}
    out = []
    for key, title, sys_units, user_units, sys_timers, user_timers in CHANNELS:
        members = [(u, False) for u in sys_units] + [(u, True) for u in user_units]
        worst, worst_unit, worst_user = "never", None, False
        last = None
        for unit, is_user in members:
            info = units.get(unit)
            outcome = unit_outcome(info)
            if info and info.get("exited") and (last is None or info["exited"] > last):
                last = info["exited"]
            if rank[outcome] < rank[worst] or worst_unit is None:
                worst, worst_unit, worst_user = outcome, unit, is_user
        nexts = [timers[t]["next"] for t in sys_timers + user_timers if t in timers and timers[t]["next"]]
        next_run = min(nexts) if nexts else None
        # Nothing known about the runs (a journal this account may not read):
        # the timers still remember when they fired.
        fired = [timers[t]["last"] for t in sys_timers + user_timers if t in timers and timers[t]["last"]]
        if worst == "never" and fired:
            last = max(fired)
        started = (units.get(worst_unit) or {}).get("started") if worst == "running" else None
        out.append({
            "key": key, "title": title, "outcome": worst, "unit": worst_unit, "user": worst_user,
            "last": last, "next": next_run, "reason": "",
            "line": health_line(worst, last, next_run, started, now),
        })
    return out


def health_line(outcome, last, next_run, started, now, reason=""):
    nxt = when_phrase(next_run, now)
    if outcome == "running":
        return f"Running since {when_phrase(started, now) or 'a moment ago'}"
    if outcome == "never" and last:
        return f"Last started {when_phrase(last, now)}" + (f", next {nxt}" if nxt else "")
    if outcome == "never":
        return f"Not run yet. First run {nxt}" if nxt else "Not run yet"
    if outcome == "interrupted":
        return f"Interrupted by a restart {when_phrase(last, now)}".rstrip() + (f", next {nxt}" if nxt else "")
    if outcome == "superseded":
        return f"The run {when_phrase(last, now)} failed, a newer version has arrived since" + (f". Next run {nxt}" if nxt else "")
    if outcome in ("failed", "hung"):
        head = "Hung and was stopped" if outcome == "hung" else "Failed"
        text = f"{head} {when_phrase(last, now)}".rstrip()
        if reason:
            text += f": {reason.rstrip('.')}"
        return text + (f". Next try {nxt}" if nxt else "")
    text = f"Last run {when_phrase(last, now)}".rstrip() if last else "Last run unknown"
    return text + (f", next {nxt}" if nxt else "")


# uupd closes a run with errors on one line that names the failed steps:
# "2 update module(s) failed: System Update, Distroboxes for User: daniel".
FAILED_STEPS = re.compile(r"\d+ update module\(s\) failed: (.+)$")
SYSTEM_STEP = "System Update"


def failed_steps(journal_text):
    """The steps uupd's last run names as failed, or [] when the journal
    does not say: a closing line counts only after the run's last
    module_fail, so a run cut short never borrows an older run's list."""
    last_fail, steps = -1, []
    for index, line in enumerate((journal_text or "").splitlines()):
        if '"module_fail"' in line:
            last_fail, steps = index, []
            continue
        if "update module(s) failed" not in line:
            continue
        try:
            msg = json.loads(line).get("msg") or ""
        except (json.JSONDecodeError, AttributeError):
            continue
        found = FAILED_STEPS.search(msg)
        if found and last_fail >= 0:
            steps = [step.strip() for step in found.group(1).split(", ") if step.strip()]
    return steps


def settle_system_failure(channel, journal_text, state, now):
    """A night run that failed on the system step alone stops counting once
    a newer image is here, booted or downloaded: one built after the run is
    newer than anything that run could fetch (2026-11-05: the run failed at
    04:15 on a depsolve, the window's update succeeded in the evening, and
    the failure was still notified and shown in red after the restart).
    A failed Distrobox or Homebrew step stands: a new image does not mend
    it. Returns True when the channel became 'superseded'."""
    if channel.get("key") != "system" or channel.get("outcome") != "failed" or not channel.get("last"):
        return False
    if failed_steps(journal_text) != [SYSTEM_STEP]:
        return False
    if not any(built and built > channel["last"] for built in (state.get("staged_built"), state.get("booted_built"))):
        return False
    channel["outcome"] = "superseded"
    channel["line"] = health_line("superseded", channel["last"], channel.get("next"), None, now)
    return True


ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def failure_excerpt(journal_text, limit=160):
    """The reason of a failed run, from the unit's journal (`-o cat`), in
    one line. uupd logs JSON: the last `module_fail` names the step and
    carries the command's output, as an object with Stdout and Stderr
    (distrobox) or as plain text (the system step, 2026-11-05: a text here
    stopped update-state on the very night it had something to say). The
    error is the line that says `error:`, else the last that speaks of one.
    Plain scripts (brew-upgrade, the Flatpak updaters): the last line that
    speaks of an error, else the last non-empty line."""
    lines = [ANSI.sub("", ln).rstrip() for ln in (journal_text or "").splitlines()]
    for line in reversed(lines):
        if '"module_fail"' not in line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        output = entry.get("output") or ""
        if isinstance(output, dict):
            step = output.get("Context") or entry.get("context") or entry.get("module") or "a step"
            text = str(output.get("Stderr") or "") + "\n" + str(output.get("Stdout") or "")
        else:
            step = entry.get("context") or entry.get("module") or "a step"
            text = str(output)
        tail = [ln.strip() for ln in ANSI.sub("", text).splitlines() if ln.strip()]
        stated = [ln for ln in tail if ln.lower().startswith("error:")]
        errors = stated or [ln for ln in tail if re.search(r"error|fail|cannot|could not|unable", ln, re.I)]
        detail = (errors or tail or [""])[-1]
        return f"{step}: {detail}"[:limit].rstrip(": ") if detail else str(step)[:limit]
    plain = [ln.strip() for ln in lines if ln.strip() and not ln.startswith("{")]
    errors = [ln for ln in plain if re.search(r"\berror\b|failed|cannot|could not|unable", ln, re.I)
              and "reported errors" not in ln and not ln.startswith("+ ")]
    if errors:
        return errors[-1][:limit]
    return plain[-1][:limit] if plain else ""


def app_updates(remote_ls_output):
    """`flatpak remote-ls --updates --columns=name,application` -> [(name, id)].
    The name is what people know the app by; the id is what the tools take."""
    apps = []
    for line in (remote_ls_output or "").splitlines():
        parts = line.rstrip("\n").split("\t")
        if not parts or not parts[0].strip():
            continue
        name = parts[0].strip()
        app_id = parts[1].strip() if len(parts) > 1 and parts[1].strip() else name
        apps.append((name, app_id))
    return apps


def waiting_phrase(items, noun, unavailable="Unavailable"):
    """One line for a row subtitle: 'All apps are up to date', '3 waiting:
    Discord, Showtime and 1 more'. items is None when the source could
    not be asked."""
    if items is None:
        return unavailable
    if not items:
        return f"All {noun} are up to date"
    names = [i[0] if isinstance(i, tuple) else i for i in items]
    preview = ", ".join(names[:2])
    if len(names) > 2:
        preview += f" and {len(names) - 2} more"
    return f"{len(names)} waiting: {preview}"


def layered_phrase(layered):
    if not layered:
        return "None: this is a stock Lucciola system"
    preview = ", ".join(layered[:3])
    if len(layered) > 3:
        preview += f" and {len(layered) - 3} more"
    return f"{preview}. Refreshed with every system update"


def check_name(path):
    """/usr/bin/lucciola-validate-margine-system -> 'Margine system'."""
    name = path.rsplit("/", 1)[-1]
    name = re.sub(r"^(lucciola|margine)-validate-", "", name)
    return name.replace("-", " ").capitalize()


def check_summary(results):
    """results: [(name, ok, detail)] -> the group description."""
    failed = [r for r in results if not r[1]]
    if not results:
        return "No checks are installed on this system"
    if not failed:
        return "Everything matches how Lucciola ships"
    return f"{len(failed)} of {len(results)} checks need attention"


def last_line(detail, limit=160):
    lines = [ln for ln in (detail or "").splitlines() if ln.strip()]
    return lines[-1][:limit] if lines else ""


def excluded_apps(blocked_text):
    """/var/lib/margine/update-watchdog/blocked: 'APP SINCE REASON...' per
    line -> [(app, since)]. Apps the update watchdog took out of unattended
    updates because their vendor download kept hanging."""
    out = []
    for line in (blocked_text or "").splitlines():
        parts = line.split()
        if parts:
            out.append((parts[0], parts[1] if len(parts) > 1 else ""))
    return out


def os_release_version(text):
    """VERSION= or VERSION_ID= from os-release, unquoted, or ''."""
    for key in ("VERSION", "VERSION_ID"):
        m = re.search(rf"^{key}=(.*)$", text or "", re.M)
        if m:
            return m.group(1).strip().strip('"')
    return ""


# ── the window's operations, and which of them wait for each other ──────
# rpm-ostree runs one transaction at a time and refuses a second; Flatpak
# and Homebrew lock their own installation. An operation of the window
# waits only for one that needs the same of these, or for itself: SSH, the
# login, the scheduler, the dock, the printers, the phone keep working while
# the system downloads (2026-11-05: one flag for the whole window greyed
# every button for the minutes an update with extra packages takes).
SYSTEM_VERBS = frozenset({"update", "rollback", "pin", "unpin", "kernel"})
FLATPAK_VERBS = frozenset({"flatpak-unblock", "apps-slim", "apps-naked", "apps-restore"})
BREW_VERBS = frozenset({"brew-remove"})
# What each optional feature of the feature helper touches, in and out.
FEATURE_LANES = {
    "gaming": ("system", "flatpak"), "gaming-native": ("system", "flatpak"),
    "ai": ("flatpak",), "sunshine": ("flatpak",),
    "devmode": ("system",), "vscode": ("system",), "devtools": ("system",), "docker": ("system",),
    "tailscale": ("system",), "vm": ("system",), "phone": ("system",),
}
# The tweaks (ujust recipes) that install or update apps.
FLATPAK_RECIPES = frozenset({"install-spola", "lucciola-darktable-opencl"})
# ssh-on and ssh-off, grub-lock-on and grub-lock-off...: one operation each.
VERB_FAMILY = re.compile(r"-(on|off|enable|disable|enroll|never|wake|rescue|repair)$")
SHARED_LANES = ("system", "flatpak", "brew")
LANE_WORDS = {
    "system": "changes to the system (updates, extra packages, the kernel)",
    "flatpak": "installing and removing apps",
    "brew": "the command-line tools",
}


def operation_lanes(argv):
    """What an operation of the window holds while it runs: 'system'
    (rpm-ostree and the boot entries), 'flatpak', 'brew', and its own name,
    so the same operation never runs twice. Two operations wait for each
    other only when what they hold meets."""
    argv = [str(a) for a in (argv or [])]
    if argv[:1] == ["pkexec"]:
        argv = argv[1:]
    if not argv:
        return frozenset()
    prog = argv[0].rsplit("/", 1)[-1]
    sub = argv[1] if len(argv) > 1 else ""
    if prog == "admin" and sub:
        family = VERB_FAMILY.sub("", sub)
        lanes = {family, *FEATURE_LANES.get(family, ())}
        for lane, verbs in (("system", SYSTEM_VERBS), ("flatpak", FLATPAK_VERBS), ("brew", BREW_VERBS)):
            if sub in verbs:
                lanes.add(lane)
        return frozenset(lanes)
    if prog == "flatpak" and sub in ("install", "uninstall", "update"):
        return frozenset({"flatpak"})
    if prog == "ujust":
        return frozenset({sub, "flatpak"} if sub in FLATPAK_RECIPES else {sub})
    if prog == "brew-upgrade" or (prog == "devmode" and sub.startswith("brew")):
        return frozenset({"brew"})
    return frozenset({f"{prog} {VERB_FAMILY.sub('', sub)}".strip()})


def waiting_for(lanes, running, background=False):
    """The title of the operation that lanes must wait for, out of running
    [(title, lanes)]; a system update rpm-ostree reports as running (the
    night's, or a command's) holds 'system' too. None when free."""
    for title, held in running:
        if lanes & held:
            return title
    if background and "system" in lanes:
        return "The system update in the background"
    return None


def banner_text(running, background=False):
    """One line for the top of the window while something shared is held:
    what waits, and that the rest does not. '' when nothing is."""
    for title, held in running:
        shared = [lane for lane in SHARED_LANES if lane in held]
        if shared:
            words = " and ".join(LANE_WORDS[lane] for lane in shared)
            return f"{title}: {words} wait until it ends, everything else works as usual"
    if background:
        return f"A system update is running in the background: {LANE_WORDS['system']} wait until it ends"
    return ""


# ── the pages' state, parsed from the helpers' own words ─────────────

STATUS_LINE = re.compile(r"^  (.{26}) (.*)$")


def parse_tpm_status(text):
    """`lucciola-tpm-unlock status` (as root) -> what the page needs. Each
    line is '  <label padded to 26> <value>'; the glyphs are the helper's:
    ✓ good, ✗ bad, — absent. error is set when there is no LUKS root."""
    st = {"device": None, "token": None, "wired": None, "fallback": None, "luks": "", "error": ""}
    if "Could not auto-detect a LUKS device" in (text or "") or "LUKS root detection failed" in (text or ""):
        st["error"] = "no encrypted disk behind the system"
        return st
    for line in (text or "").splitlines():
        m = STATUS_LINE.match(line)
        if not m:
            continue
        label, value = m.group(1).strip(), m.group(2).strip()
        good = value.startswith("✓")
        if label == "TPM2 device":
            st["device"] = good
        elif label == "TPM2 token":
            st["token"] = good
        elif label == "Boot path (crypttab)":
            st["wired"] = good
        elif label == "Fallback keyslot":
            st["fallback"] = good
        elif label == "LUKS device backing root":
            st["luks"] = value
    return st


def tpm_summary(st):
    """(state, sentence) for the Disk Unlock row: on, half (token without
    the boot path), off, unencrypted, unknown."""
    if st.get("error"):
        return "unencrypted", "The disk is not encrypted, or its encryption is not the one Lucciola sets up"
    if st.get("device") is False:
        return "no-tpm", "This machine has no TPM 2.0 chip; the passphrase is typed at every startup"
    if st.get("token") and st.get("wired"):
        return "on", "The TPM unlocks the disk at startup; only the login is asked"
    if st.get("token") and st.get("wired") is False:
        return "half", "A TPM key is enrolled but the startup does not use it yet"
    if st.get("token") is False:
        return "off", "The disk passphrase is typed at every startup"
    return "unknown", "Could not read how the disk is unlocked"


def parse_grub_lock(text):
    """`grub-lock status` -> 'on', 'off', 'unavailable' or None."""
    m = re.search(r"^GRUB menu lock: (ON|off|not available)", text or "", re.M)
    if not m:
        return None
    return {"ON": "on", "off": "off", "not available": "unavailable"}[m.group(1)]


def parse_autologin(text):
    """`lucciola-autologin status` -> (enabled, user)."""
    m = re.search(r'autologin: ENABLED for user "([^"]+)"', text or "")
    if m:
        return True, m.group(1)
    if re.search(r"autologin: disabled", text or ""):
        return False, None
    return None, None


# Interfaces that are not a way in from another computer: containers, VMs.
SSH_SKIP_INTERFACES = ("lo", "podman", "docker", "veth", "virbr", "br-", "vnet")


def ip_addresses(ip_brief):
    """`ip -4 -br addr show up` -> the addresses another computer can use."""
    found = []
    for line in (ip_brief or "").splitlines():
        words = line.split()
        if len(words) >= 3 and not words[0].startswith(SSH_SKIP_INTERFACES):
            found.append(words[2].split("/")[0])
    return found


def ssh_state(active, firewall):
    """`systemctl is-active sshd.service` and `firewall-cmd --query-service=ssh`
    -> on, off, or a half state: blocked (running behind a closed firewall),
    open (the firewall lets it through, nothing answers). A firewall that is
    not running blocks nothing."""
    running = (active or "").strip() == "active"
    passes = (firewall or "").strip() in ("yes", "not running")
    if running:
        return "on" if passes else "blocked"
    return "open" if (firewall or "").strip() == "yes" else "off"


def ssh_phrase(state, user, addresses):
    """The switch's subtitle."""
    if state == "on":
        if addresses:
            return "On. From another computer: " + " or ".join(f"{user}@{a}" for a in addresses)
        return "On, but this computer is not on a network right now"
    if state == "blocked":
        return "SSH is running, but the firewall keeps other computers out. Turn this on to let them in"
    if state == "open":
        return "The firewall is open, but SSH is not running. Turn this on to start it"
    return "Off. Nobody can log in to this computer from another one"


def parse_keyring_status(text):
    """`lucciola-keyring status` -> {'unlocked': bool|None, 'at_login': ...}.
    at_login: 'tpm-used' (credential present and used at this login),
    'tpm-present' (present, this login used the password), 'tpm-wrong'
    (present but holds a wrong password), 'tpm-next' (just stored, applies
    at the next login), 'password' (no credential), or None."""
    st = {"unlocked": None, "at_login": None}
    for line in (text or "").splitlines():
        s = line.strip()
        if s.startswith("login keyring:"):
            if "unlocked" in s:
                st["unlocked"] = True
            elif "LOCKED" in s:
                st["unlocked"] = False
        elif s.startswith("unlock at login:"):
            v = s.partition(":")[2].strip()
            if "used at this login" in v:
                st["at_login"] = "tpm-used"
            elif "WRONG password" in v:
                st["at_login"] = "tpm-wrong"
            elif "this login used the login password" in v:
                st["at_login"] = "tpm-present"
            elif v.startswith("TPM credential present"):
                st["at_login"] = "tpm-next"
            elif v.startswith("password login only"):
                st["at_login"] = "password"
    return st


def secureboot_state(sb_state_text, mok_status_text):
    """`mokutil --sb-state` first line and `mok-enroll status` -> {'secure_boot':
    bool|None, 'key': enrolled|pending|absent|unsupported}."""
    first = (sb_state_text or "").strip().splitlines()[:1]
    sb = None
    if first:
        if "enabled" in first[0]:
            sb = True
        elif "disabled" in first[0]:
            sb = False
    key = (mok_status_text or "").strip()
    if key not in ("enrolled", "pending", "absent", "unsupported"):
        key = "unsupported"
    return {"secure_boot": sb, "key": key}


def ref_tag(ref):
    """The tag of a container image reference of this image's repository,
    or None (another image, a digest pin, no reference)."""
    rest = (ref or "").partition(":")[2].removeprefix("docker://")
    if rest.startswith(REPO + ":") and "@" not in rest:
        return rest[len(REPO) + 1:]
    return None


def kernel_flavour(tag, reserve_tag):
    """fedora for the reserve tag and its dated/-test forms, cachyos otherwise."""
    if not tag or not reserve_tag:
        return None
    if tag == reserve_tag or tag.startswith(reserve_tag + ".") or tag.startswith(reserve_tag + "-"):
        return "fedora"
    return "cachyos"


def kernel_state(state, flavour_text, reserve_tag_text):
    """What kernel runs and what is staged, from rpm-ostree's state (with
    booted_ref/staged_ref), /usr/share/margine/kernel-flavor and line 1 of
    /usr/share/margine/kernel-reserve-tag."""
    reserve = ""
    for line in (reserve_tag_text or "").splitlines():
        if line.strip() and not line.startswith("#"):
            reserve = line.strip()
            break
    running = (flavour_text or "").strip()
    if running not in ("cachyos", "fedora"):
        running = None
    booted_tag = ref_tag(state.get("booted_ref"))
    staged_tag = ref_tag(state.get("staged_ref"))
    return {
        "running": running,
        "reserve_tag": reserve,
        "follows": booted_tag,
        "follows_flavour": kernel_flavour(booted_tag, reserve),
        "staged": staged_tag,
        "staged_flavour": kernel_flavour(staged_tag, reserve) if staged_tag and staged_tag != booted_tag else None,
    }


SCHED_MODES = (("Auto", "auto"), ("Gaming", "gaming"), ("LowLatency", "lowlatency"), ("PowerSave", "powersave"), ("Server", "server"))
SCHED_MODE_LABELS = {"Auto": "Auto", "Gaming": "Gaming", "LowLatency": "Low latency", "PowerSave": "Power save", "Server": "Server"}


def scheduler_state(sysfs_state, ops, config_text, enabled, active):
    """The CPU scheduler, from /sys/kernel/sched_ext/state ('enabled' or
    'disabled'), /sys/kernel/sched_ext/root/ops (the scheduler loaded), the
    boot config /etc/scx_loader/config.toml and scx_loader.service's
    enabled/active words. Never from scxctl, which starts the daemon."""
    running = None
    if (sysfs_state or "").strip() == "enabled":
        running = (ops or "").strip().removeprefix("scx_") or "unknown"
    default_sched = default_mode = None
    for line in (config_text or "").splitlines():
        m = re.match(r'^\s*default_sched\s*=\s*"([^"]*)"', line)
        if m:
            default_sched = m.group(1).removeprefix("scx_")
        m = re.match(r'^\s*default_mode\s*=\s*"([^"]*)"', line)
        if m:
            default_mode = m.group(1)
    enabled_b = (enabled or "").strip() == "enabled"
    return {
        "running": running,
        "default_sched": default_sched if enabled_b else None,
        "default_mode": default_mode if enabled_b else None,
        "config_present": default_sched is not None,
        "enabled": enabled_b,
        "active": (active or "").strip() == "active",
    }


def grub_password_ok(password):
    return bool(re.match(r"^[A-Za-z0-9]{8,}$", password or ""))


def pcrs_ok(pcrs):
    return bool(re.match(r"^[0-9]{1,2}(\+[0-9]{1,2})*$", pcrs or ""))


# ── optional features, app profiles, hardware helpers (the Features, Apps
# and Hardware pages) ──────────────────────────────────────────────────

FEATURE_STATES = ("installed", "absent", "pending", "partial")
FEATURE_STATE_LABELS = {
    "installed": "Installed",
    "absent": "Not installed",
    "pending": "Installed, working after a restart",
    "partial": "Partly installed",
    "unknown": "Could not read the state",
}


def feature_status(text):
    """The first lines of `feature NAME status`: {"state", "detail"}. An
    unknown or missing state word reads as unknown, never as absent."""
    st = {"state": "unknown", "detail": ""}
    for line in text.splitlines():
        if line.startswith("state="):
            st["state"] = line[len("state="):].strip()
        elif line.startswith("detail="):
            st["detail"] = line[len("detail="):].strip()
    if st["state"] not in FEATURE_STATES:
        st["state"] = "unknown"
    return st


def feature_statuses(text):
    """`feature all status`: a [name] block per feature, each with its
    state and detail lines; a feature the helper did not print is unknown."""
    out = {}
    name, block = None, []
    for line in text.splitlines() + ["[end]"]:
        if line.startswith("[") and line.endswith("]"):
            if name is not None:
                out[name] = feature_status("\n".join(block))
            name, block = line[1:-1], []
        else:
            block.append(line)
    return out


def gaming_state(flatpak_variant, native_variant):
    """One Gaming row for two variants: the native one wins when it is
    there, so the row never calls the Flatpak set partial because the
    native set shares four apps with it."""
    if native_variant["state"] in ("installed", "pending"):
        return dict(native_variant, variant="native")
    return dict(flatpak_variant, variant="flatpak")


def apps_profile(slim_state, naked_state):
    """stock, slim, naked or mixed (a profile applied and some of its apps
    put back by hand) from the two profiles' states."""
    if naked_state == "installed":
        return "naked"
    if slim_state == "installed":
        return "slim"
    if slim_state == "partial" or naked_state == "partial":
        return "mixed"
    return "stock"


def dock_rescue_on(switch_text):
    """/etc/margine/dock-dp-rescue: off turns the automatic rescue off;
    absent, empty or anything else is the default, on."""
    return switch_text.strip() != "off"


def stale_queues(listing):
    """Queues cups-browsed created, from `printers-repair --list` or from
    `lpstat -v` (device for NAME: implicitclass://...)."""
    names = []
    for line in listing.splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r"^device for ([^:]+): implicitclass:", line)
        if m:
            names.append(m.group(1))
        elif "implicitclass:" not in line and " " not in line:
            names.append(line)
    return names


def home_layout_stock(dry_run_text):
    """restore-stock-home without --apply: says [no change] when the home
    already has the stock folders, else lists what it would do."""
    return "[no change]" in dry_run_text


def amd_gpu(lspci_text):
    """An AMD GPU in lspci's output: the vendor as lspci prints it, as a
    word (a case-blind ATI would match "Corporation")."""
    return bool(re.search(r"(VGA|3D|Display)[^\n]*(\bAMD\b|\bATI\b|Radeon|Advanced Micro Devices)", lspci_text))


def override_set(show_text, marker):
    """`flatpak override --user --show APP` has a line that carries the
    marker (an environment key, a path): the tweak is on."""
    return any(marker in line for line in show_text.splitlines())


def netflix_state(status_text, rc):
    """`ujust lucciola-netflix-1080p status`: the extension line, or why
    there is nothing to say (no Zen, no profile yet)."""
    if rc != 0:
        return "no-browser"
    for line in status_text.splitlines():
        if line.startswith("Profile:") and "none yet" in line:
            return "no-profile"
        if line.startswith("Extension:"):
            return "installed" if "not" not in line else "absent"
    return "unknown"


# ── the phone (KDE Connect's daemon over D-Bus) ──────────────────────────

# The functions the Phone page offers per device, with the plugin that does
# each (the ids KDE Connect uses) and a sentence. Notifications to the phone
# start off on Lucciola: they carry their text, the user turns them on.
PHONE_FUNCTIONS = (
    ("kdeconnect_notifications", "Phone Notifications Here", "The phone's notifications appear on this PC, with a reply where the app allows it"),
    ("kdeconnect_sendnotifications", "This PC's Notifications on the Phone", "Off until you turn it on: notifications carry their text. The app on the phone must have Receive Notifications on for this PC, off there by default"),
    ("kdeconnect_clipboard", "Shared Clipboard", "Copy on one, paste on the other"),
    ("kdeconnect_share", "Files and Links", "Send a file or a link either way; received files land in Downloads"),
    ("kdeconnect_sftp", "The Phone in Files", "Browse the phone's storage from Files"),
    ("kdeconnect_mprisremote", "Media Control", "Play, pause, volume and track from the phone"),
    ("kdeconnect_battery", "Battery", "The phone's charge in the tray and here"),
    ("kdeconnect_findmyphone", "Ring the Phone", "Make the phone ring from here"),
    ("kdeconnect_runcommand", "Commands", "Run commands on this PC from the phone: lock, suspend, power off"),
    ("kdeconnect_systemvolume", "This PC's Volume", "Change this PC's volume from the phone"),
    ("kdeconnect_telephony", "Calls", "Incoming and missed calls as notices here; without the Phone, Contacts and Call log permissions in the app, it guesses. Phone Notifications Here already carries the Phone app's own notices"),
    ("kdeconnect_ping", "Ping", "A test notification either way"),
)
PHONE_DEFAULT_OFF = ("kdeconnect_sendnotifications",)

# Ready-made commands for the phone (KDE Connect's runcommand plugin runs
# each with /bin/sh -c in the user's session).
PHONE_COMMANDS = (
    ("Lock the screen", "/usr/libexec/lucciola/lock"),
    ("Suspend", "systemctl suspend"),
    ("Power off", "systemctl poweroff"),
    ("Mute or unmute", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),
    ("Keep awake until midnight", "/usr/libexec/lucciola/keep-awake on"),
    ("Stop keeping awake", "/usr/libexec/lucciola/keep-awake off"),
)


def device_state(paired, reachable, requested_by_peer, requested):
    """What a device is to this PC right now, in one word the page maps to a sentence."""
    if requested_by_peer:
        return "wants-to-pair"
    if paired and reachable:
        return "connected"
    if paired:
        return "paired-away"
    if requested:
        return "requested"
    return "available"


DEVICE_STATE_LABELS = {
    "connected": "Connected",
    "paired-away": "Paired, not reachable now",
    "wants-to-pair": "Wants to pair with this PC",
    "requested": "Pairing requested: accept on the phone",
    "available": "On this network, not paired",
}


def battery_phrase(charge, charging):
    if charge is None or charge < 0:
        return ""
    return f"Battery {charge}%" + (", charging" if charging else "")


def plugin_setting(config_text, plugin):
    """The explicit setting of a plugin in the device's config ([Plugins]
    group, <plugin>Enabled=true|false): True, False, or None when the daemon
    applies its own default."""
    group = None
    for raw in config_text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            group = line[1:-1]
            continue
        if group != "Plugins" or "=" not in line:
            continue
        key, _, value = line.partition("=")
        if key.strip() == f"{plugin}Enabled":
            return value.strip().lower() == "true"
    return None


def ini_quote(value):
    """A value as QSettings' INI format reads it back whole: quoted, with
    backslashes and double quotes escaped (an unquoted comma would split it
    into a list)."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def ini_unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return value


def commands_config(existing_text, presets, new_key):
    """The runcommand plugin's config with the presets added once (a command
    already there, by its command line, is left as it is): the text to write,
    and how many were added. existing_text is the current file, or empty."""
    commands = {}
    for raw in existing_text.splitlines():
        if raw.strip().startswith("commands="):
            try:
                commands = json.loads(ini_unquote(raw.split("=", 1)[1]))
            except ValueError:
                commands = {}
            if not isinstance(commands, dict):
                commands = {}
    present = {str(v.get("command", "")).strip() for v in commands.values() if isinstance(v, dict)}
    added = 0
    for name, command in presets:
        if command in present:
            continue
        commands[new_key()] = {"name": name, "command": command}
        present.add(command)
        added += 1
    text = "[General]\ncommands=" + ini_quote(json.dumps(commands, separators=(",", ":"))) + "\n"
    return text, added


def device_sort_key(device):
    """Connected first, then wanting to pair, then paired, then the rest; by name inside."""
    order = {"wants-to-pair": 0, "connected": 1, "paired-away": 2, "requested": 3, "available": 4}
    return (order.get(device.get("state"), 9), (device.get("name") or "").lower())


# ── the phone as a webcam (adb, scrcpy, the loopback device) ─────────────

CAM_LABELS = ("Lucciola Phone Cam", "Margine Phone Cam", "Phone Cam")
CAM_DEFAULT_SIZES = ("1920x1080", "1280x720", "640x480")
ADB_CONNECT_SERVICE = "_adb-tls-connect._tcp"
ADB_PAIR_SERVICE = "_adb-tls-pairing._tcp"


def adb_devices(text):
    """`adb devices -l`: the devices after the header line, each with its
    serial, state (device, unauthorized, offline, ...), model when printed,
    and whether it came over the network (a host:port serial or an mDNS
    name) rather than USB."""
    out = []
    for line in text.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 2 or parts[0].startswith("*"):
            continue
        serial, state = parts[0], parts[1]
        model = ""
        for p in parts[2:]:
            if p.startswith("model:"):
                model = p[len("model:"):].replace("_", " ")
        wireless = ":" in serial or "_adb-tls-connect" in serial
        out.append({"serial": serial, "state": state, "model": model, "wireless": wireless})
    return out


def mdns_services(text):
    """`adb mdns services`: name, type, host:port per line after the header."""
    out = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) != 3 or not parts[1].startswith("_adb"):
            continue
        host, _, port = parts[2].rpartition(":")
        if not host or not port.isdigit():
            continue
        out.append({"name": parts[0], "type": parts[1], "host": host, "port": int(port)})
    return out


def connect_service_for(services, addresses):
    """The adb connect service of the phone KDE Connect sees at one of these
    addresses; the only one when there is one and no address matches."""
    connects = [s for s in services if s["type"] == ADB_CONNECT_SERVICE]
    for s in connects:
        if s["host"] in addresses:
            return s
    if len(connects) == 1 and not addresses:
        return connects[0]
    return None


def size_key(size):
    """Pixels of a WxH size, for sorting."""
    w, h = size.split("x")
    return int(w) * int(h)


def camera_sizes(text):
    """The server's camera list: every WxH size in it, largest first."""
    sizes = {m.group(0) for m in re.finditer(r"\b(\d{3,5}x\d{3,5})\b", text)}
    return sorted(sizes, key=size_key, reverse=True)


def webcam_sizes(sizes):
    """The sizes worth offering for a webcam: 16:9 and 4:3, from 640 pixels
    wide up to 1080p. The sensor's own list runs to 12 megapixels and 2:1
    shapes; past 1080p nothing gains over Wi-Fi and the PC decodes for
    nothing. The whole list stays when none of it fits."""
    keep = []
    for size in sizes:
        try:
            w, h = (int(x) for x in size.split("x"))
        except ValueError:
            continue
        if 640 <= w <= 1920 and h <= 1080 and (w * 9 == h * 16 or w * 3 == h * 4):
            keep.append(size)
    return keep or list(sizes)


def camera_orientations(text):
    """`dumpsys media.camera`: {facing: sensor orientation in degrees}. The
    sensor sits sideways in the phone; this is how far the picture turns,
    clockwise, to stand upright on an upright phone (90 behind, 270 in front
    on a Pixel). The first camera of each facing counts."""
    out = {}
    facing = None
    for line in (text or "").splitlines():
        m = re.match(r"\s*Facing:\s*(\w+)", line)
        if m:
            facing = m.group(1).lower()
            continue
        m = re.match(r"\s*Orientation:\s*(\d+)", line)
        if m and facing:
            out.setdefault(facing, int(m.group(1)) % 360)
            facing = None
    return out


def rotation_label(rotation, upright):
    """What the Rotation row says: the phone position the turn suits."""
    delta = (rotation - upright) % 360
    if delta == 0:
        return "Upright phone"
    if delta == 180:
        return "Phone upside down"
    return "Phone on its side"


def camera_sizes_by_facing(text):
    """The server's camera list (`list_camera_sizes=true`) as {facing:
    [WxH, largest first]}: a `--camera-id=N (back, ...)` line opens a
    camera, `- WxH` lines belong to it; the high speed block is skipped,
    those sizes are for 120 and 240 fps."""
    out = {}
    facing = None
    skip = False
    for line in (text or "").splitlines():
        m = re.search(r"--camera-id=\S+\s+\((\w+)", line)
        if m:
            facing = m.group(1).lower()
            skip = False
            out.setdefault(facing, set())
            continue
        if "High speed" in line:
            skip = True
            continue
        m = re.match(r"\s*-\s*(\d{3,5}x\d{3,5})\s*$", line)
        if m and facing and not skip:
            out[facing].add(m.group(1))
    return {f: sorted(v, key=size_key, reverse=True) for f, v in out.items() if v}


def default_size(sizes, wireless):
    """1080p over the cable, 720p over the air (lesson of the first run: an
    unconstrained phone pushes its whole sensor and the apps give up); the
    largest size that fits when the exact one is missing."""
    want = "1280x720" if wireless else "1920x1080"
    if want in sizes:
        return want
    limit = 1280 if wireless else 1920
    for s in sizes:
        if int(s.split("x")[0]) <= limit:
            return s
    return sizes[-1] if sizes else want


def pair_input_ok(host, port, code):
    """What `adb pair` takes: a host, a port, the six digits the phone shows."""
    host_ok = bool(re.match(r"^[A-Za-z0-9.:-]{1,253}$", host or ""))
    port_ok = (port or "").isdigit() and 0 < int(port) < 65536
    code_ok = bool(re.match(r"^[0-9]{6}$", (code or "").strip()))
    return host_ok and port_ok and code_ok


def adb_result(text, rc):
    """One word for adb's answer to pair or connect. adb exits 0 even when
    it fails, so the words decide: a wireless-debugging phone that is not
    paired answers "failed to connect" (its TLS handshake refuses the PC),
    so that counts as not paired."""
    low = (text or "").lower()
    if "successfully paired" in low or "connected to" in low or "already connected" in low:
        return "ok"
    if "connection refused" in low or "no route" in low or "timed out" in low or "unable to connect" in low:
        return "unreachable"
    if "failed to authenticate" in low or "failed to connect" in low or ("pairing" in low and "fail" in low) or "wrong" in low:
        return "not-paired"
    return "ok" if rc == 0 else "error"


def webcam_status(device, stream, adb_ready, wireless_ready, service_seen=False):
    """The sentence under the Camera row. wireless_ready means adb is
    connected to the phone over the network; service_seen means the phone
    advertises wireless debugging but adb could not connect: not paired yet."""
    if device is None:
        return "Virtual camera missing: Lucciola's key must be registered for its module to load"
    if stream and stream.get("state") == "reconnecting":
        link = "Wi-Fi" if stream["wireless"] else "USB"
        return f"The {link} link to the phone dropped: Lucciola Phone Cam stays listed while it reconnects, for up to {RECONNECT_SECONDS} seconds"
    if stream:
        return f"Streaming {stream['size']} from the {stream['facing']} camera to Lucciola Phone Cam" + (" over Wi-Fi" if stream["wireless"] else " over USB")
    if wireless_ready:
        return "Ready over Wi-Fi"
    if adb_ready:
        return "Ready over USB"
    if service_seen:
        return "Wireless debugging is on, but this PC is not paired with it yet: Set Up Wireless, once"
    return "Not connected for the camera: a USB cable with USB debugging on, or Set Up Wireless with wireless debugging on"


# ── the phone camera engine: scrcpy's server driven by us, into PipeWire ──

SCRCPY_VERSION = "5.0.1"
SCRCPY_SERVER = "/usr/lib/margine/scrcpy/scrcpy-server"
# Our own name for the jar on the phone: a server started with cleanup on
# (what the scrcpy client does) deletes its jar at start, so a copy under
# scrcpy's name vanishes under us whenever scrcpy runs.
SCRCPY_SERVER_ON_PHONE = "/data/local/tmp/lucciola-scrcpy-server.jar"
ADB_PAIR_SERVICE_TYPE = "_adb-tls-pairing._tcp"
MIC_RATE = 48000
MIC_CHANNELS = 2
MIC_CAPS = f"audio/x-raw,format=S16LE,rate={MIC_RATE},channels={MIC_CHANNELS},layout=interleaved"
# The microphone's jitter buffer: Wi-Fi bursts up to this long play through,
# and the delay never grows past it.
MIC_BUFFER_NS = 200_000_000
# How long a stream keeps its PipeWire node and tries the phone again after
# the link drops, and after how many seconds without data it is tried again.
RECONNECT_SECONDS = 90
# Counted in bytes from the phone, not decoded frames: a dark scene still
# sends small frames, a dropped link sends nothing.
STALL_SECONDS = 10
# How long a new stream may take to hand over its first frame: a dark scene
# or the back camera's several sensors take seconds.
FIRST_FRAME_SECONDS = 20


def video_caps(size, fmt="I420", rate=True):
    """The caps the camera's outlet keeps for the whole session, and every
    feed converts to: one size, one format, BT.601 limited range (what apps
    assume of a webcam; phones send full-range BT.709), progressive, square
    pixels, a single view. Pinned, a new feed never renegotiates the node:
    v4l2loopback refuses a format change while it streams ("device busy"),
    and the apps linked to the PipeWire node would start over. The feed
    side leaves the frame rate out, the phone's raw stream carries none."""
    try:
        w, h = (int(x) for x in size.split("x"))
    except (AttributeError, ValueError):
        w, h = 1280, 720
    caps = (f"video/x-raw,format={fmt},width={w},height={h},pixel-aspect-ratio=1/1,"
            "interlace-mode=progressive,colorimetry=bt601,chroma-site=mpeg2,multiview-mode=mono")
    return caps + (",framerate=30/1" if rate else "")


def socket_name(scid=None):
    """The abstract socket the server listens on: scrcpy, or scrcpy_<scid>
    with a stream id, so two streams starting at once never share one."""
    return "scrcpy" if scid is None else f"scrcpy_{scid:08x}"


def server_command(mode, facing="back", size="1280x720", bit_rate=4000000, max_fps=30, scid=None, rotation=0):
    """The command run on the phone through `adb shell` for one stream:
    scrcpy's own server, in raw-stream mode (no headers, no control), so a
    plain TCP socket carries bare H.264 (camera) or bare PCM (mic) that
    GStreamer reads straight. Versions must match the bundled jar; cleanup
    stays off or the server deletes the jar."""
    base = ["CLASSPATH=" + SCRCPY_SERVER_ON_PHONE, "app_process", "/", "com.genymobile.scrcpy.Server", SCRCPY_VERSION,
            "tunnel_forward=true", "raw_stream=true", "send_frame_meta=false", "control=false", "cleanup=false", "log_level=info"]
    if scid is not None:
        base.append(f"scid={scid:08x}")
    if mode == "camera":
        turn = [f"capture_orientation={int(rotation) % 360}"] if int(rotation) % 360 in (90, 180, 270) else []
        return base + ["video_source=camera", f"camera_facing={facing}", f"camera_size={size}"] + turn + [
            f"video_bit_rate={int(bit_rate)}", f"max_fps={int(max_fps)}", "audio=false"]
    if mode == "mic":
        return base + ["video=false", "audio=true", "audio_source=mic", "audio_codec=raw"]
    raise ValueError(mode)


def list_command(what="camera_sizes"):
    """The same server in list mode: it prints the cameras and their sizes
    and exits, no client needed."""
    return ["CLASSPATH=" + SCRCPY_SERVER_ON_PHONE, "app_process", "/", "com.genymobile.scrcpy.Server", SCRCPY_VERSION,
            "cleanup=false", f"list_{what}=true"]


def qr_pairing_payload(name, password):
    """What the phone's QR scanner in Wireless debugging expects (the same
    text Android Studio shows): a Wi-Fi-style payload with the service name
    the phone will advertise for pairing, and the pairing password."""
    return f"WIFI:T:ADB;S:{name};P:{password};;"


def pairing_service_for(services, name):
    """The pairing service the phone advertises after scanning our QR code,
    by the name the QR carried."""
    for s in services:
        if s["type"] == ADB_PAIR_SERVICE_TYPE and s["name"] == name:
            return s
    return None


def stream_defaults(wireless):
    """Resolution and bit rate by link: the air gets 720p at 4 Mbit/s, the
    cable 1080p at 8 Mbit/s."""
    return ("1280x720", 4000000) if wireless else ("1920x1080", 8000000)


def models_state(text):
    """`local-models status` -> (state, version): ("running", "0.40.11"),
    ("stopped", "0.40.11"), ("absent", ""), or ("unknown", "") for anything else."""
    words = (text or "").split()
    if words == ["absent"]:
        return ("absent", "")
    if len(words) == 3 and words[0] == "installed" and words[2] in ("running", "stopped"):
        return (words[2], words[1])
    return ("unknown", "")
