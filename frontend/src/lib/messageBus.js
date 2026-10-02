// Tiny event bus for distributing incoming WebSocket messages
// from App.vue (which owns the connection) to view components.

const listeners = new Set()

export function onMessage(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)   // unsubscribe function
}

export function emitMessage(msg) {
  for (const fn of listeners) {
    try { fn(msg) } catch (e) { console.error('[messageBus] listener failed:', e) }
  }
}
