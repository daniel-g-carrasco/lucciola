# Content editor

Change the texts of the website (`site/index.html`) and of the welcome
window that opens at the first login, and move things around, in the
browser. No HTML, no git: the editor writes the files and, when you ask,
sends them to GitHub as a proposal you can look at before it goes live.

## Use it

1. **Get the repository** (once). In a terminal:

   ```
   gh repo clone daniel-g-carrasco/lucciola ~/lucciola
   ```

   Without the `gh` tool: `git clone https://github.com/daniel-g-carrasco/lucciola.git ~/lucciola`.
   Next times, bring it up to date first: `cd ~/lucciola && git switch main && git pull`.

2. **Start the editor**:

   ```
   cd ~/lucciola && just edit
   ```

   (or `python3 tools/content-editor/serve.py`). The browser opens on
   `http://127.0.0.1:8790/#k=...`; only this computer can reach it, and only
   the page opened with that address (the key changes at each start) can
   save or propose: another program on the computer cannot. The same address
   is printed in the terminal, if the browser tab gets closed. Ctrl+C in the
   terminal stops it.

3. **Edit, save, propose.**
   - **Website**: click any text and type. Point at a block (a section, a
     paragraph, a command, a list item, a key) for its small bar: move up,
     move down, hide, copy, delete. Point at a section's heading to act on
     the whole section. *Undo* takes back the last move, hide, copy or
     delete; Ctrl+Z undoes typing. *Home page* and *Guide* switch between the
     two views. Buttons such as "Copy" open a small box for their text.
   - **Welcome window**: change the fields on the left; the right side shows
     the window. Sections and what is inside them have up, down, hide and
     delete; "Add" puts in a paragraph, a list, key rows or a button.
     A command goes between two `` ` `` marks, like `` `toolbox enter` ``.
     Select words and press *Bold* or *Link* under a field: bold words go
     between `**` marks, a link looks like `[the guide](guide)` and can open
     the guide (from the top or at one of its sections), an app or a web
     page. Enter breaks the line; an empty line starts a new paragraph.
   - **Save** (or Ctrl+S) checks everything first and writes nothing if
     something is wrong; it says what, in plain words.
   - **Show changes** lists what you saved and have not proposed yet.
   - **Propose changes** shows exactly what it will do, then on your click
     puts the saved changes on a new branch `content/<date>-<words>`, sends
     it to GitHub and opens a pull request. Nothing goes to `main`: merge
     the pull request on GitHub when you are happy with it. It needs the
     GitHub command line tool, logged in once with `gh auth login`.

   After a proposal the editor keeps working on its branch: more saves and
   another Propose add to the same pull request. Once it is merged, start
   fresh with `git switch main && git pull`.

One rule the editor watches for: no long dash (the em dash). It offers to
put a colon or a comma instead.

## What it cannot do

- The small desktop picture on the home page, the page title and the
  description for search engines are not editable here.
- Link addresses keep their target; only their words change.
- The welcome window's buttons and links can only open the guide, an
  installed app or an https:// page; anything else needs a change in the
  program.
- Line breaks are for the welcome window only: on the website a new line
  inside a paragraph is not kept.

## How it works

`serve.py` is a small local web server (Python standard library only). It
serves the website with `ui/frame.js` added, which makes the texts editable
and draws the block bar; that addition never reaches the file.

Saving the website does not rewrite the page. `site_patch.py` reads it into
a tree whose pieces are slices of the original text (every tag, every run of
text) and gives each element a number, served as `data-edit-id`. A save
sends the moves, hides, copies and deletes in order, and the new text of
what was typed in; only those slices change, so scripts, styles, comments
and indentation stay byte for byte (a save without edits gives back the
same file, see `tests/content-editor.test.sh`). Inline markup such as
`<code>` and links is kept as it was when only the words change. Hiding
adds the `hidden` attribute.

The welcome window reads `lucciola/system_files/usr/share/lucciola/welcome/content.json`
(in the image: `/usr/share/lucciola/welcome/content.json`).
`welcome_content.py` checks it (also in CI and on the built image) and
writes it back in one stable layout:

```json
{
  "window_title": "Welcome to Lucciola",
  "intro": "...",
  "sections": [
    {"id": "keys", "title": "keys", "blocks": [
      {"type": "text", "text": "...", "dim": true},
      {"type": "keys", "rows": [{"keys": [["Super", "H"], ["Super", "L"]], "label": "..."}]}
    ]},
    {"id": "updates", "title": "updates", "hidden": true, "blocks": [
      {"type": "items", "items": ["...", "..."]},
      {"type": "button", "action": "open-system", "label": "Open Lucciola System", "style": "plain"},
      {"type": "button", "action": "open-app", "app": "io.github.kolunmi.Bazaar.desktop", "label": "Open Bazaar"}
    ]},
    {"id": "secure-boot", "title": "secure boot", "show_if": "mok-pending", "blocks": ["..."]}
  ],
  "footer": {"text": "...", "close_label": "Close"}
}
```

Sections show in file order; `hidden` leaves one out; `show_if:
"mok-pending"` shows one only while the Secure Boot key waits for the blue
screen. Button actions are `open-guide`, `open-system` and `open-app`
(with `app`, the app's desktop file; when it is not installed yet, as on
the first start while the Flatpaks download, the window says so); `style`
is `cta` (beige) or `plain`.

The intro, paragraphs, list items, what keys do and the bottom text may
hold `` `command` ``, `**bold**` and `[words](where)`, where `where` is
`guide`, `guide#<id>` (an id of `site/index.html`, such as `g-kernel` or
`h-what`), `app:<desktop file>` or an `https://` address; `\n` breaks the
line and an empty line starts a paragraph (newlines at the ends do not
count). Headings, button labels and the window title are one plain line.
Run `python3 tools/content-editor/welcome_content.py` to check the file by
hand.
