#!/usr/bin/env python3
"""Tests for the content editor (tools/content-editor), run by
tests/content-editor.test.sh: the website patcher on the real site/index.html,
the welcome window's data file and its check."""

import copy
import difflib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/content-editor"))

import serve  # noqa: E402
import site_patch as sp  # noqa: E402
import welcome_content as wc  # noqa: E402

DASH = chr(0x2014)
SRC = (ROOT / "site/index.html").read_text(encoding="utf-8")
fails = 0


def check(name, cond, detail=""):
    global fails
    if cond:
        print(f"ok   {name}")
    else:
        fails += 1
        print(f"FAIL {name}" + (f"\n     {detail}" if detail else ""))


def eid(doc, pred):
    return next(n.eid for n in doc.by_id.values() if pred(n))


def by_attr(doc, name, value):
    return eid(doc, lambda n: sp._attr(n, name) == value)


def changed_lines(a, b):
    return [ln for ln in difflib.unified_diff(a.splitlines(), b.splitlines(), lineterm="", n=0)
            if ln[:1] in "+-" and not ln.startswith(("+++", "---"))]


def save(ops=(), texts=None):
    return sp.save(SRC, sp.Document(SRC).hash, list(ops), texts or {})


# ---- website: reading and writing back --------------------------------------
doc = sp.Document(SRC)
check("site: parses with every element closed", doc.problems == [], doc.problems)
check("site: load and write back is byte-identical", doc.html() == SRC)
new, warns = save()
check("site: a save without edits is byte-identical", new == SRC and warns == [])
served = doc.served()
check("site: the served page differs only by data-edit-id",
      re.sub(r' data-edit-id="\d+"', "", served) == SRC)
check("site: the server adds the editor only to what it serves",
      "/ui/frame.js" in serve.served_site() and "frame.js" not in SRC)

# ---- website: text edits ------------------------------------------------------------
d = sp.Document(SRC)
new, _ = save(texts={by_attr(d, "id", "h-what"): "your own system"})
lines = changed_lines(SRC, new)
check("site: a heading edit changes only that heading",
      lines == ['-    <h2 id="h-what">your system</h2>', '+    <h2 id="h-what">your own system</h2>'], lines)

lede = eid(d, lambda n: sp._attr(n, "class") == "lede")
inner = d.by_id[lede].inner().replace("Some steps", "A few steps")
browser = re.sub(r"<code>", '<code data-edit-id="999">', inner)       # as innerHTML comes back
new, _ = save(texts={lede: browser})
lines = changed_lines(SRC, new)
check("site: an edit around inline <code> keeps the markup byte for byte",
      len(lines) == 2 and lines[1].count("<code>") == 2 and "A few steps" in lines[1] and "data-edit-id" not in new, lines)

cta = eid(d, lambda n: sp._attr(n, "class") == "cta")
cta_inner = d.by_id[cta].inner()
new, _ = save(texts={cta: cta_inner.replace("install", "get it")})
check("site: a label next to an icon changes, the icon stays",
      changed_lines(SRC, new)[1].count("<svg") == 1 and ">get it<svg" in new)
try:
    save(texts={cta: "get it"})
    check("site: a text that lost its icon is refused", False)
except sp.EditError as e:
    check("site: a text that lost its icon is refused", "svg" in str(e))

try:
    save(texts={by_attr(d, "id", "h-what"): f"your system {DASH} and more"})
    check("site: a long dash is refused", False)
except sp.EditError:
    check("site: a long dash is refused", True)

new, _ = save(texts={by_attr(d, "id", "h-what"): "your&nbsp;system &lt;b&gt;"})
check("site: typed spaces stay spaces and markup typed as text stays text",
      '<h2 id="h-what">your system &lt;b&gt;</h2>' in new)

new, _ = save(texts={by_attr(d, "id", "h-what"): "your own<br>system<br>"})
check("site: a browser's stray <br> does not reach the file", '<h2 id="h-what">your ownsystem</h2>' in new)

try:
    sp.save(SRC, "stale", [], {})
    check("site: a save against a page changed on disk is refused", False)
except sp.EditError:
    check("site: a save against a page changed on disk is refused", True)


# ---- website: structure ---------------------------------------------------------------
def section_of(d, heading_id):
    return d.by_id[by_attr(d, "id", heading_id)].parent.eid


def valid(html):
    errors, warnings = sp.check(html)
    return not errors and not sp.Document(html).problems, warnings


new, _ = save([{"op": "swap", "a": [section_of(d, "h-updates")], "b": [section_of(d, "h-work")]}])
ok, _ = valid(new)
check("site: moving a section keeps the page valid and loses no line",
      ok and sorted(new.splitlines()) == sorted(SRC.splitlines()) and new.index('"h-updates"') < new.index('"h-work"'))

keys = [n for n in d.by_id.values() if n.tag in ("dt", "dd") and n.parent.parent.tag == "section"
        and sp._attr(n.parent.parent, "aria-labelledby") == "h-keys"]
pair1, pair2 = [keys[0].eid, keys[1].eid], [keys[2].eid, keys[3].eid]
new, _ = save([{"op": "swap", "a": pair2, "b": pair1}])
check("site: a key and its meaning move together",
      "<dt>Super Return</dt><dd>terminal</dd>\n      <dt>Super Space</dt><dd>apps</dd>" in new and valid(new)[0])

sec = section_of(d, "h-ready")
new, _ = save([{"op": "hide", "ids": [sec]}])
check("site: hiding adds the hidden attribute and nothing else",
      changed_lines(SRC, new) == ['-  <section aria-labelledby="h-ready">', '+  <section aria-labelledby="h-ready" hidden>']
      and valid(new)[0])
again = sp.Document(new)
back = sp.save(new, again.hash, [{"op": "show", "ids": [sec]}], {})[0]
check("site: showing it again gives back the original file", back == SRC)
check("site: a hidden block is served faded, not hidden, to the editor",
      'aria-labelledby="h-ready" data-ce-hidden>' in again.served())

para = d.by_id[by_attr(d, "id", "h-what")].parent.children
first_p = next(c for c in para if isinstance(c, sp.Node) and c.tag == "p")
new, _ = save([{"op": "delete", "ids": [first_p.eid]}])
check("site: deleting a paragraph removes its line and only that",
      len(changed_lines(SRC, new)) == 1 and changed_lines(SRC, new)[0].startswith("-    <p>Lucciola builds") and valid(new)[0])

new, warns = save([{"op": "delete", "ids": [section_of(d, "g-h-apps")]}])
check("site: deleting a guide section warns about the contents link to it",
      valid(new)[0] and any("#g-apps" in w for w in warns), warns)

help_sec = d.by_id[section_of(d, "g-h-help")]
mapping = {n.eid: f"n{i}" for i, n in enumerate([help_sec, *help_sec.elements()], 1)}
new_head = mapping[by_attr(d, "id", "g-h-help")]
new, _ = save([{"op": "duplicate", "ids": [help_sec.eid], "map": mapping}], {new_head: "more help"})
ok, _ = valid(new)
check("site: a duplicated section gets its own names and can be edited",
      ok and 'id="g-help-2" aria-labelledby="g-h-help-2"' in new and '<h2 id="g-h-help-2">more help</h2>' in new
      and new.count('<h2 id="g-h-help">help</h2>') == 1)

try:
    save([{"op": "swap", "a": [section_of(d, "h-what")], "b": [first_p.eid]}])
    check("site: blocks that are not neighbours cannot swap", False)
except sp.EditError:
    check("site: blocks that are not neighbours cannot swap", True)

# ---- welcome window ---------------------------------------------------------------
raw = wc.CONTENT.read_text(encoding="utf-8")
data = json.loads(raw)
check("welcome: the shipped file passes the check", wc.validate(data) == [], wc.validate(data))
check("welcome: the shipped file is in the editor's layout (a save without edits changes nothing)",
      wc.dumps(data) == raw)
check("welcome: the Secure Boot section keeps its condition",
      any(s.get("show_if") == "mok-pending" for s in data["sections"]))

program = (ROOT / "build_files/system_files/usr/libexec/margine/welcome").read_text(encoding="utf-8")
editor_js = (ROOT / "tools/content-editor/ui/editor.js").read_text(encoding="utf-8")
actions_src = program[program.index("const ACTIONS = {"):program.index("};", program.index("const ACTIONS = {"))]
wired = set(re.findall(r'^\s+"([a-z-]+)": \(', actions_src, re.M))
check("welcome: the program and the check know the same button actions", wired == set(wc.ACTIONS), wired)
check("welcome: the program reads the shipped path",
      '"/usr/share/lucciola/welcome/content.json"' in program)
sample = next(b["text"] for s in data["sections"] for b in s["blocks"] if b["type"] == "text")
check("welcome: no text left in the program", sample[:40] not in program and sample[:40] in raw)


def js_regex(src, name):
    m = re.search(rf"const {name} = /(.+)/g;", src)
    return m and m.group(1)


check("welcome: the program, the editor's preview and the check read marks alike",
      js_regex(program, "INLINE") == wc.INLINE.pattern == js_regex(editor_js, "INLINE"),
      (js_regex(program, "INLINE"), wc.INLINE.pattern, js_regex(editor_js, "INLINE")))
para_py = r"\n[ \t]*\n\s*"
check("welcome: the program, the editor's preview and the check split paragraphs alike",
      f"split(/{para_py}/)" in program and f"split(/{para_py}/)" in editor_js
      and f'r"{para_py}"' in (ROOT / "tools/content-editor/welcome_content.py").read_text(encoding="utf-8"))


def rejects(name, mutate, words):
    d2 = copy.deepcopy(data)
    mutate(d2)
    errs = wc.validate(d2)
    check(f"welcome: rejects {name}", any(words in e for e in errs), errs)


def first_block(d2, kind):
    return next(b for s in d2["sections"] for b in s["blocks"] if b["type"] == kind)


rejects("an unknown button action", lambda d2: first_block(d2, "button").update(action="rm-rf"), "action must be")
rejects("a long dash", lambda d2: first_block(d2, "text").update(text=f"a {DASH} b"), "long dash")
rejects("an empty heading", lambda d2: d2["sections"][1].update(title=" "), "heading is empty")
rejects("an unknown field", lambda d2: d2["sections"][0].update(colour="red"), 'unknown field "colour"')
rejects("an id used twice", lambda d2: d2["sections"][1].update(id=d2["sections"][0]["id"]), "used twice")
rejects("a lone ` mark", lambda d2: first_block(d2, "text").update(text="run `this"), "without its pair")
rejects("an unknown condition", lambda d2: d2["sections"][0].update(show_if="sunny"), "show_if")
rejects("a missing bottom", lambda d2: d2.pop("footer"), "Bottom of the window")
rejects("an empty key", lambda d2: first_block(d2, "keys")["rows"][0].update(keys=[["Super", ""]]), "empty key")
rejects("a section with nothing in it", lambda d2: d2["sections"][0].update(blocks=[]), "nothing in it")
rejects("no sections", lambda d2: d2.update(sections=[]), "at least one section")
d3 = copy.deepcopy(data)
d3["sections"][0]["hidden"] = False
first_block(d3, "text")["dim"] = False
first_text = first_block(d3, "text")["text"]
d3["sections"][0]["blocks"][0] = {"dim": False, "text": first_text, "type": "text"}
check("welcome: defaults and key order do not show up as changes",
      wc.dumps(d3).count('"hidden"') == 0 and wc.dumps(d3).count('"dim": false') == 0
      and wc.dumps(d3).index('"type": "text"') < wc.dumps(d3).index(json.dumps(first_text, ensure_ascii=False)[:30]))
d4 = copy.deepcopy(data)
d4["sections"][1]["hidden"] = True
d4["sections"].insert(0, d4["sections"].pop(2))
check("welcome: a hidden and reordered file still passes", wc.validate(d4) == [])

# ---- welcome window: line breaks, bold, links, app buttons -------------------------
check("marks: commands, bold and links split out of the text",
      wc.parse_inline("Run `ujust x y`, then **press Enter** or [read the guide](guide#g-kernel).") == [
          ("text", "Run "), ("code", "ujust x y"), ("text", ", then "), ("bold", "press Enter"),
          ("text", " or "), ("link", "read the guide", "guide#g-kernel"), ("text", ".")])
check("marks: a command keeps its stars and brackets as typed",
      wc.parse_inline("`echo **[x](y)**`") == [("code", "echo **[x](y)**")])
check("marks: a blank line starts a paragraph, newlines at the ends do not count",
      wc.paragraphs("\nOne\ntwo\n\n\n  three\n \nfour\n\n") == ["One\ntwo", "three", "four"])
check("marks: the shipped intro links to a part of the guide that exists",
      ("link", "read more here", "guide#h-what") in wc.parse_inline(data["intro"]) and "h-what" in wc.guide_anchors())
check("marks: the editor's list of guide parts holds only real places",
      wc.guide_sections() and all(wc.link_problem(t, wc.guide_anchors()) is None for t, _ in wc.guide_sections()))
check("marks: the shipped Bazaar button opens Bazaar by its desktop file",
      {"type": "button", "action": "open-app", "app": "io.github.kolunmi.Bazaar.desktop", "label": "Open Bazaar",
       "style": "plain"} in [b for s in data["sections"] for b in s["blocks"]])


def accepts(name, mutate):
    d2 = copy.deepcopy(data)
    mutate(d2)
    errs = wc.validate(d2)
    check(f"welcome: accepts {name}", errs == [], errs)
    return d2


d5 = accepts("line breaks and paragraphs in every long text", lambda d2: (
    d2.update(intro="One line\nand the next.\n\nA paragraph."),
    first_block(d2, "text").update(text="\nA\nB\n\nC\n"),
    first_block(d2, "items")["items"].append("An item\n\nwith two paragraphs."),
    d2["footer"].update(text="Bottom\ntext.")))
check("welcome: line breaks survive a save and a load", json.loads(wc.dumps(d5)) == wc.canonical(d5)
      and json.loads(wc.dumps(d5))["intro"] == "One line\nand the next.\n\nA paragraph.")
accepts("bold, commands and links of every kind", lambda d2: first_block(d2, "items")["items"].append(
    "**Bold**, `ujust x`, [the guide](guide), [a part](guide#g-apps), [Bazaar](app:io.github.kolunmi.Bazaar.desktop), "
    "[a page](https://github.com/daniel-g-carrasco/lucciola/issues)."))
accepts("a button that opens another app", lambda d2: d2["sections"][0]["blocks"].append(
    {"type": "button", "action": "open-app", "app": "org.gnome.Ptyxis.desktop", "label": "Open the terminal"}))
rejects("a link to a file", lambda d2: d2.update(intro="[x](file:///etc/passwd)"), "the window opens only")
rejects("a link to a script", lambda d2: d2.update(intro="[x](javascript:alert)"), "the window opens only")
rejects("a plain http link", lambda d2: d2.update(intro="[x](http://example.org)"), "the window opens only")
rejects("a link to a guide part that does not exist", lambda d2: d2.update(intro="[x](guide#g-nowhere)"),
        "the guide has no such section")
rejects("a link to an app without its desktop file", lambda d2: d2.update(intro="[x](app:bazaar)"), "desktop file")
rejects("a link with no words", lambda d2: d2.update(intro="[](guide)"), "a link with no words")
rejects("a link with no address", lambda d2: d2.update(intro="[here]()"), "no address")
rejects("a lone [", lambda d2: d2.update(intro="read [here(guide)"), "not part of a link")
rejects("a lone ]", lambda d2: d2.update(intro="read here](guide)"), "not part of a link")
rejects("a lone ** mark", lambda d2: d2.update(intro="**bold"), "without its pair")
rejects("a command inside bold", lambda d2: d2.update(intro="**run `x`**"), "inside bold")
rejects("bold inside a link's words", lambda d2: d2.update(intro="[**x**](guide)"), "inside a link")
rejects("a long dash in a link's words", lambda d2: d2.update(intro=f"[a {DASH} b](guide)"), "long dash")
rejects("a link in a heading", lambda d2: d2["sections"][0].update(title="[keys](guide)"), "cannot hold a link")
rejects("bold in a button", lambda d2: first_block(d2, "button").update(label="**Open**"), "cannot be bold")
rejects("a heading on two lines", lambda d2: d2["sections"][0].update(title="the\nkeys"), "cannot break across lines")
rejects("an app button without its app", lambda d2: d2["sections"][0]["blocks"].append(
    {"type": "button", "action": "open-app", "label": "Open"}), '"app" must name')
rejects("an app button with a command for an app", lambda d2: d2["sections"][0]["blocks"].append(
    {"type": "button", "action": "open-app", "app": "sh -c reboot", "label": "Open"}), '"app" must name')
rejects("an app on a button that opens something else", lambda d2: first_block(d2, "button").update(
    app="io.github.kolunmi.Bazaar.desktop") if first_block(d2, "button")["action"] != "open-app" else None,
    "only an open-app button")

guide_open = ROOT / "build_files/system_files/usr/libexec/margine/guide-open"
bad = subprocess.run(["bash", str(guide_open), "g-x;reboot"], capture_output=True, text=True)
check("guide-open: refuses a section name that is not one", bad.returncode == 2 and "not a section name" in bad.stderr)

dashed = [str(f.relative_to(ROOT)) for f in [*(ROOT / "tools/content-editor").rglob("*"), wc.CONTENT]
          if f.is_file() and f.suffix in (".py", ".js", ".css", ".html", ".md", ".json")
          and DASH in f.read_text(encoding="utf-8")]
check("editor: no long dash in the editor's own files or the welcome texts", not dashed, dashed)
check("editor: branch names stay short and plain", serve.slug("Fix the Guide's help, today!") == "fix-the-guide-s")
print("all passed" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
