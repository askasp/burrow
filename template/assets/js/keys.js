// Keyboard shortcuts: the tmux keymap from Beamcode. Press the prefix
// (ctrl+b), then a key. Every link, button and box in view shows a letter
// right away; after a moment a which-key popup lists the keys.
//
//   1–9  sidebar item               n p  next / previous item ↻
//   [ ]  previous / next tab ↻      l    last place
//   b    back: the page's back button, else the browser's
//   w    switch to…                 g    go to… (then a letter)
//   :    all commands               /    search box
//   o    next focus region          ←↑→  focus sidebar / tabs / main
//   z    zoom                       ?    all shortcuts
//   a–z  the letter on a link, button or box; esc or the prefix again: cancel
//
// Without the prefix: mod+k all commands, "/" search box, "?" shortcuts,
// j k (then ↑↓) move in the focused region, enter opens, esc leaves a box
// or cancels, mod+\ zooms.
//
// The page says what the keys act on, with data attributes:
//
//   data-kb="item"      sidebar entries (1–9, n p); the current one has
//                       data-kb-current="1" or aria-current
//   data-kb="tab"       tabs ([ ]); the current one marked the same way
//   data-kb="row"       rows in the main area (j k, enter)
//   data-kb="search"    the box "/" focuses
//   data-kb-key="x"     prefix x clicks it (or focuses a box). data-kb-label
//                       names it in the popups, data-kb-group groups it,
//                       data-kb-focus="#id" focuses that box after.
//   data-kb-go="p"      a link prefix g p follows
//   data-kb-dismiss     an open overlay's scrim: esc clicks it first,
//                       typing or not, so it never reaches data-kb-esc
//   data-kb-esc         esc clicks it (when not typing)
//   data-kb-back        the back button (found without it too: "← …",
//                       "Back …", or a left arrow or chevron icon)
//   data-kb-zoom-hide   hidden while zoomed
//   data-kb-skip        never gets a letter
//
// The same file is in Burrow, Peon and the app template; keep them alike.

// The prefix by key position (any layout's B key) or by letter (Dvorak, Colemak…).
const PREFIX_CODES = {"ctrl+b": "KeyB", "ctrl+space": "Space", "ctrl+a": "KeyA"}
const PREFIX_KEYS = {"ctrl+b": "b", "ctrl+space": " ", "ctrl+a": "a"}
const RESERVED = new Set([..."123456789nplb[]wgoz/:?"])
const REPEATABLE = new Set(["n", "p", "[", "]"])
const LETTERS = [..."sdfjehtyuqvxakmcri"]
const HINT_TARGETS =
  'a[href], button, [role="button"], summary, input:not([type="hidden"]), textarea, select, [data-kb], [data-kb-key], [data-kb-go]'
const MODIFIERS = ["Shift", "Control", "Alt", "Meta", "CapsLock", "AltGraph"]

const isMac = /Mac|iPhone|iPad/.test(navigator.platform)
const modLabel = isMac ? "⌘" : "Ctrl+"

let opts = {prefix: "ctrl+b", whichKeyDelay: 300}
let prefixLabel = "Ctrl+B"

const state = {
  mode: null, // "prefix" | "g" | "repeat" | null
  typed: "",
  hints: [], // [{label, el}]
  which: false,
  help: false,
  palette: null, // {entries, query, sel}
}
const nav = {focus: "main", cursor: false, idx: {side: 0, tabs: 0, main: 0}}
const timers = {}
let path = here()
let lastPath = null
let layers

// ── Reading the page ──────────────────────────────────────────────────────

function here() {
  return location.pathname + location.search
}

const visible = el => el.offsetParent !== null || el.getClientRects().length > 0
const usable = el => visible(el) && !el.disabled && el.getAttribute("aria-disabled") !== "true"
const all = sel => [...document.querySelectorAll(sel)]
const shown = sel => all(sel).filter(usable)
const isBox = el => el.matches("input, textarea, select")
const isCurrent = el =>
  el.dataset.kbCurrent === "1" || ["page", "true", "step", "location"].includes(el.getAttribute("aria-current"))

function nameOf(el) {
  return (
    el.dataset.kbLabel ||
    el.getAttribute("aria-label") ||
    el.getAttribute("placeholder") ||
    el.textContent.trim().replace(/\s+/g, " ") ||
    el.getAttribute("title") ||
    "…"
  ).slice(0, 80)
}

// The page's own prefix keys: key -> {key, label, group, els}.
function pageKeys() {
  const keys = new Map()
  for (const el of all("[data-kb-key]")) {
    const key = el.dataset.kbKey
    if (RESERVED.has(key)) continue
    if (!keys.has(key)) keys.set(key, {key, label: nameOf(el), group: el.dataset.kbGroup || "Act", els: []})
    keys.get(key).els.push(el)
  }
  return keys
}

// Places on `g <key>`: key -> {key, label, el}.
function goKeys() {
  const keys = new Map()
  for (const el of all("[data-kb-go]")) {
    const key = el.dataset.kbGo
    if (!keys.has(key) || (!usable(keys.get(key).el) && usable(el))) keys.set(key, {key, label: nameOf(el), el})
  }
  return keys
}

const items = () => shown('[data-kb="item"]')
const tabs = () => shown('[data-kb="tab"]')

// ── Overlay ───────────────────────────────────────────────────────────────

const STYLE = `
:root {
  --kb-bg: var(--raised, var(--color-base-100, #fff));
  --kb-fg: var(--text, var(--color-base-content, #1c1917));
  --kb-muted: var(--text-3, #6b6560);
  --kb-border: var(--border-strong, var(--color-base-300, #b5aca3));
  --kb-accent: var(--accent, var(--color-primary, #8fbf5a));
  --kb-accent-ink: var(--accent-ink, var(--color-primary-content, #18240b));
  --kb-shadow: var(--shadow, rgba(0, 0, 0, .18));
  --kb-mono: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
}
body.kb-zoom [data-kb-zoom-hide] { display: none !important }
[data-kb-cursor] { box-shadow: inset 0 0 0 1.5px var(--kb-accent) !important }
#kb-overlay { font: 13px/1.4 system-ui, sans-serif; color: var(--kb-fg) }
.kb-hint { position: fixed; z-index: 2147483600; padding: 0 4px; border-radius: 3px; background: var(--kb-accent);
  color: var(--kb-accent-ink); font: 700 11px/16px var(--kb-mono); box-shadow: 0 1px 2px var(--kb-shadow); pointer-events: none }
.kb-hint.faded { opacity: .2 }
.kb-hint .kb-typed { opacity: .45 }
.kb-panel { background: var(--kb-bg); color: var(--kb-fg); border: 1px solid var(--kb-border); border-radius: 8px;
  box-shadow: 0 8px 24px var(--kb-shadow) }
.kb-which { position: fixed; z-index: 2147483601; bottom: 16px; left: 50%; transform: translateX(-50%); padding: 12px 14px;
  display: flex; flex-wrap: wrap; gap: 6px 28px; max-width: calc(100vw - 32px); font-size: 12px; pointer-events: none }
.kb-title { font-size: 11px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; color: var(--kb-muted); margin-bottom: 4px }
.kb-row { display: flex; gap: 8px; align-items: center; margin: 2px 0 }
.kb-key { display: inline-flex; align-items: center; justify-content: center; min-width: 22px; height: 22px; padding: 0 6px;
  border-radius: 4px; font: 11.5px var(--kb-mono); white-space: nowrap; flex: none;
  box-shadow: inset 0 0 0 1px var(--kb-border), inset 0 -1px 0 var(--kb-border) }
.kb-keys { display: flex; gap: 3px; min-width: 120px }
.kb-which .kb-keys { min-width: 52px }
.kb-backdrop { position: fixed; inset: 0; z-index: 2147483602; background: rgba(0, 0, 0, .4); display: grid; place-items: center }
.kb-help { padding: 20px; width: min(720px, calc(100vw - 32px)); max-height: calc(100vh - 48px); overflow: auto }
.kb-help-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px 28px; margin-top: 12px }
.kb-head { display: flex; align-items: baseline; gap: 12px; font-weight: 600; font-size: 14px }
.kb-head span { margin-left: auto; font-weight: 400; font-size: 12px; color: var(--kb-muted) }
.kb-pal-wrap { position: fixed; inset: 0; z-index: 2147483602; background: rgba(0, 0, 0, .25) }
.kb-pal { position: absolute; top: 12vh; left: 50%; transform: translateX(-50%); width: min(560px, calc(100vw - 32px)); overflow: hidden }
.kb-pal input { width: 100%; box-sizing: border-box; border: 0; border-bottom: 1px solid var(--kb-border); outline: 0;
  padding: 12px 14px; font: inherit; font-size: 15px; background: transparent; color: inherit }
.kb-pal ul { list-style: none; margin: 0; padding: 4px; max-height: 50vh; overflow: auto }
.kb-pal li { display: flex; gap: 10px; align-items: center; padding: 7px 10px; border-radius: 5px; cursor: pointer }
.kb-pal li.sel { background: color-mix(in srgb, var(--kb-accent) 22%, transparent) }
.kb-pal li .kb-group { margin-left: auto; font-size: 11px; color: var(--kb-muted) }
.kb-pal .kb-empty { padding: 10px 14px; color: var(--kb-muted) }
.kb-toast { position: fixed; z-index: 2147483603; bottom: 16px; right: 16px; padding: 8px 12px; pointer-events: none }
`

function setup() {
  const style = document.createElement("style")
  style.id = "kb-style"
  style.textContent = STYLE
  // First in <head>, so the app's own CSS can restyle any of it.
  document.head.prepend(style)

  const root = document.createElement("div")
  root.id = "kb-overlay"
  root.innerHTML = '<div data-l="hints"></div><div data-l="which"></div><div data-l="help"></div><div data-l="pal"></div><div data-l="toast"></div>'
  document.body.appendChild(root)
  layers = Object.fromEntries([...root.children].map(el => [el.dataset.l, el]))
}

const esc = s => String(s).replace(/[&<>"]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"})[c])
const kbd = k => `<kbd class="kb-key">${esc(k)}</kbd>`
const row = (keys, label) =>
  `<div class="kb-row"><span class="kb-keys">${keys.map(kbd).join("")}</span><span>${esc(label)}</span></div>`
const section = (title, rows) =>
  `<div><div class="kb-title">${esc(title)}</div>${rows.map(([k, l]) => row(k, l)).join("")}</div>`

function renderHints() {
  if (state.mode !== "prefix") return (layers.hints.innerHTML = "")
  layers.hints.innerHTML = state.hints
    .map(({label, el}) => {
      const r = el.getBoundingClientRect()
      const off = state.typed && !label.startsWith(state.typed)
      const text = state.typed && !off
        ? `<span class="kb-typed">${esc(state.typed)}</span>${esc(label.slice(state.typed.length))}`
        : esc(label)
      return `<span class="kb-hint${off ? " faded" : ""}" style="left:${Math.max(r.left - 8, 2)}px;top:${Math.max(r.top - 7, 2)}px">${text}</span>`
    })
    .join("")
}

// What the prefix can do here: the built-in keys that apply, then the page's.
function whichGroups() {
  const navigate = [
    ...(items().length ? [[["1–9"], "Sidebar item"], [["n", "p"], "Next / previous ↻"]] : []),
    [["l"], "Last place"],
    [["b"], (b => (b ? `Back: ${nameOf(b)}` : "Back"))(backButton())],
    [["w"], "Switch to…"],
    ...(goKeys().size ? [[["g"], "Go to…"]] : []),
  ]
  const groups = new Map()
  for (const k of pageKeys().values()) {
    if (!groups.has(k.group)) groups.set(k.group, [])
    groups.get(k.group).push([[k.key], k.label])
  }
  const view = [
    ...(tabs().length ? [[["[", "]"], "Previous / next tab ↻"]] : []),
    [["o"], "Next focus region"],
    [["z"], "Zoom"],
    [["/"], "Search"],
    [[":"], "All commands"],
    [["?"], "All shortcuts"],
    [["a–z"], "The letter on it: press it"],
  ]
  return [["Navigate", navigate], ...groups, ["View", view]]
}

function renderWhich() {
  if (state.mode === "g") {
    const rows = [...goKeys().values()].map(g => [[g.key], g.label])
    layers.which.innerHTML = `<div class="kb-panel kb-which">${section("Go to", rows)}</div>`
  } else if (state.mode === "prefix" && state.which) {
    layers.which.innerHTML = `<div class="kb-panel kb-which">${whichGroups().map(([t, r]) => section(t, r)).join("")}</div>`
  } else {
    layers.which.innerHTML = ""
  }
}

function renderHelp() {
  if (!state.help) return (layers.help.innerHTML = "")
  const p = prefixLabel
  const prefixed = whichGroups().map(([title, rows]) => [title, rows.map(([k, l]) => [[p, ...k], l])])
  const gos = [...goKeys().values()].map(g => [[p, "g", g.key], g.label])
  const escEl = shown("[data-kb-esc]")[0]
  const plain = [
    [[modLabel + "K"], "All commands"],
    [["/"], "Search"],
    [["?"], "Shortcuts"],
    [["j", "k"], "Move in the focused region"],
    [["enter"], "Open"],
    [["esc"], escEl ? `Leave a box / ${nameOf(escEl)}` : "Leave a box / cancel"],
    [[modLabel + "\\"], "Zoom"],
  ]
  const notes = [
    [[p], "works inside text boxes. Press it twice to cancel."],
    [["↻"], "repeats: for 600 ms after, press the same key again without the prefix."],
  ]
  const sections = [...prefixed, ...(gos.length ? [[`Go to (${p} g …)`, gos]] : []), ["Anywhere, no prefix", plain], ["Notes", notes]]
  layers.help.innerHTML = `<div class="kb-backdrop" data-kb-close><div class="kb-panel kb-help">
    <div class="kb-head">Keyboard shortcuts<span>esc or ? to close</span></div>
    <div class="kb-help-grid">${sections.map(([t, r]) => section(t, r)).join("")}</div></div></div>`
  layers.help.querySelector("[data-kb-close]").addEventListener("click", e => {
    if (e.target.matches("[data-kb-close]")) setHelp(false)
  })
}

function setHelp(open) {
  state.help = open
  renderHelp()
}

function toast(text) {
  clearTimeout(timers.toast)
  layers.toast.innerHTML = `<div class="kb-panel kb-toast">${esc(text)}</div>`
  timers.toast = setTimeout(() => (layers.toast.innerHTML = ""), 1800)
}

// ── Doing things ──────────────────────────────────────────────────────────

// A row that isn't clickable itself (a table row) clicks what's inside it.
const CLICKABLE = 'a[href], button, [role="button"], summary, [phx-click], input, textarea, select'

function press(el) {
  if (!el.matches(CLICKABLE)) el = el.querySelector(CLICKABLE) || el
  if (isBox(el)) return el.focus()
  el.click()
  const then = el.dataset.kbFocus
  if (then) setTimeout(() => document.querySelector(then)?.focus(), 60)
}

function pressKey(entry) {
  const el = entry.els.find(usable)
  el ? press(el) : toast(`${entry.label}: not here right now`)
}

function go(href) {
  const link = all("a[href]").find(a => a.getAttribute("href") === href)
  link ? link.click() : location.assign(href)
}

function openItem(i) {
  const item = items()[i]
  item ? item.click() : toast(`No item ${i + 1}`)
}

function cycle(list, dir) {
  if (!list.length) return toast("Nothing to step through here")
  const cur = list.findIndex(isCurrent)
  const next = cur < 0 ? (dir > 0 ? 0 : list.length - 1) : (cur + dir + list.length) % list.length
  list[next].click()
}

function focusSearch() {
  const box = shown('[data-kb="search"]')[0]
  box ? box.focus() : openPalette("all")
}

// The page's own back button, else the browser's back.
const BACK_ICON = '[class*="hero-arrow-left"], [class*="hero-chevron-left"], [class*="hero-arrow-uturn-left"]'

function backButton() {
  const marked = shown("[data-kb-back]")[0]
  if (marked) return marked
  return shown('a[href], button, [role="button"]').find(el => {
    const text = el.textContent.trim()
    const label = el.getAttribute("aria-label") || ""
    return /^(←|‹|<|back\b|go back\b)/i.test(text) || /^(back|go back)\b/i.test(label) || !!el.querySelector(BACK_ICON)
  })
}

function back() {
  const el = backButton()
  if (el) return el.click()
  history.length > 1 ? history.back() : toast("Nowhere to go back to")
}

function toggleZoom() {
  document.body.classList.toggle("kb-zoom")
}

// ── Focus regions and the cursor ──────────────────────────────────────────
// j / k (then ↑↓) move a cursor in the focused region, enter opens; h / l
// step through tabs. o or the prefix with an arrow switch regions.

const REGIONS = ["side", "tabs", "main"]
const REGION_SELECTOR = {side: '[data-kb="item"]', tabs: '[data-kb="tab"]', main: '[data-kb="row"]'}
const REGION_NAME = {side: "sidebar", tabs: "tabs", main: "main area"}
const regionEls = r => shown(REGION_SELECTOR[r])

function paint() {
  all("[data-kb-cursor]").forEach(el => el.removeAttribute("data-kb-cursor"))
  if (!nav.cursor) return
  const el = regionEls(nav.focus)[nav.idx[nav.focus]]
  if (!el) return
  el.setAttribute("data-kb-cursor", "")
  el.scrollIntoView({block: "nearest"})
}

function startAt(r) {
  const list = regionEls(r)
  const cur = list.findIndex(isCurrent)
  return cur < 0 ? 0 : cur
}

// Moves the cursor; false when the region has nothing to move through.
function move(dir) {
  const list = regionEls(nav.focus)
  if (!list.length) return false
  if (!nav.cursor) {
    nav.cursor = true
    nav.idx[nav.focus] = startAt(nav.focus)
  } else {
    nav.idx[nav.focus] = Math.min(list.length - 1, Math.max(0, nav.idx[nav.focus] + dir))
  }
  paint()
  return true
}

function activate() {
  const el = nav.cursor && regionEls(nav.focus)[nav.idx[nav.focus]]
  if (!el) return false
  press(el)
  return true
}

function focusRegion(r) {
  if (!regionEls(r).length) return toast(`Nothing to focus in the ${REGION_NAME[r]}`)
  nav.focus = r
  nav.cursor = true
  nav.idx[r] = startAt(r)
  paint()
}

function cycleFocus() {
  const start = REGIONS.indexOf(nav.focus)
  for (let i = 1; i <= REGIONS.length; i++) {
    const r = REGIONS[(start + i) % REGIONS.length]
    if (regionEls(r).length) return focusRegion(r)
  }
  toast("Nothing to focus here")
}

function clearCursor() {
  nav.cursor = false
  paint()
}

// ── Command palette ───────────────────────────────────────────────────────
// mod+k or the prefix and ":" list everything; the prefix and "w" only places.

function entries(mode) {
  const list = []
  const seen = new Set()
  const add = (group, label, keys, run, el) => {
    if (el && seen.has(el)) return
    if (el) seen.add(el)
    list.push({group, label, keys, run})
  }
  const p = prefixLabel
  items().forEach((el, i) => add("Sidebar", nameOf(el), i < 9 ? [p, String(i + 1)] : [], () => el.click(), el))
  tabs().forEach(el => add("Tabs", nameOf(el), [], () => el.click(), el))
  for (const g of goKeys().values()) add("Go to", g.label, [p, "g", g.key], () => g.el.click(), g.el)
  if (mode === "all") {
    for (const k of pageKeys().values()) {
      const el = k.els.find(usable)
      if (el) add(k.group, k.label, [p, k.key], () => press(el), el)
    }
    add("View", "Zoom", [p, "z"], toggleZoom)
    add("View", "Next focus region", [p, "o"], cycleFocus)
    add("View", "Keyboard shortcuts", ["?"], () => setHelp(true))
    if (lastPath) add("Navigate", "Last place", [p, "l"], () => go(lastPath))
    add("Navigate", "Back", [p, "b"], back)
  }
  return list
}

function score(text, q) {
  if (!q) return 1
  const t = text.toLowerCase()
  const at = t.indexOf(q)
  if (at === 0) return 100
  if (at > 0) return 60 - Math.min(at, 50)
  let i = 0
  for (const c of t) if (c === q[i]) i++
  return i === q.length ? 1 : 0
}

function matches() {
  const q = state.palette.query.trim().toLowerCase()
  return state.palette.entries
    .map((e, i) => ({e, i, s: Math.max(score(e.label, q), score(`${e.group} ${e.label}`, q) / 2)}))
    .filter(m => m.s > 0)
    .sort((a, b) => b.s - a.s || a.i - b.i)
    .map(m => m.e)
}

function openPalette(mode) {
  disarm()
  state.palette = {entries: entries(mode), query: "", sel: 0}
  const placeholder = mode === "switch" ? "Switch to…" : "Type a command or a place…"
  layers.pal.innerHTML = `<div class="kb-pal-wrap" data-kb-close><div class="kb-panel kb-pal">
    <input type="text" placeholder="${placeholder}" autocomplete="off" spellcheck="false" aria-label="${placeholder}" data-kb-skip />
    <ul role="listbox"></ul></div></div>`
  const input = layers.pal.querySelector("input")
  input.addEventListener("input", () => {
    state.palette.query = input.value
    state.palette.sel = 0
    renderPaletteList()
  })
  layers.pal.querySelector("[data-kb-close]").addEventListener("mousedown", e => {
    if (e.target.matches("[data-kb-close]")) closePalette()
  })
  layers.pal.querySelector("ul").addEventListener("mousedown", e => {
    const li = e.target.closest("li[data-i]")
    if (!li) return
    e.preventDefault()
    runPalette(Number(li.dataset.i))
  })
  renderPaletteList()
  input.focus()
}

function renderPaletteList() {
  const list = matches()
  const ul = layers.pal.querySelector("ul")
  if (!list.length) return (ul.innerHTML = '<li class="kb-empty">Nothing matches</li>')
  state.palette.sel = Math.min(state.palette.sel, list.length - 1)
  ul.innerHTML = list
    .map((e, i) => `<li data-i="${i}" role="option" class="${i === state.palette.sel ? "sel" : ""}">
      <span>${esc(e.label)}</span><span class="kb-group">${esc(e.group)}</span>
      ${e.keys.length ? `<span class="kb-keys" style="min-width:0">${e.keys.map(kbd).join("")}</span>` : ""}</li>`)
    .join("")
  ul.querySelector("li.sel")?.scrollIntoView({block: "nearest"})
}

function runPalette(i) {
  const entry = matches()[i]
  closePalette()
  entry?.run()
}

function closePalette() {
  state.palette = null
  layers.pal.innerHTML = ""
}

function paletteKey(e) {
  const stop = () => e.preventDefault()
  const down = e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")
  const up = e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")
  if (e.key === "Escape" || (mod(e) && e.code === "KeyK")) {
    stop()
    return closePalette()
  }
  if (e.key === "Enter") {
    stop()
    return runPalette(state.palette.sel)
  }
  if (down || up) {
    stop()
    const n = matches().length
    if (n) state.palette.sel = (state.palette.sel + (down ? 1 : -1) + n) % n
    renderPaletteList()
  }
}

// ── Hints ─────────────────────────────────────────────────────────────────
// While the prefix is armed every link, button and box in view shows a
// letter; pressing it clicks the link or focuses the box. Letters that are
// built-in or page keys are never hints.

// In view and not covered (a row scrolled under a header doesn't count).
function inView(el) {
  if (!usable(el) || el.closest("[data-kb-skip], #kb-overlay")) return false
  const r = el.getBoundingClientRect()
  if (!r.width || r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth) return false
  const hit = document.elementFromPoint(
    Math.min(Math.max(r.left + Math.min(r.width / 2, 24), 0), innerWidth - 1),
    (Math.max(r.top, 0) + Math.min(r.bottom, innerHeight)) / 2,
  )
  return !!hit && (hit === el || el.contains(hit) || (el.labels && [...el.labels].some(l => l.contains(hit))))
}

function showHints() {
  const taken = new Set(pageKeys().keys())
  const letters = LETTERS.filter(k => !RESERVED.has(k) && !taken.has(k))
  const n = letters.length
  const found = [...new Set(all(HINT_TARGETS))].filter(inView).slice(0, n * n)
  const rects = new Map(found.map(el => [el, el.getBoundingClientRect()]))
  found.sort((a, b) => rects.get(a).top - rects.get(b).top || rects.get(a).left - rects.get(b).left)
  const label = i => (found.length <= n ? letters[i] : letters[Math.floor(i / n)] + letters[i % n])
  state.hints = found.map((el, i) => ({label: label(i), el}))
}

// A hint letter: opens it, or waits for the second letter. False when no hint starts so.
function hintKey(k) {
  const typed = state.typed + k
  const hit = state.hints.find(h => h.label === typed)
  if (hit) {
    disarm()
    press(hit.el)
    return true
  }
  if (!state.hints.some(h => h.label.startsWith(typed))) return false
  state.typed = typed
  clearTimeout(timers.reset)
  timers.reset = setTimeout(disarm, 6000)
  renderHints()
  return true
}

// ── Keys ──────────────────────────────────────────────────────────────────

function arm(mode = "prefix") {
  clearTimeout(timers.which)
  clearTimeout(timers.reset)
  state.mode = mode
  state.typed = ""
  state.which = false
  state.hints = []
  if (mode === "prefix") {
    showHints()
    timers.which = setTimeout(() => {
      state.which = true
      renderWhich()
    }, opts.whichKeyDelay)
  }
  timers.reset = setTimeout(disarm, {prefix: 6000, g: 3000, repeat: 600}[mode])
  renderHints()
  renderWhich()
}

function disarm() {
  clearTimeout(timers.which)
  clearTimeout(timers.reset)
  state.mode = null
  state.typed = ""
  state.which = false
  state.hints = []
  if (layers) {
    renderHints()
    renderWhich()
  }
}

function prefixKey(e) {
  const k = e.key
  if (k === "Escape") return disarm()
  if (state.mode === "g") {
    disarm()
    const place = goKeys().get(k)
    return place ? place.el.click() : toast(`Nothing on g ${k}`)
  }
  const once = fn => {
    disarm()
    fn()
  }
  const rep = fn => {
    fn()
    arm("repeat")
  }

  if (state.typed) {
    if (/^[a-z]$/.test(k) && hintKey(k)) return
    return once(() => toast(`No letter ${state.typed}${k}`))
  }
  if (/^[1-9]$/.test(k)) return once(() => openItem(Number(k) - 1))
  const own = pageKeys().get(k)
  if (own) return once(() => pressKey(own))
  if (/^[a-z]$/.test(k) && !RESERVED.has(k) && hintKey(k)) return

  switch (k) {
    case "n": return rep(() => cycle(items(), 1))
    case "p": return rep(() => cycle(items(), -1))
    case "]": return rep(() => cycle(tabs(), 1))
    case "[": return rep(() => cycle(tabs(), -1))
    case "l": return once(() => (lastPath ? go(lastPath) : toast("No last place yet")))
    case "b": return once(back)
    case "w": return once(() => openPalette("switch"))
    case ":": return once(() => openPalette("all"))
    case "g": return goKeys().size ? arm("g") : once(() => toast("No places to go to here"))
    case "/": return once(focusSearch)
    case "o": return once(cycleFocus)
    case "z": return once(toggleZoom)
    case "?": return once(() => setHelp(true))
    case "ArrowLeft": return once(() => focusRegion("side"))
    case "ArrowUp": return once(() => focusRegion("tabs"))
    case "ArrowRight":
    case "ArrowDown": return once(() => focusRegion("main"))
    default: return once(() => toast(`No binding: ${prefixLabel} ${k}`))
  }
}

const editable = el => !!el && (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName))
const plain = e => !e.ctrlKey && !e.metaKey && !e.altKey
const mod = e => (isMac ? e.metaKey : e.ctrlKey)

function onKey(e) {
  if (e.defaultPrevented || e.isComposing || MODIFIERS.includes(e.key)) return
  const typing = editable(e.target)
  const isPrefix =
    e.ctrlKey && !e.metaKey && !e.altKey &&
    (e.code === PREFIX_CODES[opts.prefix] || e.key.toLowerCase() === PREFIX_KEYS[opts.prefix])
  const stop = () => e.preventDefault()

  if (state.palette) return paletteKey(e)
  if (state.help) {
    if (e.key === "Escape" || e.key === "?") {
      stop()
      setHelp(false)
    }
    return
  }

  if (state.mode) {
    if (state.mode === "repeat" && !(plain(e) && REPEATABLE.has(e.key))) disarm()
    else {
      stop()
      return isPrefix ? disarm() : prefixKey(e)
    }
  }
  if (isPrefix) {
    stop()
    return arm()
  }
  if (mod(e) && e.code === "KeyK") {
    stop()
    return openPalette("all")
  }
  if (mod(e) && e.code === "Backslash") {
    stop()
    return toggleZoom()
  }
  if (e.key === "Escape") {
    const scrim = shown("[data-kb-dismiss]")[0]
    if (scrim) {
      stop()
      if (typing) e.target.blur()
      return scrim.click()
    }
    if (typing) return e.target.blur()
    if (nav.cursor) return clearCursor()
    const el = shown("[data-kb-esc]")[0]
    if (el) {
      stop()
      el.click()
    }
    return
  }
  if (typing || !plain(e)) return

  const k = e.key
  const done = fn => {
    stop()
    fn()
  }
  if (k === "j" && move(1)) return stop()
  if (k === "k" && move(-1)) return stop()
  if (nav.cursor && k === "ArrowDown") return done(() => move(1))
  if (nav.cursor && k === "ArrowUp") return done(() => move(-1))
  if (nav.cursor && nav.focus === "tabs" && (k === "h" || k === "ArrowLeft")) return done(() => cycle(tabs(), -1))
  if (nav.cursor && nav.focus === "tabs" && (k === "l" || k === "ArrowRight")) return done(() => cycle(tabs(), 1))
  if (k === "Enter" && activate()) return stop()
  if (k === "/") return done(focusSearch)
  if (k === "?") return done(() => setHelp(true))
}

function moved() {
  const next = here()
  if (next === path) return
  lastPath = path
  path = next
  nav.cursor = false
  paint()
}

// Options: prefix ("ctrl+b", "ctrl+space" or "ctrl+a"), whichKeyDelay (ms).
export function installKeys(options = {}) {
  opts = {...opts, ...options}
  prefixLabel = {
    "ctrl+b": isMac ? "⌃B" : "Ctrl+B",
    "ctrl+space": isMac ? "⌃Space" : "Ctrl+Space",
    "ctrl+a": isMac ? "⌃A" : "Ctrl+A",
  }[opts.prefix]
  const start = () => {
    setup()
    // Keys typed in a text box are caught on the way down, everything else on the way up.
    window.addEventListener("keydown", e => editable(e.target) && onKey(e), true)
    window.addEventListener("keydown", e => !editable(e.target) && onKey(e))
    window.addEventListener("phx:page-loading-stop", moved)
    window.addEventListener("popstate", moved)
    window.addEventListener("resize", () => state.mode === "prefix" && renderHints())
    window.addEventListener("scroll", () => state.mode === "prefix" && renderHints(), true)
  }
  document.body ? start() : document.addEventListener("DOMContentLoaded", start)
}
