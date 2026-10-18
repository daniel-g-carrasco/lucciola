#!/usr/bin/env python3
"""The texts of the Welcome to Lucciola window: check them and write them.

The window (/usr/libexec/margine/welcome) reads
/usr/share/lucciola/welcome/content.json at every start and draws the
sections in the file's order. This module says what a good file looks like,
in words a person can act on, and writes it back in one stable layout so a
change shows up in git as the lines that changed and nothing else.

    python3 tools/content-editor/welcome_content.py [FILE]   # check a file

Used by the content editor before every save, by the lint workflow and by
validate-image-rootfs.sh, so a broken file never reaches an image.
"""

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CONTENT = REPO / "lucciola/system_files/usr/share/lucciola/welcome/content.json"

# Buttons run fixed code in the window, chosen by name: a file can place them,
# relabel them and highlight them, never point them somewhere else.
ACTIONS = {
    "open-guide": "opens the Lucciola Guide",
    "open-system": "opens Lucciola System",
}
STYLES = ("cta", "plain")
CONDITIONS = {
    "mok-pending": "shown only while the Secure Boot key waits for the blue screen",
}
BLOCK_NAMES = {"text": "paragraph", "items": "list", "keys": "keys", "button": "button"}
EM_DASH = "\u2014"

# Key order on disk (the window does not care, git diffs do).
TOP_KEYS = ("about", "window_title", "intro", "sections", "footer")
SECTION_KEYS = ("id", "title", "hidden", "show_if", "blocks")
BLOCK_KEYS = {
    "text": ("type", "text", "dim"),
    "items": ("type", "items"),
    "keys": ("type", "rows"),
    "button": ("type", "action", "label", "style"),
}
ROW_KEYS = ("keys", "label")
FOOTER_KEYS = ("text", "close_label")


def _text_problems(value):
    """Rules every visible text follows."""
    out = []
    if EM_DASH in value:
        out.append("has a long dash (\u2014); use a colon or a comma instead")
    if value.count("`") % 2:
        out.append("has a ` mark without its pair (commands go between two ` marks)")
    return out


def validate(data):
    """Return a list of problems in plain English; empty means the file is good."""
    errors = []

    def need_text(where, value, empty_ok=False):
        if not isinstance(value, str):
            errors.append(f"{where} must be text.")
            return
        if not empty_ok and not value.strip():
            errors.append(f"{where} is empty.")
        for p in _text_problems(value):
            errors.append(f"{where} {p}.")

    def only_keys(where, obj, allowed):
        for k in obj:
            if k not in allowed:
                errors.append(f"{where}: unknown field \"{k}\".")

    if not isinstance(data, dict):
        return ["The file must hold one object with the window's texts."]
    only_keys("The file", data, TOP_KEYS)
    if "about" in data and not isinstance(data["about"], str):
        errors.append("about: must be text.")
    need_text("Window title", data.get("window_title"))
    need_text("Intro", data.get("intro"))

    sections = data.get("sections")
    if not isinstance(sections, list) or not sections:
        errors.append("Sections: there must be at least one section.")
        sections = []
    seen_ids = set()
    for si, sec in enumerate(sections, 1):
        if not isinstance(sec, dict):
            errors.append(f"Section {si}: must be an object.")
            continue
        name = sec.get("title") if isinstance(sec.get("title"), str) else ""
        where = f"Section {si}" + (f" \"{name}\"" if name else "")
        only_keys(where, sec, SECTION_KEYS)
        sid = sec.get("id")
        if not isinstance(sid, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", sid):
            errors.append(f"{where}: needs an id made of small letters, digits and dashes.")
        elif sid in seen_ids:
            errors.append(f"{where}: the id \"{sid}\" is used twice.")
        else:
            seen_ids.add(sid)
        need_text(f"{where}, heading", sec.get("title"))
        if "hidden" in sec and not isinstance(sec["hidden"], bool):
            errors.append(f"{where}: \"hidden\" must be true or false.")
        if "show_if" in sec and sec["show_if"] not in CONDITIONS:
            errors.append(f"{where}: \"show_if\" must be one of: {', '.join(CONDITIONS)}.")
        blocks = sec.get("blocks")
        if not isinstance(blocks, list) or not blocks:
            errors.append(f"{where}: has nothing in it; add a paragraph or delete the section.")
            continue
        counts = {}
        for blk in blocks:
            if not isinstance(blk, dict) or blk.get("type") not in BLOCK_KEYS:
                errors.append(f"{where}: a block has an unknown type (use {', '.join(BLOCK_KEYS)}).")
                continue
            kind = blk["type"]
            counts[kind] = counts.get(kind, 0) + 1
            bw = f"{where}, {BLOCK_NAMES[kind]} {counts[kind]}"
            only_keys(bw, blk, BLOCK_KEYS[kind])
            if kind == "text":
                need_text(bw, blk.get("text"))
                if "dim" in blk and not isinstance(blk["dim"], bool):
                    errors.append(f"{bw}: \"dim\" must be true or false.")
            elif kind == "items":
                items = blk.get("items")
                if not isinstance(items, list) or not items:
                    errors.append(f"{bw}: the list is empty.")
                else:
                    for ii, item in enumerate(items, 1):
                        need_text(f"{bw}, item {ii}", item)
            elif kind == "keys":
                rows = blk.get("rows")
                if not isinstance(rows, list) or not rows:
                    errors.append(f"{bw}: there are no keys.")
                    continue
                for ri, row in enumerate(rows, 1):
                    rw = f"{bw}, row {ri}"
                    if not isinstance(row, dict):
                        errors.append(f"{rw}: must be an object.")
                        continue
                    only_keys(rw, row, ROW_KEYS)
                    combos = row.get("keys")
                    ok = (isinstance(combos, list) and combos and all(
                        isinstance(c, list) and c and all(isinstance(k, str) and k.strip() for k in c)
                        for c in combos))
                    if not ok:
                        errors.append(f"{rw}: the keys are missing or have an empty key.")
                    need_text(f"{rw}, what the keys do,", row.get("label"))
            elif kind == "button":
                if blk.get("action") not in ACTIONS:
                    errors.append(f"{bw}: the action must be one of: {', '.join(ACTIONS)}.")
                need_text(f"{bw}, label", blk.get("label"))
                if blk.get("style", "plain") not in STYLES:
                    errors.append(f"{bw}: the style must be one of: {', '.join(STYLES)}.")

    footer = data.get("footer")
    if not isinstance(footer, dict):
        errors.append("Bottom of the window: missing.")
    else:
        only_keys("Bottom of the window", footer, FOOTER_KEYS)
        need_text("Bottom of the window, text", footer.get("text"))
        need_text("Bottom of the window, Close button", footer.get("close_label"))
    return errors


def _ordered(obj, keys):
    out = {k: obj[k] for k in keys if k in obj}
    out.update({k: v for k, v in obj.items() if k not in out})
    return out


def canonical(data):
    """Same content, fixed key order, defaults (false, "plain") left out."""
    data = _ordered(data, TOP_KEYS)
    secs = []
    for sec in data.get("sections", []):
        sec = _ordered(sec, SECTION_KEYS)
        if sec.get("hidden") is False:
            del sec["hidden"]
        blocks = []
        for blk in sec.get("blocks", []):
            blk = _ordered(blk, BLOCK_KEYS.get(blk.get("type"), ("type",)))
            if blk.get("dim") is False:
                del blk["dim"]
            if blk.get("type") == "keys":
                blk["rows"] = [_ordered(r, ROW_KEYS) for r in blk.get("rows", [])]
            blocks.append(blk)
        sec["blocks"] = blocks
        secs.append(sec)
    data["sections"] = secs
    if isinstance(data.get("footer"), dict):
        data["footer"] = _ordered(data["footer"], FOOTER_KEYS)
    return data


def dumps(data, width=120):
    """JSON with two-space indents; short lists and objects stay on one line."""

    def one_line(v):
        return json.dumps(v, ensure_ascii=False, separators=(", ", ": "))

    def emit(v, indent):
        if not isinstance(v, (dict, list)) or not v:
            return one_line(v)
        flat = one_line(v)
        if len(flat) + indent <= width and "\n" not in flat:
            return flat
        pad = " " * (indent + 2)
        if isinstance(v, dict):
            inner = [f"{pad}{json.dumps(k, ensure_ascii=False)}: {emit(x, indent + 2)}" for k, x in v.items()]
            return "{\n" + ",\n".join(inner) + "\n" + " " * indent + "}"
        inner = [pad + emit(x, indent + 2) for x in v]
        return "[\n" + ",\n".join(inner) + "\n" + " " * indent + "]"

    return emit(canonical(data), 0) + "\n"


def load(path=CONTENT):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main(argv):
    path = Path(argv[1]) if len(argv) > 1 else CONTENT
    try:
        data = load(path)
    except (OSError, ValueError) as e:
        print(f"{path}: cannot be read as JSON: {e}", file=sys.stderr)
        return 1
    errors = validate(data)
    for e in errors:
        print(f"{path}: {e}", file=sys.stderr)
    if errors:
        return 1
    print(f"{path}: ok ({len(data['sections'])} sections)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
