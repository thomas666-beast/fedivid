export function fmtCount(n) {
  const v = Number(n) || 0
  if (v < 1000) return String(v)
  if (v < 10_000) return (v / 1000).toFixed(1).replace(/\.0$/, '') + 'K'
  if (v < 1_000_000) return Math.floor(v / 1000) + 'K'
  if (v < 10_000_000) return (v / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M'
  if (v < 1_000_000_000) return Math.floor(v / 1_000_000) + 'M'
  return Math.floor(v / 1_000_000_000) + 'B'
}

export function fmtTime(ts) {
  if (!ts) return ''
  const then = new Date(ts).getTime()
  if (isNaN(then)) return ts
  const diff = Math.max(0, Date.now() - then) / 1000
  if (diff < 60) return 'just now'
  if (diff < 3600) return `${Math.floor(diff / 60)}m`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h`
  if (diff < 86400 * 7) return `${Math.floor(diff / 86400)}d`
  return new Date(ts).toLocaleDateString()
}

export function fmtChatTime(ts) {
  if (!ts) return ''
  const d = new Date(ts)
  if (isNaN(d.getTime())) return ts

  const now = new Date()
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate()

  const hh = String(d.getHours()).padStart(2, '0')
  const mm = String(d.getMinutes()).padStart(2, '0')

  if (sameDay) return `${hh}:${mm}`

  const yesterday = new Date(now)
  yesterday.setDate(now.getDate() - 1)
  const isYesterday =
    d.getFullYear() === yesterday.getFullYear() &&
    d.getMonth() === yesterday.getMonth() &&
    d.getDate() === yesterday.getDate()

  if (isYesterday) return `Yesterday ${hh}:${mm}`

  const mon = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][d.getMonth()]
  const sameYear = d.getFullYear() === now.getFullYear()

  if (sameYear) return `${mon} ${d.getDate()} ${hh}:${mm}`
  return `${mon} ${d.getDate()} ${d.getFullYear()} ${hh}:${mm}`
}

export function fmtBadge(n) {
  const v = Number(n) || 0
  if (v <= 99) return String(v)
  if (v < 1000) return '99+'
  if (v < 10_000) return (v / 1000).toFixed(1).replace(/\.0$/, '') + 'K'
  if (v < 1_000_000) return Math.floor(v / 1000) + 'K'
  return (v / 1_000_000).toFixed(1).replace(/\.0$/, '') + 'M'
}
