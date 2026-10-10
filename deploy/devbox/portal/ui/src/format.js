// devbox.sh logs carry ANSI colours (deploy/scripts/lib/colors.sh). Turn the
// few it uses into spans; escape everything else so a log can't inject HTML.
const COLORS = { 30: 'c-dim', 31: 'c-red', 32: 'c-green', 33: 'c-yellow', 34: 'c-blue', 36: 'c-cyan', 90: 'c-dim' }

const escape = (s) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))

export function ansiToHtml(text) {
  let out = ''
  let open = false
  const re = /\x1b\[([0-9;]*)m/g
  const src = escape(text || '')
  let last = 0
  let m
  while ((m = re.exec(src)) !== null) {
    out += src.slice(last, m.index)
    last = re.lastIndex
    if (open) { out += '</span>'; open = false }
    const codes = m[1].split(';').map(Number)
    const cls = codes.map((c) => COLORS[c]).filter(Boolean)
    if (codes.includes(1)) cls.push('c-bold')
    if (cls.length) { out += `<span class="${cls.join(' ')}">`; open = true }
  }
  out += src.slice(last)
  if (open) out += '</span>'
  return out
}

export function when(iso) {
  return iso ? new Date(iso).toLocaleString() : ''
}

export function ago(iso) {
  if (!iso) return ''
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000))
  if (s < 60) return `${s}s ago`
  if (s < 3600) return `${Math.round(s / 60)}m ago`
  if (s < 86400) return `${Math.round(s / 3600)}h ago`
  return `${Math.round(s / 86400)}d ago`
}

export function duration(fromIso, toIso) {
  if (!fromIso) return ''
  const end = toIso ? new Date(toIso).getTime() : Date.now()
  const s = Math.max(0, Math.round((end - new Date(fromIso).getTime()) / 1000))
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`
}

/** Where a browser reaches an env (ingress hosts; prod-like is the bare one). */
export function envUrls(env) {
  return env === 'prod-like'
    ? { web: 'http://microecom.local', api: 'http://api.microecom.local' }
    : { web: `http://${env}.microecom.local`, api: `http://api.${env}.microecom.local` }
}

/** Copy text; navigator.clipboard only exists in a secure context (https / localhost). */
export async function copyText(text, inputEl) {
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text)
      return true
    }
  } catch { /* fall through */ }
  if (inputEl) {
    const type = inputEl.type
    inputEl.type = 'text'
    inputEl.select()
    const ok = document.execCommand('copy')
    inputEl.type = type
    return ok
  }
  return false
}

/** Per-viewer UI memory (last env, last service…). Storage can throw (private mode) — never fatal. */
export const remember = {
  get: (k, fallback) => { try { return localStorage.getItem(k) ?? fallback } catch { return fallback } },
  set: (k, v) => { try { localStorage.setItem(k, v) } catch { /* fine */ } },
}
