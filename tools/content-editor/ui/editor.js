// The editor around the two targets: the website (in a frame, edited in
// place by frame.js) and the welcome window (a form with a live preview).
(() => {
  const TOKEN = document.querySelector('meta[name=editor-token]').content;
  const DASH = '\u2014';
  const $ = (s) => document.querySelector(s);
  const frame = $('#frame');
  const ce = () => frame.contentWindow && frame.contentWindow.ce;
  let tab = 'site';
  const FILE_NAMES = { 'site/index.html': 'Website', 'lucciola/system_files/usr/share/lucciola/welcome/content.json': 'Welcome window' };
  const W = { content: null, saved: '', actions: {}, conditions: {}, history: [] };

  // ---- small helpers -----------------------------------------------------
  function h(tag, props = {}, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === 'class') el.className = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
      else if (v === true) el.setAttribute(k, '');
      else if (v !== false && v != null) el.setAttribute(k, v);
    }
    for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid);
    return el;
  }
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  async function api(path, body) {
    const r = await fetch(path, body === undefined ? {} : {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Editor-Token': TOKEN }, body: JSON.stringify(body),
    });
    const data = await r.json().catch(() => ({ error: `The editor's server answered ${r.status}.` }));
    if (!r.ok && !data.error) data.error = `The editor's server answered ${r.status}.`;
    return data;
  }

  // ---- dialogs and the toast -------------------------------------------------
  const dlg = $('#dlg');
  function dialog(title, body, buttons = []) {
    $('#dlg-title').textContent = title;
    $('#dlg-body').replaceChildren(...[body].flat());
    $('#dlg-foot').replaceChildren(...buttons);
    if (!dlg.open) dlg.showModal();
  }
  $('#dlg-x').addEventListener('click', () => dlg.close());
  const closeBtn = (label = 'Close') => h('button', { type: 'button', onclick: () => dlg.close() }, label);

  let toastTimer = 0;
  function toast(text, actions = [], ms = 0) {
    const t = $('#toast');
    clearTimeout(toastTimer);
    t.replaceChildren(h('p', {}, text), ...actions.map(([label, fn]) =>
      h('button', { type: 'button', onclick: () => { t.hidden = true; fn && fn(); } }, label)));
    t.hidden = false;
    if (ms) toastTimer = setTimeout(() => { t.hidden = true; }, ms);
  }
  function warnDash(fix) {
    toast(`That text has a long dash (${DASH}). Lucciola's texts use a colon or a comma instead.`, [
      ['Use a colon', () => fix(':')], ['Use a comma', () => fix(',')], ['Not now', null]]);
  }

  // ---- status, tabs, hint --------------------------------------------------------
  const welcomeDirty = () => W.content && JSON.stringify(W.content) !== W.saved;
  const siteDirty = () => !!(ce() && ce().dirty());
  const HINTS = {
    site: `Click any text to change it. Point at a block for <b>↑ ↓ hide copy delete</b> (point at a heading for its whole section). <b>Ctrl+S</b> saves. Rule: no long dash (${DASH}); use a colon or a comma.`,
    welcome: `Change the fields on the left; the right side shows the window. Put a command between \` marks, like <b>\`toolbox enter\`</b>. <b>Ctrl+S</b> saves. Rule: no long dash (${DASH}); use a colon or a comma.`,
  };
  function changed() {
    const dirty = siteDirty() || welcomeDirty();
    const st = $('#status');
    st.textContent = dirty ? 'Unsaved changes' : 'All saved';
    st.classList.toggle('dirty', dirty);
    $('#undo').disabled = tab === 'site' ? !(ce() && ce().canUndo()) : W.history.length === 0;
    const view = ce() ? ce().currentView() : 'home';
    document.querySelectorAll('[data-view]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.view === view)));
  }
  function showTab(name) {
    tab = name;
    document.querySelectorAll('[data-tab]').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.tab === name)));
    $('#tab-site').hidden = name !== 'site';
    $('#tab-welcome').hidden = name !== 'welcome';
    document.querySelector('.tools [data-view]').parentElement.hidden = name !== 'site';
    $('#hint').innerHTML = HINTS[name];
    changed();
  }
  document.querySelectorAll('[data-tab]').forEach((b) => b.addEventListener('click', () => showTab(b.dataset.tab)));
  document.querySelectorAll('[data-view]').forEach((b) => b.addEventListener('click', () => ce() && ce().view(b.dataset.view)));
  $('#undo').addEventListener('click', () => {
    if (tab === 'site') ce() && ce().undo();
    else if (W.history.length) { W.content = JSON.parse(W.history.pop()); renderWelcome(); }
    changed();
  });

  window.ceHost = { ready: changed, changed, warnDash, save: () => save() };
  addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') { e.preventDefault(); save(); }
  });
  addEventListener('beforeunload', (e) => { if (siteDirty() || welcomeDirty()) { e.preventDefault(); e.returnValue = ''; } });

  // ---- save ------------------------------------------------------------------------
  let saving = false;
  async function save() {
    if (saving) return;
    const sd = siteDirty(), wd = welcomeDirty();
    if (!sd && !wd) { toast('Nothing to save.', [], 1800); return; }
    if (sd && ce().hasDash()) { warnDash((sep) => { ce().fixAllDashes(sep); save(); }); return; }
    if (wd && JSON.stringify(W.content).includes(DASH)) {
      warnDash((sep) => { W.content = JSON.parse(JSON.stringify(W.content).replace(/\s*\u2014\s*/g, sep === ':' ? ': ' : ', ')); renderWelcome(); save(); });
      return;
    }
    saving = true;
    $('#save').disabled = true;
    try {
      const view = ce() ? ce().currentView() : 'home';
      const res = await api('/api/save', { site: sd ? ce().payload() : null, welcome: wd ? W.content : null });
      if (res.error || !res.ok) {
        dialog('Not saved', [
          h('p', { class: 'msg' }, 'Nothing was written. Fix these and save again:'),
          h('ul', { class: 'errors' }, (res.errors || [res.error]).map((e) => h('li', {}, e))),
        ], [closeBtn()]);
        return;
      }
      if (wd) W.saved = JSON.stringify(W.content);
      if (sd) await reloadFrame(view);
      const what = res.saved.length ? `Saved: ${res.saved.map((f) => FILE_NAMES[f] || f).join(' and ')}.` : 'Saved (the files did not change).';
      toast(what, [], 2600);
      if (res.warnings && res.warnings.length) {
        dialog('Saved, with a note', h('ul', { class: 'warns' }, res.warnings.map((w) => h('li', {}, w))), [closeBtn('OK')]);
      }
    } finally {
      saving = false;
      $('#save').disabled = false;
      changed();
    }
  }
  $('#save').addEventListener('click', save);
  function reloadFrame(view) {
    return new Promise((resolve) => {
      frame.addEventListener('load', () => resolve(), { once: true });
      frame.src = `/site?t=${Date.now()}#${view}`;
    });
  }

  // ---- show changes --------------------------------------------------------------
  function wordDiff(a, b) {
    const A = a.split(/(\s+)/), B = b.split(/(\s+)/);
    if (A.length * B.length > 250000) return [esc(a), esc(b)];
    const L = Array.from({ length: A.length + 1 }, () => new Uint16Array(B.length + 1));
    for (let i = A.length - 1; i >= 0; i--) for (let j = B.length - 1; j >= 0; j--)
      L[i][j] = A[i] === B[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
    let i = 0, j = 0, x = '', y = '';
    while (i < A.length && j < B.length) {
      if (A[i] === B[j]) { x += esc(A[i]); y += esc(B[j]); i++; j++; }
      else if (L[i + 1][j] >= L[i][j + 1]) x += `<mark>${esc(A[i++])}</mark>`;
      else y += `<mark>${esc(B[j++])}</mark>`;
    }
    while (i < A.length) x += `<mark>${esc(A[i++])}</mark>`;
    while (j < B.length) y += `<mark>${esc(B[j++])}</mark>`;
    return [x, y];
  }
  const shorten = (s) => (s.length > 300 ? `${s.slice(0, 140)} … ${s.slice(-100)}` : s);
  function renderDiff(text) {
    const files = [];
    let f = null, hunk = null;
    for (const line of text.split('\n')) {
      if (line.startsWith('diff --git ')) { f = { path: line.split(' b/')[1], hunks: [] }; files.push(f); continue; }
      if (!f || line.startsWith('index ') || line.startsWith('--- ') || line.startsWith('+++ ')) continue;
      if (line.startsWith('@@')) { hunk = []; f.hunks.push(hunk); continue; }
      if (hunk && line) hunk.push([line[0], line.slice(1)]);
    }
    return files.map((file) => h('div', { class: 'dfile' },
      h('h3', {}, `${FILE_NAMES[file.path] || 'File'} (${file.path})`),
      file.hunks.map((lines) => {
        const box = h('div', { class: 'dhunk' });
        for (let k = 0; k < lines.length;) {
          if (lines[k][0] === ' ') { box.append(h('div', { class: 'dl ctx' }, shorten(lines[k][1].trim()))); k++; continue; }
          const del = [], add = [];
          while (k < lines.length && lines[k][0] === '-') del.push(lines[k++][1]);
          while (k < lines.length && lines[k][0] === '+') add.push(lines[k++][1]);
          const pairs = Math.min(del.length, add.length);
          const dEl = [], aEl = [];
          del.forEach((d, n) => {
            const [x, y] = n < pairs && del.length === add.length ? wordDiff(d.trim(), add[n].trim()) : [esc(shorten(d.trim())), null];
            const a = h('div', { class: 'dl del' }); a.innerHTML = x; dEl.push(a);
            if (y !== null) { const b = h('div', { class: 'dl add' }); b.innerHTML = y; aEl[n] = b; }
          });
          add.forEach((a, n) => { if (!aEl[n]) { const b = h('div', { class: 'dl add' }); b.innerHTML = esc(shorten(a.trim())); aEl[n] = b; } });
          box.append(...dEl, ...aEl);
        }
        return box;
      })));
  }
  $('#changes').addEventListener('click', async () => {
    const res = await api('/api/diff');
    const body = [];
    if (siteDirty() || welcomeDirty()) body.push(h('p', { class: 'msg' }, 'You have unsaved changes; they show here once saved.'));
    if (res.error) body.push(h('p', { class: 'errors' }, res.error));
    else if (!res.diff.trim()) body.push(h('p', { class: 'msg' }, 'No saved changes yet.'));
    else {
      body.push(h('p', { class: 'note' }, `Saved changes not yet proposed, on branch ${res.branch || '(none)'}. Red: before. Green: after.`));
      body.push(...renderDiff(res.diff));
    }
    dialog('Changes', body, [closeBtn()]);
  });

  // ---- propose -----------------------------------------------------------------------
  $('#propose').addEventListener('click', async () => {
    if (siteDirty() || welcomeDirty()) {
      dialog('Save first', h('p', { class: 'msg' }, 'Propose sends saved changes only. Save, then propose.'), [
        closeBtn('Cancel'),
        h('button', { type: 'button', class: 'primary', onclick: async () => { dlg.close(); await save(); if (!siteDirty() && !welcomeDirty()) $('#propose').click(); } }, 'Save and continue')]);
      return;
    }
    const summary = h('input', { type: 'text', value: 'update texts', maxlength: '72' });
    const planBox = h('div', { class: 'plan' }, h('p', { class: 'note' }, 'Checking…'));
    const go = h('button', { type: 'button', class: 'primary', disabled: true }, 'Propose now');
    let current = null, timer = 0;
    async function refresh() {
      const p = await api('/api/propose/plan', { summary: summary.value });
      current = p;
      const parts = [];
      if (p.error) parts.push(h('p', { class: 'errors' }, p.error));
      if (p.problems && p.problems.length) parts.push(h('ul', { class: 'errors' }, p.problems.map((x) => h('li', {}, x))));
      if (p.notes && p.notes.length) parts.push(h('ul', { class: 'warns' }, p.notes.map((x) => h('li', {}, x))));
      if (p.steps) {
        parts.push(h('p', { class: 'msg' }, `This is exactly what will happen, on branch ${p.branch}. Nothing goes to main: the change waits in a pull request until you merge it on GitHub.`));
        parts.push(h('ol', { class: 'steps' }, p.steps.map((s) => h('li', {}, s.what, h('code', {}, s.command)))));
      }
      planBox.replaceChildren(...parts);
      go.disabled = !p.ok;
    }
    summary.addEventListener('input', () => {
      if (summary.value.includes(DASH)) warnDash((sep) => { summary.value = summary.value.replace(/\s*\u2014\s*/g, sep === ':' ? ': ' : ', '); refresh(); });
      clearTimeout(timer); timer = setTimeout(refresh, 300);
    });
    go.addEventListener('click', async () => {
      go.disabled = true;
      planBox.replaceChildren(h('p', { class: 'note' }, 'Working… (sending to GitHub can take a few seconds)'));
      const r = await api('/api/propose', { summary: summary.value, branch: current && current.branch });
      const out = [];
      (r.log || []).forEach((l) => out.push(h('div', {}, h('span', { class: l.ok ? 'log-ok' : 'log-bad' }, l.ok ? 'done: ' : 'failed: '), l.what,
        l.out ? h('span', { class: 'cmdline' }, l.out) : null)));
      if (r.ok) {
        out.unshift(h('p', { class: 'msg' }, 'Proposed. ', r.url ? h('a', { href: r.url, target: '_blank', rel: 'noopener' }, 'Open the pull request') : 'The pull request is on GitHub.'));
        out.push(h('p', { class: 'note' }, `The editor now works on ${r.branch}: more saves and another Propose add to the same pull request. When it is merged, start fresh with: git switch main && git pull`));
        summary.disabled = true;
      } else {
        out.unshift(h('ul', { class: 'errors' }, (r.errors || [r.error]).map((x) => h('li', {}, x))));
      }
      planBox.replaceChildren(...out);
      changed();
    });
    dialog('Propose changes', [
      h('label', { class: 'field' }, 'Describe the change in a few words (it becomes the title of the proposal)', summary),
      planBox,
    ], [closeBtn('Cancel'), go]);
    refresh();
  });

  // ---- welcome window: form -------------------------------------------------------------
  const keysText = (combos) => combos.map((c) => c.join(' + ')).join(' / ');
  const parseKeys = (text) => text.split(/\s*\/\s*/).map((alt) => alt.split(/\s*\+\s*/).map((k) => k.trim()).filter(Boolean)).filter((c) => c.length);
  function snapshot() { W.history.push(JSON.stringify(W.content)); if (W.history.length > 100) W.history.shift(); }
  function structural(fn) { snapshot(); fn(); renderWelcome(); changed(); }
  function move(list, i, d) { const j = i + d; if (j < 0 || j >= list.length) return; [list[i], list[j]] = [list[j], list[i]]; }

  function bind(el, get, set) {
    el.value = get();
    el.addEventListener('input', () => {
      set(el.value);
      if (el.value.includes(DASH)) warnDash((sep) => { el.value = el.value.replace(/\s*\u2014\s*/g, sep === ':' ? ': ' : ', '); set(el.value); renderPreview(); changed(); });
      renderPreview(); changed();
    });
    return el;
  }
  const text = (get, set, cls) => bind(h('input', { type: 'text', class: cls || '' }), get, set);
  const area = (get, set, rows = 3) => bind(h('textarea', { rows: String(rows) }), get, set);
  const field = (label, control) => h('label', { class: 'field' }, label, control);
  const iconBtn = (label, title, fn, disabled, cls) => h('button', { type: 'button', title, 'aria-label': title, onclick: fn, disabled: !!disabled, class: cls || '' }, label);

  function blockEditor(sec, b, bi) {
    const list = sec.blocks;
    const head = h('div', { class: 'block-head' },
      h('span', { class: 'block-kind' }, { text: 'Paragraph', items: 'List', keys: 'Keys', button: 'Button' }[b.type] || b.type),
      h('div', { class: 'icons' },
        iconBtn('↑', 'Move up', () => structural(() => move(list, bi, -1)), bi === 0),
        iconBtn('↓', 'Move down', () => structural(() => move(list, bi, 1)), bi === list.length - 1),
        iconBtn('✕', 'Delete', () => structural(() => list.splice(bi, 1)), false, 'danger')));
    const box = h('div', { class: 'block' }, head);
    if (b.type === 'text') {
      box.append(area(() => b.text, (v) => { b.text = v; }, Math.min(6, Math.ceil(b.text.length / 70) + 1)));
      const cb = h('input', { type: 'checkbox' }); cb.checked = !!b.dim;
      cb.addEventListener('change', () => structural(() => { if (cb.checked) b.dim = true; else delete b.dim; }));
      box.append(h('label', { class: 'check' }, cb, 'Grey text (less important)'));
    } else if (b.type === 'items') {
      box.append(field('One item per line', area(() => b.items.join('\n'), (v) => { b.items = v.split('\n').map((x) => x.trim()).filter(Boolean); }, Math.max(3, b.items.length * 2))));
    } else if (b.type === 'keys') {
      box.append(h('p', { class: 'note' }, 'Keys joined with +, alternatives with /. Example: Super + H / Super + L'));
      b.rows.forEach((row, ri) => box.append(h('div', { class: 'row' },
        text(() => keysText(row.keys), (v) => { row.keys = parseKeys(v); }),
        text(() => row.label, (v) => { row.label = v; }),
        h('div', { class: 'icons' },
          iconBtn('↑', 'Move up', () => structural(() => move(b.rows, ri, -1)), ri === 0),
          iconBtn('↓', 'Move down', () => structural(() => move(b.rows, ri, 1)), ri === b.rows.length - 1),
          iconBtn('✕', 'Delete this key', () => structural(() => b.rows.splice(ri, 1)), false, 'danger')))));
      box.append(h('div', { class: 'adds' }, h('button', { type: 'button', onclick: () => structural(() => b.rows.push({ keys: [['Super', 'X']], label: 'what it does' })) }, '+ key')));
    } else if (b.type === 'button') {
      box.append(h('div', { class: 'row' },
        text(() => b.label, (v) => { b.label = v; }),
        h('span', { class: 'note' }, (W.actions[b.action] || b.action).replace(/^./, (c) => c.toUpperCase())),
        h('span')));
      const cb = h('input', { type: 'checkbox' }); cb.checked = b.style === 'cta';
      cb.addEventListener('change', () => structural(() => { b.style = cb.checked ? 'cta' : 'plain'; }));
      box.append(h('label', { class: 'check' }, cb, 'Highlighted (beige) button'));
    }
    return box;
  }

  function sectionCard(sec, si) {
    const secs = W.content.sections;
    const card = h('div', { class: `card${sec.hidden ? ' hidden-sec' : ''}` });
    card.append(h('div', { class: 'card-head' },
      h('label', { class: 'field grow' }, `Section ${si + 1}: heading`, text(() => sec.title, (v) => { sec.title = v; }, 'heading')),
      h('div', { class: 'icons' },
        iconBtn('↑', 'Move the section up', () => structural(() => move(secs, si, -1)), si === 0),
        iconBtn('↓', 'Move the section down', () => structural(() => move(secs, si, 1)), si === secs.length - 1),
        iconBtn(sec.hidden ? 'show' : 'hide', sec.hidden ? 'Show this section' : 'Hide this section', () => structural(() => { if (sec.hidden) delete sec.hidden; else sec.hidden = true; })),
        iconBtn('delete', 'Delete this section', () => structural(() => secs.splice(si, 1)), false, 'danger'))));
    if (sec.show_if) card.append(h('p', { class: 'badge' }, `Appears only when needed: ${W.conditions[sec.show_if] || sec.show_if}.`));
    if (sec.hidden) card.append(h('p', { class: 'badge' }, 'Hidden: not shown in the window.'));
    sec.blocks.forEach((b, bi) => card.append(blockEditor(sec, b, bi)));
    const actionSel = h('select', {}, Object.entries(W.actions).map(([k, v]) => h('option', { value: k }, v)));
    card.append(h('div', { class: 'adds' }, 'Add:',
      h('button', { type: 'button', onclick: () => structural(() => sec.blocks.push({ type: 'text', text: 'New paragraph.' })) }, '+ paragraph'),
      h('button', { type: 'button', onclick: () => structural(() => sec.blocks.push({ type: 'items', items: ['First item.', 'Second item.'] })) }, '+ list'),
      h('button', { type: 'button', onclick: () => structural(() => sec.blocks.push({ type: 'keys', rows: [{ keys: [['Super', 'X']], label: 'what it does' }] })) }, '+ keys'),
      h('button', { type: 'button', onclick: () => structural(() => sec.blocks.push({ type: 'button', action: actionSel.value, label: 'Open', style: 'plain' })) }, '+ button that'),
      actionSel));
    return card;
  }

  function renderForm() {
    const c = W.content;
    const form = $('#wform');
    const y = form.scrollTop;
    form.replaceChildren(
      h('div', { class: 'card' }, h('h3', {}, 'Top of the window'),
        field('Window title', text(() => c.window_title, (v) => { c.window_title = v; })),
        field('Intro, under the name', area(() => c.intro, (v) => { c.intro = v; }, 2))),
      ...c.sections.map(sectionCard),
      h('div', { class: 'adds' }, h('button', { type: 'button', onclick: () => structural(() => {
        let n = c.sections.length + 1;
        while (c.sections.some((s) => s.id === `section-${n}`)) n++;
        c.sections.push({ id: `section-${n}`, title: 'new section', blocks: [{ type: 'text', text: 'New paragraph.' }] });
      }) }, '+ section')),
      h('div', { class: 'card' }, h('h3', {}, 'Bottom of the window'),
        field('Text', area(() => c.footer.text, (v) => { c.footer.text = v; }, 2)),
        field('Close button', text(() => c.footer.close_label, (v) => { c.footer.close_label = v; }))));
    form.scrollTop = y;
  }

  // ---- welcome window: preview ---------------------------------------------------------
  const md = (s) => esc(s).replace(/`([^`]+)`/g, '<span class="g-cmd">$1</span>');
  function renderPreview() {
    const c = W.content;
    const parts = [`<div class="g-hero"><div class="g-word">lucciola<i></i></div><p class="g-lede">${md(c.intro)}</p></div>`];
    for (const sec of c.sections) {
      const cls = ['g-sec', sec.hidden ? 'g-off' : '', sec.show_if ? 'g-cond' : ''].join(' ');
      const tag = sec.hidden ? '<small>hidden</small>' : sec.show_if ? '<small>only when needed</small>' : '';
      const blocks = sec.blocks.map((b) => {
        if (b.type === 'text') return `<p class="g-p${b.dim ? ' g-dim' : ''}">${md(b.text)}</p>`;
        if (b.type === 'items') return `<ul class="g-list">${b.items.map((i) => `<li><span>${md(i)}</span></li>`).join('')}</ul>`;
        if (b.type === 'keys') return `<div class="g-keys">${b.rows.map((r) => `<div class="g-caps">${r.keys.map((combo) =>
          combo.map((k) => `<span class="g-cap">${esc(k)}</span>`).join('')).join('<span class="g-sep">/</span>')}</div><div>${md(r.label)}</div>`).join('')}</div>`;
        if (b.type === 'button') return `<span class="g-btn${b.style === 'cta' ? ' cta' : ''}">${esc(b.label)}</span>`;
        return '';
      }).join('');
      parts.push(`<div class="${cls}"><p class="g-h">${md(sec.title)}${tag}</p>${blocks}</div>`);
    }
    parts.push(`<div class="g-foot"><hr><div><p>${md(c.footer.text)}</p><span class="g-btn">${esc(c.footer.close_label)}</span></div></div>`);
    $('#wpreview').innerHTML = parts.join('');
  }
  function renderWelcome() { renderForm(); renderPreview(); }

  async function loadWelcome() {
    const res = await api('/api/welcome');
    if (res.error) { $('#wform').replaceChildren(h('p', { class: 'errors' }, res.error)); return; }
    W.content = res.content; W.actions = res.actions; W.conditions = res.conditions;
    W.saved = JSON.stringify(W.content); W.history = [];
    renderWelcome();
    changed();
  }

  frame.addEventListener('load', changed);
  showTab(location.hash === '#welcome' ? 'welcome' : 'site');
  loadWelcome();
})();
