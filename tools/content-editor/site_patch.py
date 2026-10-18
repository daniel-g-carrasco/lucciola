"""Edit site/index.html without rewriting it.

The page is parsed into a tree whose every piece is a slice of the original
text: a start tag, an end tag, a run of text. Writing the tree back joins the
slices, so an untouched file comes back byte for byte, and an edit changes
only the slices it touches. Scripts, styles, comments, indentation and the
long inline images never pass through a serializer.

The editor addresses elements by number: data-edit-id="N", given in document
order to every element inside <body> when the page is served (and only
then; the attribute never reaches the file). A save sends the structural
operations in the order they were made, then the new inner HTML of every
text that was typed in.
"""

import hashlib
import html
import re
from html.parser import HTMLParser

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr"}
# Inline markup a text may keep or gain: links, code, emphasis, keys.
INLINE_OK = {"a", "b", "br", "code", "em", "i", "kbd", "small", "span", "strong"}
INLINE_ATTRS = {"a": {"href"}, "span": {"class", "aria-hidden"}}
EDITOR_ATTR = re.compile(r'\s+data-edit-id="[^"]*"|\s+data-ce-[a-z-]+(="[^"]*")?|\s+contenteditable(="[^"]*")?')
EM_DASH = "\u2014"


class EditError(Exception):
    """A save that cannot be applied; the message is for the person editing."""


class Node:
    __slots__ = ("tag", "attrs", "start", "end", "children", "parent", "eid")

    def __init__(self, tag, attrs, start, parent):
        self.tag, self.attrs, self.start, self.end = tag, attrs, start, ""
        self.children, self.parent, self.eid = [], parent, None

    def html(self):
        return self.start + "".join(c if isinstance(c, str) else c.html() for c in self.children) + self.end

    def inner(self):
        return "".join(c if isinstance(c, str) else c.html() for c in self.children)

    def elements(self):
        for c in self.children:
            if isinstance(c, Node):
                yield c
                yield from c.elements()


class _Events(HTMLParser):
    """Every construct of the source with the offset where it starts."""

    def __init__(self, src):
        super().__init__(convert_charrefs=False)
        self._lines = [0] + [m.end() for m in re.finditer("\n", src)]
        self.events = []

    def _at(self, kind, tag=None, attrs=None):
        line, col = self.getpos()
        self.events.append((self._lines[line - 1] + col, kind, tag, attrs))

    def handle_starttag(self, tag, attrs):
        self._at("start", tag, attrs)

    def handle_startendtag(self, tag, attrs):
        self._at("void", tag, attrs)

    def handle_endtag(self, tag):
        self._at("end", tag)

    def handle_data(self, data):
        self._at("text")

    handle_comment = handle_decl = handle_pi = handle_entityref = handle_charref = handle_data
    unknown_decl = handle_data


def _slices(src):
    p = _Events(src)
    p.feed(src)
    p.close()
    ev = p.events
    out = []
    for i, (off, kind, tag, attrs) in enumerate(ev):
        nxt = ev[i + 1][0] if i + 1 < len(ev) else len(src)
        if nxt < off:
            raise EditError("The page could not be read (the parser went backwards).")
        out.append((src[off:nxt], kind, tag, attrs))
    if (ev and ev[0][0] != 0) or "".join(s for s, *_ in out) != src:
        raise EditError("The page could not be read back exactly.")
    return out


class Document:
    """The page as a tree of source slices; problems lists what is not well formed."""

    def __init__(self, src):
        self.src = src
        self.hash = hashlib.sha256(src.encode("utf-8")).hexdigest()
        self.root = Node("#root", [], "", None)
        self.problems = []
        stack = [self.root]
        for raw, kind, tag, attrs in _slices(src):
            top = stack[-1]
            if kind in ("start", "void"):
                if kind == "start" and not raw.startswith("<"):
                    raise EditError("The page could not be read (a tag is out of place).")
                node = Node(tag, attrs or [], raw, top)
                top.children.append(node)
                if kind == "start" and tag not in VOID:
                    stack.append(node)
            elif kind == "end":
                if any(n.tag == tag for n in stack[1:]):
                    while stack[-1].tag != tag:
                        self.problems.append(f"<{stack[-1].tag}> is not closed")
                        stack.pop()
                    stack.pop().end = raw
                else:
                    top.children.append(raw)
            else:
                top.children.append(raw)
        for n in stack[1:]:
            self.problems.append(f"<{n.tag}> is not closed")
        self.by_id = {}
        body = next((n for n in self.root.elements() if n.tag == "body"), None)
        if body is None:
            raise EditError("The page has no <body>.")
        for i, n in enumerate(body.elements(), 1):
            n.eid = str(i)
            self.by_id[n.eid] = n

    def html(self):
        return self.root.html()

    # ---- serving -------------------------------------------------------
    def served(self):
        """The page with data-edit-id on every body element.

        A hidden element (other than the two views) is served with
        data-ce-hidden instead of hidden, so the editor can show it faded
        and bring it back.
        """
        def walk(node):
            parts = []
            for c in node.children:
                if isinstance(c, str):
                    parts.append(c)
                    continue
                start = c.start
                if c.eid:
                    start = re.sub(r"^<([A-Za-z][\w:-]*)", lambda m: f'{m.group(0)} data-edit-id="{c.eid}"', start, count=1)
                    if _has_attr(c, "hidden") and "view" not in _attr(c, "class", "").split():
                        start = _set_hidden(start, False).rstrip(">").rstrip("/").rstrip() + " data-ce-hidden>"
                parts.append(start + walk(c) + c.end)
            return "".join(parts)
        return walk(self.root)

    # ---- edits ---------------------------------------------------------
    def node(self, eid):
        n = self.by_id.get(str(eid))
        if n is None:
            raise EditError("The editor and the file disagree about the page. Reload and make the change again.")
        return n

    def unit(self, ids):
        """Adjacent siblings acted on together (a key and its meaning)."""
        nodes = [self.node(i) for i in ids]
        parent = nodes[0].parent
        if parent is None or any(n.parent is not parent for n in nodes):
            raise EditError("These blocks do not sit together on the page.")
        idx = sorted(parent.children.index(n) for n in nodes)
        return parent, idx[0], idx[-1]

    def apply(self, ops, texts):
        for op in ops:
            kind = op.get("op")
            if kind == "swap":
                pa, a0, a1 = self.unit(op["a"])
                pb, b0, b1 = self.unit(op["b"])
                if pa is not pb:
                    raise EditError("A block can only move among its neighbours.")
                if a0 > b0:
                    a0, a1, b0, b1 = b0, b1, a0, a1
                if a1 >= b0:
                    raise EditError("Two blocks overlap.")
                ch = pa.children
                pa.children = ch[:a0] + ch[b0:b1 + 1] + ch[a1 + 1:b0] + ch[a0:a1 + 1] + ch[b1 + 1:]
            elif kind in ("hide", "show"):
                for i in op["ids"]:
                    n = self.node(i)
                    n.start = _set_hidden(n.start, kind == "hide")
            elif kind == "delete":
                parent, i0, i1 = self.unit(op["ids"])
                if i0 > 0 and _blank(parent.children[i0 - 1]):
                    i0 -= 1
                del parent.children[i0:i1 + 1]
            elif kind == "duplicate":
                parent, i0, i1 = self.unit(op["ids"])
                lead = [parent.children[i0 - 1]] if i0 > 0 and _blank(parent.children[i0 - 1]) else []
                mapping = {str(k): str(v) for k, v in op.get("map", {}).items()}
                copies = [_copy(c, parent, mapping, self.by_id) for c in parent.children[i0:i1 + 1]]
                self._rename_ids(copies)
                parent.children[i1 + 1:i1 + 1] = lead + copies
            else:
                raise EditError(f"Unknown change \"{kind}\".")
        for eid, new_inner in texts.items():
            node = self.node(eid)
            if _attached(node, self.root):
                node.children = _merge_text(node.inner(), new_inner)

    def _rename_ids(self, copies):
        taken = {v for n in self.root.elements() for k, v in n.attrs if k == "id"}
        renamed = {}
        for top in copies:
            if not isinstance(top, Node):
                continue
            for n in [top, *top.elements()]:
                old = _attr(n, "id")
                if old is None:
                    continue
                k = 2
                while f"{old}-{k}" in taken:
                    k += 1
                new = f"{old}-{k}"
                taken.add(new)
                renamed[old] = new
                n.start = _replace_attr(n.start, "id", new)
                n.attrs = [(a, new if a == "id" else v) for a, v in n.attrs]
            for n in [top, *top.elements()]:
                ref = _attr(n, "aria-labelledby")
                if ref in renamed:
                    n.start = _replace_attr(n.start, "aria-labelledby", renamed[ref])


def _blank(c):
    return isinstance(c, str) and not c.strip()


def _attached(node, root):
    while node.parent is not None:
        if node not in node.parent.children:
            return False
        node = node.parent
    return node is root


def _copy(c, parent, mapping, by_id):
    if isinstance(c, str):
        return c
    n = Node(c.tag, list(c.attrs), c.start, parent)
    n.end = c.end
    if c.eid in mapping:
        n.eid = mapping[c.eid]
        by_id[n.eid] = n
    n.children = [_copy(x, n, mapping, by_id) for x in c.children]
    return n


def _attr(node, name, default=None):
    for k, v in node.attrs:
        if k == name:
            return v if v is not None else ""
    return default


def _has_attr(node, name):
    return any(k == name for k, _ in node.attrs)


_HIDDEN = re.compile(r"\s+hidden(\s*=\s*(\"[^\"]*\"|'[^']*'|[^\s>]+))?(?=[\s/>])")


def _set_hidden(start, on):
    has = bool(_HIDDEN.search(start))
    if on and not has:
        m = re.search(r"\s*/?>$", start)
        return start[:m.start()] + " hidden" + start[m.start():]
    if not on and has:
        return _HIDDEN.sub("", start, count=1)
    return start


def _replace_attr(start, name, value):
    pat = re.compile(r"(\s" + re.escape(name) + r"\s*=\s*)(\"[^\"]*\"|'[^']*'|[^\s>]+)")
    return pat.sub(lambda m: m.group(1) + '"' + html.escape(value) + '"', start, count=1)


# ---- text edits ---------------------------------------------------------

class _Frag(HTMLParser):
    """A text's inner HTML as ("text", raw) and ("tag", raw, kind, name, attrs)."""

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.tokens = []

    def handle_starttag(self, tag, attrs):
        self.tokens.append(("tag", self.get_starttag_text(), "start", tag, attrs))

    def handle_startendtag(self, tag, attrs):
        self.tokens.append(("tag", self.get_starttag_text(), "start", tag, attrs))

    def handle_endtag(self, tag):
        self.tokens.append(("tag", f"</{tag}>", "end", tag, None))

    def handle_data(self, data):
        self._text(data)

    def handle_entityref(self, name):
        self._text(f"&{name};")

    def handle_charref(self, name):
        self._text(f"&#{name};")

    def handle_comment(self, data):
        self.tokens.append(("tag", f"<!--{data}-->", "comment", "#comment", None))

    def _text(self, raw):
        if self.tokens and self.tokens[-1][0] == "text":
            self.tokens[-1] = ("text", self.tokens[-1][1] + raw)
        else:
            self.tokens.append(("text", raw))


def _tokens(fragment):
    p = _Frag()
    p.feed(fragment)
    p.close()
    return p.tokens


def _escape(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _new_text(old_raw, new_raw):
    """The text to write: the old slice when the words are the same."""
    old, new = html.unescape(old_raw), html.unescape(new_raw)
    if "\u00a0" not in old:
        new = new.replace("\u00a0", " ")
    if old == new:
        return old_raw
    return _escape(new)


def _skeleton(tokens):
    return [(t[2], t[3]) for t in tokens if t[0] == "tag"]


def _merge_text(old_inner, new_inner):
    """New children for an edited element, as source slices.

    Same tags in the same order (the usual case: only words changed): the
    original tags are kept byte for byte and only the changed runs of text
    are rewritten. Otherwise the new text is cleaned to plain text plus a few
    inline tags; a picture or other markup the old text had and the new one
    lost is refused rather than dropped.
    """
    old_t, new_t = _tokens(old_inner), _tokens(EDITOR_ATTR.sub("", new_inner))
    if not any(t[0] == "tag" and t[3] == "br" for t in old_t):
        # A browser's placeholder <br>, never typed: the editor turns Enter off.
        new_t = [t for t in new_t if not (t[0] == "tag" and t[3] == "br")]
        merged = []
        for t in new_t:
            if t[0] == "text" and merged and merged[-1][0] == "text":
                merged[-1] = ("text", merged[-1][1] + t[1])
            else:
                merged.append(t)
        new_t = merged
    # Leading/trailing runs of text may be missing on one side.
    if _skeleton(old_t) == _skeleton(new_t):
        out, ni = [], 0
        new_texts = [t for t in new_t if t[0] == "text"]
        old_texts = [t for t in old_t if t[0] == "text"]
        if len(new_texts) == len(old_texts) and [t[0] for t in old_t] == [t[0] for t in new_t]:
            for t in old_t:
                if t[0] == "tag":
                    out.append(t[1])
                else:
                    out.append(_new_text(t[1], new_texts[ni][1]))
                    ni += 1
            return ["".join(out)]
        # Same tags, a text run appeared or vanished: walk both in step.
        out, oi = [], 0
        old_tags = [t for t in old_t if t[0] == "tag"]
        for t in new_t:
            if t[0] == "tag":
                out.append(old_tags[oi][1])
                oi += 1
            else:
                out.append(_escape(html.unescape(t[1]).replace("\u00a0", " ")))
        return ["".join(out)]
    lost = {n for kind, n in _skeleton(old_t) if n not in INLINE_OK and n != "#comment"} - \
        {n for kind, n in _skeleton(new_t)}
    if lost:
        raise EditError("A text lost a picture or a special part (" + ", ".join(sorted(lost)) +
                        "). Undo that change with Ctrl+Z and change only the words.")
    out = []
    for t in new_t:
        if t[0] == "text":
            out.append(_escape(html.unescape(t[1]).replace("\u00a0", " ")))
        elif t[3] in INLINE_OK:
            if t[2] == "end":
                out.append(t[1])
            else:
                keep = INLINE_ATTRS.get(t[3], set())
                attrs = "".join(f' {k}="{html.escape(v or "", quote=True)}"' for k, v in t[4] if k in keep)
                out.append(f"<{t[3]}{attrs}>")
    return ["".join(out)]


# ---- checks -------------------------------------------------------------

def check(src):
    """(errors, warnings) for a page about to be written."""
    errors, warnings = [], []
    try:
        doc = Document(src)
    except EditError as e:
        return [str(e)], []
    errors += [f"The page is not well formed: {p}." for p in doc.problems]
    ids = {}
    for n in doc.root.elements():
        i = _attr(n, "id")
        if i is not None:
            ids[i] = ids.get(i, 0) + 1
    errors += [f"Two elements share the name \"{i}\"." for i, k in ids.items() if k > 1]
    for n in doc.root.elements():
        href = _attr(n, "href") or ""
        if n.tag == "a" and href.startswith("#") and len(href) > 1 and href[1:] not in ids \
                and href[1:] not in ("home", "guide"):
            warnings.append(f"A link points to \"{href}\", which is no longer on the page.")
    return errors, warnings


def em_dash_in(texts):
    return any(EM_DASH in html.unescape(v) for v in texts.values())


def save(src, served_hash, ops, texts):
    """Apply a save from the editor to the source; returns (new_src, warnings)."""
    doc = Document(src)
    if served_hash != doc.hash:
        raise EditError("The page changed on disk after the editor opened it. "
                        "Reload the editor (your unsaved changes will be lost) and make them again.")
    if em_dash_in(texts):
        raise EditError("A text has a long dash (\u2014). Use a colon or a comma instead.")
    doc.apply(ops, texts)
    new = doc.html()
    errors, warnings = check(new)
    if errors:
        raise EditError(" ".join(errors))
    return new, warnings
