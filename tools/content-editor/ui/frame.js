// Runs inside the website when the editor shows it (never shipped: the
// server adds it to the page it serves). Texts become editable in place;
// blocks get small controls to move, hide, duplicate and delete them. The
// editor around the page asks for the changes with ce.payload() on save.
(() => {
  const HASH = document.currentScript.dataset.hash;
  const host = window.parent !== window ? window.parent.ceHost : null;
  const page = document.querySelector('.page');
  document.documentElement.classList.add('ce-on');

  // ---- what can be edited, what can be moved ---------------------------
  const TEXT = 'h1, h2, h3, p, li, dt, dd, figcaption, pre, a, button';
  const BLOCKY = 'p, div, ul, ol, dl, section, h1, h2, h3, li, pre, figure, header, nav, footer';
  const BLOCKS = [
    '.view > section', '.view > figure', '.view > .close',
    'section > p', 'section > .cmd', 'section > dl', 'section > ul', 'section > ol', 'section > .term',
    'ul > li', 'ol > li', '.steps > li > p', '.steps > li > .cmd',
    'dl.keys > dt', 'dl.keys > dd', '.term-body > p', '.top > a', 'footer > p',
  ].join(', ');
  const NAMES = [
    ['.view > section', 'section'], ['figure', 'picture'], ['.close', 'closing line'], ['.cmd', 'command'],
    ['dl', 'key list'], ['.steps > li', 'step'], ['dt, dd', 'key'], ['li', 'list item'], ['ul, ol', 'list'],
    ['.term', 'terminal'], ['.top > a', 'link'], ['p', 'paragraph'],
  ];
  const inPage = (el) => page.contains(el) && !el.closest('.screen, script, style, svg');
  const isBlock = (el) => el && el.matches && el.matches(BLOCKS) && inPage(el);
  const nameOf = (el) => (NAMES.find(([s]) => el.matches(s)) || [, 'block'])[1];

  const edited = new Set();
  const undo = [];
  let newId = 0;

  function editable(el) {
    if (!inPage(el) || !el.matches(TEXT)) return false;
    if (el.querySelector('.firefly') || el.querySelector(BLOCKY)) return false;
    if (el.parentElement.closest(TEXT) && editable(el.parentElement.closest(TEXT))) return false;
    return !!el.textContent.trim();
  }

  const plainOnly = (() => {
    const t = document.createElement('div');
    try { t.contentEditable = 'plaintext-only'; } catch { return false; }
    return t.contentEditable === 'plaintext-only';
  })();

  function setup(root) {
    const all = [root, ...root.querySelectorAll(TEXT)].filter((el) => el.matches && el.matches(TEXT));
    for (const el of all) {
      if (!editable(el)) continue;
      el.classList.add('ce-text');
      if (el.tagName === 'BUTTON') continue;        // edited through a small box, see below
      el.contentEditable = plainOnly ? 'plaintext-only' : 'true';
      el.spellcheck = true;
    }
    root.querySelectorAll('.ce-text svg, .ce-text img').forEach((x) => { x.contentEditable = 'false'; });
  }
  setup(page);

  // Firefox stops editing texts whose view was hidden (display: none) when
  // they were made editable: arm them again each time a view appears, and
  // once more on the press that should start the editing.
  const arm = (el) => { const mode = el.contentEditable; el.contentEditable = 'false'; el.contentEditable = mode; };
  document.querySelectorAll('.view').forEach((view) => new MutationObserver(() => {
    if (view.hidden) return;
    setTimeout(() => { void view.offsetHeight; view.querySelectorAll('.ce-text[contenteditable]').forEach(arm); }, 0);
  }).observe(view, { attributes: true, attributeFilter: ['hidden'] }));
  document.addEventListener('mousedown', (e) => {
    const t = e.target.closest && e.target.closest('.ce-text[contenteditable]');
    if (t && document.activeElement !== t && !t.contains(document.activeElement)) { arm(t); t.focus({ preventScroll: true }); }
  }, true);

  // ---- typing ----------------------------------------------------------
  document.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); host && host.save(); return; }
    const t = e.target.closest && e.target.closest('.ce-text');
    if (!t) return;
    if (e.key === 'Enter') e.preventDefault();       // every text is one line in the source
    if ((e.ctrlKey || e.metaKey) && ['b', 'i', 'u'].includes(e.key.toLowerCase())) e.preventDefault();
  }, true);
  document.addEventListener('paste', (e) => {
    const t = e.target.closest && e.target.closest('.ce-text');
    if (!t) return;
    e.preventDefault();
    const text = (e.clipboardData.getData('text/plain') || '').replace(/\s*\n\s*/g, ' ');
    document.execCommand('insertText', false, text);
  }, true);
  document.addEventListener('input', (e) => {
    const t = e.target.closest && e.target.closest('.ce-text');
    if (!t) return;
    markEdited(t);
  });
  function markEdited(t) {
    edited.add(t);
    t.classList.add('ce-edited');
    if (t.textContent.includes('\u2014') && host) host.warnDash(fixDash(t));
    host && host.changed();
  }
  function fixDash(t) {
    return (sep) => {
      const walker = document.createTreeWalker(t, NodeFilter.SHOW_TEXT);
      for (let n = walker.nextNode(); n; n = walker.nextNode()) {
        n.nodeValue = n.nodeValue.replace(/\s*\u2014\s*/g, sep === ':' ? ': ' : ', ');
      }
      markEdited(t);
    };
  }

  // Links and buttons do not navigate or copy here: a click edits them.
  document.addEventListener('click', (e) => {
    const a = e.target.closest('a, button');
    if (!a || !page.contains(a) || a.closest('.ce-bar')) return;
    e.preventDefault();
    if (a.tagName === 'BUTTON') {
      e.stopImmediatePropagation();
      if (a.classList.contains('ce-text')) editButton(a);
    }
  }, true);

  function editButton(b) {
    const box = document.createElement('div');
    box.className = 'ce-pop';
    box.innerHTML = '<label>Button text<input type="text"></label><button type="button">OK</button>';
    const input = box.querySelector('input');
    input.value = b.textContent;
    document.body.appendChild(box);
    const r = b.getBoundingClientRect();
    box.style.left = `${r.left + scrollX}px`;
    box.style.top = `${r.bottom + scrollY + 6}px`;
    input.focus(); input.select();
    const done = (keep) => {
      if (keep && input.value.trim() && input.value !== b.textContent) { b.textContent = input.value; markEdited(b); }
      box.remove();
    };
    box.querySelector('button').addEventListener('click', () => done(true));
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); done(true); }
      if (e.key === 'Escape') done(false);
    });
    input.addEventListener('blur', () => setTimeout(() => box.isConnected && done(true), 150));
  }

  // ---- blocks ------------------------------------------------------------
  const unitOf = (el) => {
    if (el.tagName === 'DD' && el.previousElementSibling && el.previousElementSibling.tagName === 'DT') return [el.previousElementSibling, el];
    if (el.tagName === 'DT' && el.nextElementSibling && el.nextElementSibling.tagName === 'DD') return [el, el.nextElementSibling];
    return [el];
  };
  const ids = (u) => u.map((el) => el.dataset.editId);
  const prevUnit = (u) => { const s = u[0].previousElementSibling; return isBlock(s) ? unitOf(s) : null; };
  const nextUnit = (u) => { const s = u[u.length - 1].nextElementSibling; return isBlock(s) ? unitOf(s) : null; };

  const bar = document.createElement('div');
  bar.className = 'ce-bar';
  bar.innerHTML = `<span class="ce-name"></span>
    <button type="button" data-do="up" title="Move up">↑</button>
    <button type="button" data-do="down" title="Move down">↓</button>
    <button type="button" data-do="hide" title="Hide or show">hide</button>
    <button type="button" data-do="dup" title="Duplicate">copy</button>
    <button type="button" data-do="del" title="Delete">delete</button>`;
  document.body.appendChild(bar);
  let current = null;

  function place(u) {
    current = u;
    document.querySelectorAll('.ce-hover').forEach((x) => x.classList.remove('ce-hover'));
    if (!u) { bar.style.display = 'none'; return; }
    u.forEach((x) => x.classList.add('ce-hover'));
    const r = u[0].getBoundingClientRect();
    const pr = page.getBoundingClientRect();
    const colRight = pr.right - parseFloat(getComputedStyle(page).paddingRight);
    bar.querySelector('.ce-name').textContent = nameOf(u[0]);
    const hidden = u[0].hasAttribute('data-ce-hidden');
    bar.querySelector('[data-do=hide]').textContent = hidden ? 'show' : 'hide';
    bar.querySelector('[data-do=up]').disabled = !prevUnit(u);
    bar.querySelector('[data-do=down]').disabled = !nextUnit(u);
    bar.style.display = 'flex';
    // Beside the column when there is room, so it covers no text; else above the block.
    const w = bar.offsetWidth;
    if (colRight + w + 28 < innerWidth) {
      bar.style.left = `${colRight + 16 + scrollX}px`;
      bar.style.top = `${r.top + scrollY - 4}px`;
    } else {
      const left = Math.min(pr.right - w - 4, Math.max(pr.left + 4, r.right - w));
      bar.style.left = `${left + scrollX}px`;
      bar.style.top = `${Math.max(0, r.top + scrollY - bar.offsetHeight - 4)}px`;
    }
  }
  // Pointing at a block selects it at once. Leaving it for its section or
  // for empty space waits a moment, so the pointer can travel to the bar.
  let pending = 0;
  document.addEventListener('mousemove', (e) => {
    if (bar.contains(e.target)) { clearTimeout(pending); return; }
    let el = e.target.closest ? e.target : null;
    while (el && !isBlock(el)) el = el.parentElement;
    const u = el ? unitOf(el) : null;
    if (u && current && u[0] === current[0]) { clearTimeout(pending); return; }
    clearTimeout(pending);
    if (current && (!u || u[0].contains(current[0]))) pending = setTimeout(() => place(u), 700);
    else place(u);
  });
  addEventListener('scroll', () => current && place(current), { passive: true });

  function record(op, revert) { undo.push({ op, revert }); host && host.changed(); }

  bar.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b || !current) return;
    e.preventDefault(); e.stopPropagation();
    const u = current;
    const what = b.dataset.do;
    if (what === 'up' || what === 'down') {
      const other = what === 'up' ? prevUnit(u) : nextUnit(u);
      if (!other) return;
      const [first, second] = what === 'up' ? [other, u] : [u, other];
      swap(first, second);
      record({ op: 'swap', a: ids(u), b: ids(other) }, () => swap(second, first));
    } else if (what === 'hide') {
      const on = !u[0].hasAttribute('data-ce-hidden');
      const set = (v) => u.forEach((x) => x.toggleAttribute('data-ce-hidden', v));
      set(on);
      record({ op: on ? 'hide' : 'show', ids: ids(u) }, () => set(!on));
    } else if (what === 'dup') {
      const map = {};
      const copies = u.map((x) => x.cloneNode(true));
      copies.forEach((c) => [c, ...c.querySelectorAll('[data-edit-id]')].forEach((n) => {
        const fresh = `n${++newId}`;
        map[n.dataset.editId] = fresh;
        n.dataset.editId = fresh;
        n.classList.remove('ce-hover');
      }));
      // A copy cannot share its names (id) with the original: the server
      // renames them the same way, name-2, name-3...
      const renamed = {};
      copies.forEach((c) => [c, ...c.querySelectorAll('[id]')].filter((n) => n.id).forEach((n) => {
        let k = 2;
        while (document.getElementById(`${n.id}-${k}`) || Object.values(renamed).includes(`${n.id}-${k}`)) k++;
        renamed[n.id] = `${n.id}-${k}`;
        n.id = renamed[n.id];
      }));
      copies.forEach((c) => [c, ...c.querySelectorAll('[aria-labelledby]')].forEach((n) => {
        const ref = n.getAttribute && n.getAttribute('aria-labelledby');
        if (ref && renamed[ref]) n.setAttribute('aria-labelledby', renamed[ref]);
      }));
      const last = u[u.length - 1];
      copies.slice().reverse().forEach((c) => last.after(c));
      copies.forEach((c) => {
        setup(c);
        [c, ...c.querySelectorAll('.ce-text')].filter((t) => t.classList.contains('ce-text')).forEach((t) => edited.add(t));
      });
      record({ op: 'duplicate', ids: ids(u), map }, () => copies.forEach((c) => c.remove()));
    } else if (what === 'del') {
      const anchor = u[u.length - 1].nextSibling;
      const parent = u[0].parentNode;
      u.forEach((x) => x.remove());
      place(null);
      record({ op: 'delete', ids: ids(u) }, () => u.forEach((x) => parent.insertBefore(x, anchor)));
      return;
    }
    place(u);
  });

  function swap(first, second) {
    // second goes in front of first
    const anchor = first[0];
    second.forEach((x) => anchor.parentNode.insertBefore(x, anchor));
  }

  // ---- what the editor asks for --------------------------------------------
  function innerFor(el) {
    const c = el.cloneNode(true);
    c.querySelectorAll('[contenteditable]').forEach((x) => x.removeAttribute('contenteditable'));
    // Firefox keeps a <br> at the end of a text typed over; Enter is off, so no <br> is real.
    c.querySelectorAll('br').forEach((x) => x.remove());
    return c.innerHTML;
  }
  window.ce = {
    hash: HASH,
    dirty: () => undo.length > 0 || edited.size > 0,
    canUndo: () => undo.length > 0,
    undo() {
      const last = undo.pop();
      if (last) last.revert();
      place(null);
      host && host.changed();
    },
    payload() {
      const texts = {};
      for (const el of edited) if (document.contains(el) && el.dataset.editId) texts[el.dataset.editId] = innerFor(el);
      return { hash: HASH, ops: undo.map((u) => u.op), texts };
    },
    hasDash: () => [...edited].some((el) => document.contains(el) && el.textContent.includes('\u2014')),
    fixAllDashes(sep) { [...edited].forEach((el) => fixDash(el)(sep)); },
    view(v) { location.hash = v === 'guide' ? '#guide' : '#home'; },
    currentView: () => { const v = location.hash.slice(1); return v === 'guide' || v.startsWith('g-') ? 'guide' : 'home'; },
  };
  addEventListener('hashchange', () => host && host.changed());
  host && host.ready();
})();
