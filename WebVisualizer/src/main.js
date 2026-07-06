import './style.css'
import mockDiffs from '../mockDiffs.json'

/* ------------------------------------------------------------------ *
 * DProvenance Diff Explorer
 * Renders one already-diffed reasoning tree (summary + metrics +
 * timeline + color-coded collapsible tree) from a DPK diff export.
 * Framework-free. The loaded document is the mock today; the "Load
 * JSON" button accepts any file with the same shape (see SCHEMA.md).
 * ------------------------------------------------------------------ */

const TYPES = ['added', 'removed', 'changed', 'unchanged']

const state = {
  data: mockDiffs,
  search: '',
  types: new Set(TYPES),
  collapsed: new Set(),
}

const app = document.querySelector('#app')

/* --- helpers --------------------------------------------------------- */

const esc = (s) =>
  String(s).replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])
  )

function highlight(label, term) {
  if (!term) return esc(label)
  const i = label.toLowerCase().indexOf(term.toLowerCase())
  if (i < 0) return esc(label)
  return (
    esc(label.slice(0, i)) +
    '<mark>' +
    esc(label.slice(i, i + term.length)) +
    '</mark>' +
    esc(label.slice(i + term.length))
  )
}

function countByType(node, acc = { added: 0, removed: 0, changed: 0, unchanged: 0 }) {
  if (acc[node.type] !== undefined) acc[node.type]++
  ;(node.children || []).forEach((c) => countByType(c, acc))
  return acc
}

function collectIds(node, withChildrenOnly, out = []) {
  if (!withChildrenOnly || (node.children && node.children.length)) out.push(node.id)
  ;(node.children || []).forEach((c) => collectIds(c, withChildrenOnly, out))
  return out
}

/* A node is "self-visible" if its type is active AND it matches the search.
 * A node is rendered if it is self-visible OR has a visible descendant
 * (kept as dimmed context so the tree stays a coherent path). */
function selfVisible(node) {
  if (!state.types.has(node.type)) return false
  if (!state.search) return true
  return node.label.toLowerCase().includes(state.search.toLowerCase())
}
function visible(node) {
  if (selfVisible(node)) return true
  return (node.children || []).some(visible)
}

/* --- rendering ------------------------------------------------------- */

function renderNode(node, depth = 0) {
  if (!visible(node)) return ''

  const kids = (node.children || []).filter(visible)
  const hasKids = kids.length > 0
  // when searching we force-expand so matches are never hidden
  const collapsed = !state.search && state.collapsed.has(node.id)
  const ctx = selfVisible(node) ? '' : ' ctx'

  const caret = hasKids
    ? `<button class="caret" data-toggle="${esc(node.id)}" aria-label="toggle">▾</button>`
    : `<span class="caret leaf">▾</span>`

  const badge = `<span class="badge">${node.type}</span>`

  const delta =
    node.type === 'changed' && node.details
      ? `<span class="delta"><span class="from">${esc(node.details.runA ?? '—')}</span>` +
        `<span class="arrow">→</span><span class="to">${esc(node.details.runB ?? '—')}</span></span>`
      : ''

  const childHtml = hasKids
    ? `<div class="children">${kids.map((c) => renderNode(c, depth + 1)).join('')}</div>`
    : ''

  return (
    `<div class="node t-${esc(node.type)}${collapsed ? ' collapsed' : ''}" data-id="${esc(node.id)}">` +
    `<div class="row${ctx}" style="--i:${depth}">` +
    caret +
    `<span class="dot"></span>` +
    `<span class="label">${highlight(node.label, state.search)}</span>` +
    badge +
    delta +
    `<span class="nid">${esc(node.id)}</span>` +
    `</div>` +
    childHtml +
    `</div>`
  )
}

function paintTree() {
  const root = document.querySelector('#tree')
  const html = renderNode(state.data.tree)
  root.innerHTML =
    html ||
    `<div class="tree-empty">No nodes match the current filter.</div>`

  // refresh live chip counts + pressed state
  const counts = countByType(state.data.tree)
  document.querySelectorAll('.chip').forEach((chip) => {
    const t = chip.dataset.type
    chip.querySelector('.n').textContent = counts[t] ?? 0
    chip.setAttribute('aria-pressed', String(state.types.has(t)))
  })
}

function metricsHtml() {
  const { summary, metrics } = state.data
  const risk = (summary?.regressionRisk || metrics?.risk || 'unknown').toLowerCase()
  const live = countByType(state.data.tree)
  return `
    <div class="metric risk-${esc(risk)}" style="--i:0">
      <span class="k eyebrow">Regression risk</span>
      <span class="risk-pill ${esc(risk)}">${esc(summary?.regressionRisk || metrics?.risk || '—')}</span>
      <div class="sub">structural + semantic alignment</div>
    </div>
    <div class="metric" style="--i:1">
      <span class="k eyebrow">Drift score</span>
      <span class="v">${esc(metrics?.driftScore ?? '—')}</span>
      <div class="meter"><span style="width:${Math.min(100, Number(metrics?.driftScore) || 0)}%"></span></div>
    </div>
    <div class="metric" style="--i:2">
      <span class="k eyebrow">Node changes</span>
      <div class="countset">
        <span class="c added">+${live.added}</span>
        <span class="c removed">−${live.removed}</span>
        <span class="c changed">~${live.changed}</span>
      </div>
      <div class="sub">added · removed · changed</div>
    </div>
    <div class="metric" style="--i:3">
      <span class="k eyebrow">Changed paths</span>
      <span class="v">${esc(summary?.changedLogicPaths ?? metrics?.changedPaths ?? '—')}</span>
      <div class="sub">logic paths affected</div>
    </div>
    <div class="metric" style="--i:4">
      <span class="k eyebrow">Runs analyzed</span>
      <span class="v">${esc(summary?.runs ?? '—')}</span>
      <div class="sub">in this corpus</div>
    </div>`
}

function timelineHtml() {
  const t = state.data.timeline || {}
  const a = t.runA || {}
  const b = t.runB || {}
  return `
    <div class="run a">
      <span class="rtag">baseline</span>
      <span class="rlabel">${esc(a.label || 'Run A')}</span>
      <span class="rdate">${esc(a.date || '')}</span>
    </div>
    <div class="tl-connector"><span class="pulse"></span></div>
    <div class="run b">
      <span class="rtag">candidate</span>
      <span class="rlabel">${esc(b.label || 'Run B')}</span>
      <span class="rdate">${esc(b.date || '')}</span>
    </div>`
}

function chipsHtml() {
  return TYPES.map(
    (t) => `
    <button class="chip" data-type="${t}" aria-pressed="true">
      <span class="swatch"></span>${t[0].toUpperCase() + t.slice(1)}
      <span class="n">0</span>
    </button>`
  ).join('')
}

function buildShell() {
  const fp = state.data.summary?.structuralFingerprint
  app.innerHTML = `
    <header class="cmdbar">
      <div class="brand">
        <h1><span class="accent-tick">◆</span> DProvenance <span class="dim">/ diff</span></h1>
        <span class="eyebrow">reasoning-trace regression explorer</span>
      </div>
      ${fp ? `<div class="fingerprint">fingerprint <b>${esc(fp)}</b></div>` : ''}
      <button class="btn" id="load-btn">Load JSON</button>
      <input id="file" type="file" accept="application/json,.json" hidden />
    </header>

    <section class="metrics">${metricsHtml()}</section>

    <section class="timeline">${timelineHtml()}</section>

    <div class="toolbar">
      <label class="search">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
          <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
        </svg>
        <input id="search" type="text" placeholder="filter by label…" autocomplete="off" spellcheck="false" />
      </label>
      <div class="chips">${chipsHtml()}</div>
      <button class="tool-btn" id="expand-all">Expand all</button>
      <button class="tool-btn" id="collapse-all">Collapse all</button>
    </div>

    <div class="treewrap"><div class="tree" id="tree"></div></div>

    <p class="footnote">
      Loaded document is <code>mockDiffs.json</code>. This viewer consumes a DPK diff
      export — see <code>SCHEMA.md</code> for the shape the Swift side must emit.
    </p>`

  wire()
  paintTree()
}

/* --- events ---------------------------------------------------------- */

function wire() {
  // search (input is not recreated, so focus is preserved)
  document.querySelector('#search').addEventListener('input', (e) => {
    state.search = e.target.value.trim()
    paintTree()
  })

  // type filter chips
  document.querySelector('.chips').addEventListener('click', (e) => {
    const chip = e.target.closest('.chip')
    if (!chip) return
    const t = chip.dataset.type
    if (state.types.has(t)) state.types.delete(t)
    else state.types.add(t)
    paintTree()
  })

  // expand / collapse all
  document.querySelector('#expand-all').addEventListener('click', () => {
    state.collapsed.clear()
    paintTree()
  })
  document.querySelector('#collapse-all').addEventListener('click', () => {
    collectIds(state.data.tree, true).forEach((id) => state.collapsed.add(id))
    // keep the root open so the tree never fully disappears
    state.collapsed.delete(state.data.tree.id)
    paintTree()
  })

  // per-node caret toggle (delegated)
  document.querySelector('#tree').addEventListener('click', (e) => {
    const btn = e.target.closest('.caret[data-toggle]')
    if (!btn) return
    const id = btn.dataset.toggle
    if (state.collapsed.has(id)) state.collapsed.delete(id)
    else state.collapsed.add(id)
    paintTree()
  })

  // file uploader
  const fileInput = document.querySelector('#file')
  document.querySelector('#load-btn').addEventListener('click', () => fileInput.click())
  fileInput.addEventListener('change', async (e) => {
    const file = e.target.files?.[0]
    if (!file) return
    try {
      const parsed = JSON.parse(await file.text())
      if (!parsed || typeof parsed !== 'object' || !parsed.tree || !parsed.tree.type) {
        throw new Error('missing a top-level "tree" node')
      }
      state.data = parsed
      state.search = ''
      state.types = new Set(TYPES)
      state.collapsed = new Set()
      buildShell()
    } catch (err) {
      alert(`Could not load "${file.name}": ${err.message}\n\nExpected a DPK diff export (see SCHEMA.md).`)
    } finally {
      e.target.value = '' // allow re-selecting the same file
    }
  })
}

buildShell()
