// Keyboard shortcuts, the tmux keymap from Beamcode (lib/keys.ts there):
// press the prefix (ctrl+b), then a key. After a moment a which-key popup
// lists the keys, and every button and row in view shows a letter hint.
//
//   1–9  chat in the sidebar        n p  next / previous chat (↻ repeats)
//   l    last chat                  c    new chat
//   s    incidents · deploys        a    land the chat's changeset
//   x    stop the agent             r R  reload / restart the preview
//   v    preview logs               P    promote staging to prod
//   z    zoom the preview           /    the chat box
//   ?    all shortcuts              esc  or the prefix again: cancel
//
// Without the prefix: "/" the chat box, "?" shortcuts, esc stops the agent
// (or leaves the chat box), mod+\ zooms.
//
// The page marks what keys act on: data-kb="item" (sidebar chats, the current
// one data-kb-current="1"), data-kb="row" (anything a hint can click) and
// data-kb-action="name" (what a command key clicks).

const PREFIX_CODE = "KeyB"
const WHICH_KEY_DELAY = 300
const REPEATABLE = ["n", "p"]
const COMMAND_KEYS = new Set("nplcsaxrvz")
const HINT_LETTERS = [..."sdfjehtyuqvxbakm"].filter(k => !COMMAND_KEYS.has(k))
const HINT_TARGETS = '[data-kb="row"], [data-kb="item"], textarea, input:not([type="hidden"])'

const isMac = /Mac|iPhone|iPad/.test(navigator.platform)
const prefixLabel = isMac ? "⌃B" : "Ctrl+B"

const ACTIONS = {
  c: "new", s: "ship", a: "land", x: "stop", r: "reload", R: "restart", v: "logs", P: "promote",
}

const WHICH_KEY = [
  ["Chats", [["1–9", "Chat in the sidebar"], ["n p", "Next / previous ↻"], ["l", "Last chat"], ["c", "New chat"]]],
  ["Ship", [["a", "Land changeset"], ["s", "Incidents · deploys"], ["P", "Promote to prod"]]],
  ["Agent & preview", [["x", "Stop the agent"], ["r R", "Reload / restart preview"], ["v", "Preview logs"], ["z", "Zoom preview"]]],
  ["Other", [["/", "Chat box"], ["?", "All shortcuts"], ["a–z", "Letter on a button: press it"]]],
]

const HELP = [
  ["After the prefix (" + prefixLabel + ")", WHICH_KEY.flatMap(([, keys]) => keys)],
  ["Anywhere, no prefix", [
    ["/", "Chat box"], ["?", "Shortcuts"], ["esc", "Stop the agent / leave the chat box"],
    [(isMac ? "⌘" : "Ctrl+") + "\\", "Zoom preview"],
  ]],
  ["Notes", [
    [prefixLabel, "works inside the chat box. Press it twice to cancel."],
    ["↻", "repeats: for 600 ms after, press the same key again without the prefix."],
  ]],
]

let mode = null // "prefix" | "repeat" | null
let typed = ""
let hints = [] // [{label, el}]
let lastPath = null
let path = location.pathname
const timers = {}
let overlay

function ui() {
  if (overlay) return overlay
  overlay = document.createElement("div")
  overlay.id = "kb-overlay"
  document.body.appendChild(overlay)
  return overlay
}

function render({which = false, help = false, toast = null} = {}) {
  const root = ui()
  const hintHtml = hints
    .map(({label, el}) => {
      const r = el.getBoundingClientRect()
      const done = typed && !label.startsWith(typed)
      return `<span class="kb-hint ${done ? "faded" : ""}"
        style="left:${Math.max(r.left - 6, 2)}px;top:${Math.max(r.top - 6, 2)}px">${label}</span>`
    })
    .join("")

  const whichHtml = which
    ? `<div class="kb-panel fixed z-[61] bottom-4 left-1/2 -translate-x-1/2 p-3 text-xs grid grid-cols-2 md:grid-cols-4 gap-x-6 gap-y-1">
        ${WHICH_KEY.map(([title, keys]) => `<div><div class="eyebrow mb-1">${title}</div>${keys
          .map(([k, d]) => `<div class="flex gap-2"><kbd class="kbd">${esc(k)}</kbd><span>${esc(d)}</span></div>`)
          .join("")}</div>`).join("")}
      </div>`
    : ""

  const helpHtml = help
    ? `<div class="fixed inset-0 z-[62] bg-black/40 grid place-items-center" data-kb-close>
        <div class="kb-panel p-5 max-w-2xl w-[calc(100%-2rem)] text-sm space-y-4">
          <div class="flex items-center"><span class="font-semibold">Keyboard shortcuts</span><span class="ml-auto text-xs muted">esc or ? to close</span></div>
          ${HELP.map(([title, keys]) => `<div><div class="eyebrow mb-1">${esc(title)}</div>
            <div class="grid sm:grid-cols-2 gap-x-6 gap-y-1">${keys
              .map(([k, d]) => `<div class="flex gap-2"><kbd class="kbd shrink-0">${esc(k)}</kbd><span>${esc(d)}</span></div>`)
              .join("")}</div></div>`).join("")}
        </div>
      </div>`
    : ""

  const toastHtml = toast
    ? `<div class="toast" style="top:auto;bottom:16px"><div class="toast-body">${esc(toast)}</div></div>`
    : ""

  root.innerHTML = hintHtml + whichHtml + helpHtml + toastHtml
  root.querySelector("[data-kb-close]")?.addEventListener("click", () => setHelp(false))
}

const esc = s => String(s).replace(/[&<>"]/g, c => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"})[c])

let helpOpen = false
function setHelp(open) {
  helpOpen = open
  render({help: open})
}

function toast(text) {
  clearTimeout(timers.toast)
  render({toast: text})
  timers.toast = setTimeout(() => render(), 1800)
}

const visible = el => el.offsetParent !== null && !el.disabled

function inView(el) {
  if (!visible(el)) return false
  const r = el.getBoundingClientRect()
  if (!r.width || r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth) return false
  const hit = document.elementFromPoint(
    Math.min(Math.max(r.left + Math.min(r.width / 2, 24), 0), innerWidth - 1),
    (Math.max(r.top, 0) + Math.min(r.bottom, innerHeight)) / 2,
  )
  return !!hit && (hit === el || el.contains(hit))
}

function showHints() {
  const found = [...document.querySelectorAll(HINT_TARGETS)].filter(inView)
  const n = HINT_LETTERS.length
  const els = found.slice(0, n * n)
  const label = i => (els.length <= n ? HINT_LETTERS[i] : HINT_LETTERS[Math.floor(i / n)] + HINT_LETTERS[i % n])
  hints = els.map((el, i) => ({label: label(i), el}))
}

function arm(next = "prefix") {
  clearTimeout(timers.which)
  clearTimeout(timers.reset)
  mode = next
  typed = ""
  hints = []
  if (next === "prefix") {
    showHints()
    render()
    timers.which = setTimeout(() => render({which: true}), WHICH_KEY_DELAY)
  }
  timers.reset = setTimeout(disarm, next === "repeat" ? 600 : 6000)
}

function disarm() {
  clearTimeout(timers.which)
  clearTimeout(timers.reset)
  mode = null
  typed = ""
  hints = []
  render()
}

const items = () => [...document.querySelectorAll('[data-kb="item"]')].filter(visible)

function openItem(i) {
  const item = items()[i]
  item ? item.click() : toast(`No chat ${i + 1}`)
}

function step(dir) {
  const list = items()
  if (!list.length) return
  const cur = list.findIndex(el => el.dataset.kbCurrent === "1")
  list[(cur + dir + list.length) % list.length].click()
}

function action(name) {
  const el = [...document.querySelectorAll(`[data-kb-action="${name}"]`)].find(visible)
  if (!el) return toast(`Nothing to ${name} here`)
  el.click()
  if (name === "new") setTimeout(focusComposer, 50)
}

function focusComposer() {
  const box = document.getElementById("chat-input")
  box ? box.focus() : toast("No chat box here")
}

function lastChat() {
  const link = lastPath && document.querySelector(`a[href="${lastPath}"]`)
  link ? link.click() : toast("No last chat yet")
}

function toggleZoom() {
  document.body.classList.toggle("kb-zoom")
}

function openHint(el) {
  if (el.matches("input, textarea")) el.focus()
  else el.click()
}

// A hint letter: opens it, or waits for the second letter. False when no hint starts so.
function hintKey(k) {
  const next = typed + k
  const hit = hints.find(h => h.label === next)
  if (hit) {
    disarm()
    openHint(hit.el)
    return true
  }
  if (!hints.some(h => h.label.startsWith(next))) return false
  typed = next
  clearTimeout(timers.reset)
  timers.reset = setTimeout(disarm, 6000)
  render({which: true})
  return true
}

function prefixKey(e) {
  const k = e.key
  if (k === "Escape") return disarm()
  const once = fn => {
    disarm()
    fn()
  }
  const rep = fn => {
    fn()
    arm("repeat")
  }

  if (/^[1-9]$/.test(k)) return once(() => openItem(Number(k) - 1))
  if (hints.length && /^[a-z]$/.test(k) && !COMMAND_KEYS.has(k) && hintKey(k)) return
  if (typed) return once(() => toast(`No hint ${typed}${k}`))
  if (ACTIONS[k]) return once(() => action(ACTIONS[k]))

  switch (k) {
    case "n": return rep(() => step(1))
    case "p": return rep(() => step(-1))
    case "l": return once(lastChat)
    case "z": return once(toggleZoom)
    case "/": return once(focusComposer)
    case "?": return once(() => setHelp(true))
    default: return once(() => toast(`No binding: ${prefixLabel} ${k}`))
  }
}

const editable = el => !!el && (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName))
const plain = e => !e.ctrlKey && !e.metaKey && !e.altKey
const mod = e => (isMac ? e.metaKey : e.ctrlKey)

function onKey(e) {
  if (e.defaultPrevented || e.isComposing) return
  if (["Shift", "Control", "Alt", "Meta", "CapsLock", "AltGraph"].includes(e.key)) return
  const typing = editable(e.target)
  const isPrefix = e.ctrlKey && !e.metaKey && !e.altKey && e.code === PREFIX_CODE
  const stop = () => e.preventDefault()

  if (helpOpen) {
    if (e.key === "Escape" || e.key === "?") {
      stop()
      setHelp(false)
    }
    return
  }

  if (mode) {
    if (mode === "repeat" && !(plain(e) && REPEATABLE.includes(e.key))) disarm()
    else if (isPrefix) {
      stop()
      return disarm()
    } else {
      stop()
      return prefixKey(e)
    }
  }
  if (isPrefix) {
    stop()
    return arm()
  }
  if (mod(e) && e.code === "Backslash") {
    stop()
    return toggleZoom()
  }
  if (e.key === "Escape") {
    if (typing) return e.target.blur()
    const stopButton = document.querySelector('[data-kb-action="stop"]')
    if (stopButton && visible(stopButton)) {
      stop()
      stopButton.click()
    }
    return
  }
  if (typing || !plain(e)) return
  if (e.key === "/") {
    stop()
    focusComposer()
  } else if (e.key === "?") {
    stop()
    setHelp(true)
  }
}

export function installKeys() {
  // Keys typed in a text field are caught on the way down, everything else on the way up.
  window.addEventListener("keydown", e => editable(e.target) && onKey(e), true)
  window.addEventListener("keydown", e => !editable(e.target) && onKey(e))
  window.addEventListener("phx:page-loading-stop", () => {
    if (location.pathname !== path) {
      lastPath = path
      path = location.pathname
    }
  })
  window.addEventListener("resize", () => mode === "prefix" && render())
}
